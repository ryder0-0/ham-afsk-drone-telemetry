// FILE: mac_app/Sources/HamTelemetryApp/Services/PacketDecoder.swift
//
// Top-level decode service that sits between the serial stream and the
// telemetry model.
//
// The receiver firmware's USB serial stream is a **mixed byte stream**:
//
//   • Raw MAVLink bytes (v1 frames starting 0xFE, v2 starting 0xFD)
//     written by MavlinkOutput::update() draining the decoded-packet ring
//     buffer.
//   • ASCII log lines like "[RX] Packet OK type=0x00 seq=42 len=17 rssi=85\n"
//     written by Serial.printf() from main.cpp and mavlink_output.cpp.
//   • (Optionally) raw 24-byte TelemetrySummary structs if the TX end is
//     running in TELEM_MODE_SUMMARY.
//
// Strategy:
//   1. Buffer bytes.  Split on '\n' into "line candidates".
//   2. A candidate that is pure printable-ASCII and begins with "[" is a
//      diagnostic line — emit onLogLine and consume it.
//   3. Everything else is binary — forward to MavlinkDecoder (which itself
//      hunts for 0xFE/0xFD start bytes and ignores junk in between).
//
// In practice the simpler and more robust approach is: **feed everything
// to MavlinkDecoder**, and separately scan for printable-ASCII log lines
// to surface them in the UI.  MavlinkDecoder is already byte-sync-hunting,
// so diagnostic bytes get harmlessly discarded.
//
// Custom packets (PKT_TYPE_TELEM summaries) on the USB path arrive as raw
// 24-byte structs.  Detecting those with no framing is ambiguous, so for
// the USB path we rely on the transmitter running in tunnel mode (the
// default) and treat MAVLink as the primary protocol.  When replaying
// on-wire captures we can switch to the Bell-202 framing decoder.

import Foundation
import Combine

@MainActor
final class PacketDecoder: ObservableObject {

    // MARK: - Config

    enum Source { case usbMavlink, rawBellFrames }

    @Published var source: Source = .usbMavlink

    // MARK: - Callbacks (set by HamTelemetryApp.bootPipeline)

    var onTelemetryUpdate: ((TelemetrySnapshot) -> Void)?
    var onPacketStats:     ((LinkStats) -> Void)?
    var onLogLine:         ((String) -> Void)?
    var onSpectrum:        (([Float]) -> Void)?

    // MARK: - Sub-decoders

    private let mavlink = MavlinkDecoder()
    private let custom  = CustomPacketDecoder()

    // Rolling buffer for ASCII line extraction
    private var lineBuf: [UInt8] = []

    // Stats
    private var stats = LinkStats()
    private var lastHeartbeatAt: Date?
    private var lastSeqBySys: [UInt8: UInt8] = [:]
    private var pktWindowCount: Int = 0
    private var pktWindowStart: Date = Date()

    init() {
        setupCallbacks()
    }

    /// Install (or clear with nil) the MAVLink 2.0 signature verifier.
    func setSignatureVerifier(_ v: MavlinkSignatureVerifier?) {
        mavlink.signatureVerifier = v
    }

    private func setupCallbacks() {
        mavlink.onFrame = { [weak self] frame in
            guard let self else { return }
            self.handleMavFrame(frame)
        }
        mavlink.onBadCRC = { [weak self] _ in
            guard let self else { return }
            self.stats.crcFails &+= 1
            self.onPacketStats?(self.stats)
        }
        custom.onPacket = { [weak self] pkt in
            guard let self else { return }
            self.handleCustomPacket(pkt)
        }
        custom.onCRCFail = { [weak self] in
            guard let self else { return }
            self.stats.crcFails &+= 1
            self.onPacketStats?(self.stats)
        }
    }

    // MARK: - Byte entry point

    func feed(_ data: Data) {
        stats.bytesReceived &+= UInt64(data.count)

        // Extract printable ASCII lines opportunistically.
        for b in data {
            if b == 0x0A || b == 0x0D {
                flushLineBufIfDiagnostic()
            } else if b >= 0x20 && b <= 0x7E {
                lineBuf.append(b)
                if lineBuf.count > 512 { lineBuf.removeAll(keepingCapacity: true) }
            } else {
                // Non-printable byte — whatever was in lineBuf isn't a clean
                // ASCII line; drop it so we don't emit garbled log lines.
                lineBuf.removeAll(keepingCapacity: true)
            }
        }

        switch source {
        case .usbMavlink:
            // Primary: MAVLink frames.  Secondary: if a future firmware
            // wraps spectrum frames in Bell-202 framing and writes them
            // to USB, CustomPacketDecoder will pick them up (its preamble
            // hunter ignores MAVLink bytes, so the two can coexist).
            mavlink.feed(data)
            custom.feed(data)
        case .rawBellFrames:
            custom.feed(data)
        }

        refreshPktsPerSec()
        onPacketStats?(stats)
    }

    private func flushLineBufIfDiagnostic() {
        guard !lineBuf.isEmpty else { return }
        if lineBuf.first == UInt8(ascii: "[") {
            if let s = String(bytes: lineBuf, encoding: .utf8) {
                onLogLine?(s)
                parseDiagnostic(s)
            }
        }
        lineBuf.removeAll(keepingCapacity: true)
    }

    /// Extract RSSI and other fields from firmware log lines like:
    ///   [RX] Packet OK type=0x00 seq=42 len=17 rssi=85
    ///   [RX] ok=5 crc_fail=0 overflow=0 seq_err=0 bytes=100 rssi=85 bits=800
    private func parseDiagnostic(_ s: String) {
        if let r = s.range(of: "rssi=") {
            let tail = s[r.upperBound...]
            let num = tail.prefix { $0.isNumber }
            if let v = Int(num) {
                stats.rssiPct = v
            }
        }
    }

    private func refreshPktsPerSec() {
        let now = Date()
        let elapsed = now.timeIntervalSince(pktWindowStart)
        if elapsed >= 1.0 {
            stats.pktsPerSec = Double(pktWindowCount) / elapsed
            pktWindowCount = 0
            pktWindowStart = now
        }
    }

    // MARK: - Frame handlers

    private func handleMavFrame(_ frame: MavlinkFrame) {
        stats.packetsOK &+= 1
        stats.mavlinkFrames &+= 1
        stats.lastPacketAt = Date()
        stats.lastMavlinkAt = stats.lastPacketAt
        pktWindowCount += 1

        if let prev = lastSeqBySys[frame.systemID] {
            let expected = prev &+ 1
            if frame.sequence != expected {
                let gap = Int(frame.sequence) &- Int(expected)
                let positive = gap < 0 ? gap + 256 : gap
                stats.droppedSeq &+= UInt32(positive)
            }
        }
        lastSeqBySys[frame.systemID] = frame.sequence

        guard let msg = MavlinkMessage.decode(msgID: frame.messageID, payload: frame.payload) else {
            onPacketStats?(stats)
            return
        }

        var snap = TelemetrySnapshot()
        switch msg {
        case .heartbeat(let hb):
            snap.armed = hb.armed
            snap.flightMode = heartbeatModeName(custom: hb.customMode, type: hb.type)
            lastHeartbeatAt = Date()

        case .sysStatus(let ss):
            snap.batteryVolts = Double(ss.voltageBatteryMV) / 1000.0
            if ss.currentBatteryCA >= 0 {
                snap.batteryCurrentA = Double(ss.currentBatteryCA) / 100.0
            }
            if ss.batteryRemaining >= 0 {
                snap.batteryRemaining = Int(ss.batteryRemaining)
            }

        case .gpsRawInt(let g):
            snap.gpsFixType = Int(g.fixType)
            snap.gpsSats    = Int(g.satellitesVisible)
            snap.gpsHDOP    = Double(g.eph) / 100.0

        case .attitude(let a):
            snap.rollDeg  = Double(a.roll)  * 180.0 / .pi
            snap.pitchDeg = Double(a.pitch) * 180.0 / .pi
            var y = Double(a.yaw)  * 180.0 / .pi
            if y < 0 { y += 360 }
            snap.yawDeg = y

        case .globalPositionInt(let g):
            snap.latitude  = Double(g.lat) / 1e7
            snap.longitude = Double(g.lon) / 1e7
            snap.altitudeM = Double(g.alt) / 1000.0
            snap.relAltM   = Double(g.relativeAlt) / 1000.0
            snap.yawDeg    = Double(g.hdg) / 100.0

        case .vfrHud(let v):
            snap.airspeedMS    = Double(v.airspeed)
            snap.groundspeedMS = Double(v.groundspeed)
            snap.climbMS       = Double(v.climb)
            snap.throttlePct   = Int(v.throttle)
            snap.altitudeM     = Double(v.alt)
        }

        onTelemetryUpdate?(snap)
    }

    private func handleCustomPacket(_ pkt: CustomPacketDecoder.Packet) {
        stats.packetsOK &+= 1
        stats.lastPacketAt = Date()
        pktWindowCount += 1

        if let t = CustomPacketDecoder.PktType(rawValue: pkt.type) {
            switch t {
            case .mavlink:
                mavlink.feed(pkt.payload)
            case .telem:
                if let s = TelemetrySummaryBytes.decode(pkt.payload) {
                    var snap = TelemetrySnapshot()
                    snap.latitude  = Double(s.latE7) / 1e7
                    snap.longitude = Double(s.lonE7) / 1e7
                    snap.altitudeM = Double(s.altMM) / 1000.0
                    snap.yawDeg    = Double(s.headingCD) / 100.0
                    snap.groundspeedMS = Double(s.speedCMS) / 100.0
                    snap.batteryVolts    = Double(s.battMV) / 1000.0
                    snap.batteryRemaining = Int(s.battPct)
                    snap.gpsSats   = Int(s.gpsSats)
                    snap.armed     = s.armed != 0
                    snap.flightMode = "mode \(s.flightMode)"
                    stats.rssiPct = Int(s.rssiEst)
                    onTelemetryUpdate?(snap)
                }
            case .spectrum:
                if let s = SpectrumFrameBytes.decode(pkt.payload) {
                    onSpectrum?(s.bins)
                }
            case .heartbeat:
                lastHeartbeatAt = Date()
            }
        }
    }

    private func heartbeatModeName(custom: UInt32, type: UInt8) -> String {
        // ArduPilot copter modes — partial map
        switch (type, custom) {
        case (2, 0):  return "STABILIZE"
        case (2, 1):  return "ACRO"
        case (2, 2):  return "ALT_HOLD"
        case (2, 3):  return "AUTO"
        case (2, 4):  return "GUIDED"
        case (2, 5):  return "LOITER"
        case (2, 6):  return "RTL"
        case (2, 9):  return "LAND"
        case (2, 16): return "POSHOLD"
        default:      return "mode \(custom)"
        }
    }
}
