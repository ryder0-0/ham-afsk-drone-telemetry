// FILE: mac_app/Sources/HamTelemetryApp/Services/CustomPacketDecoder.swift
//
// Fallback parser for this project's custom Bell 202 packet framing (see
// firmware/common/src/packet.cpp).  Used for two reasons:
//
//   1. The receiver firmware emits PKT_TYPE_TELEM (0x01) 24-byte compressed
//      telemetry summaries when the drone transmitter runs in summary mode.
//      These are **not** MAVLink and only this decoder understands them.
//
//   2. The receiver also emits human-readable "[RX] ..." diagnostic lines
//      interleaved with the binary MAVLink stream on USB serial.  We don't
//      try to frame-sync on those here — that filter lives in PacketDecoder.
//
// Wire format (from firmware/common/src/packet.cpp):
//
//   [25 × 0xAA preamble]  ← already stripped on USB serial? NO — actually
//                           on USB serial the receiver writes out the
//                           PKT_TYPE_MAVLINK *payload only* (via
//                           MavlinkOutput::update) and PKT_TYPE_TELEM
//                           struct bytes are also emitted raw.  So on the
//                           USB path we really only see:
//                             • MAVLink bytes (handled by MavlinkDecoder)
//                             • 24-byte TelemetrySummary blobs
//                             • ASCII [RX] log lines
//
// For completeness this decoder ALSO knows how to chew the full on-wire
// Bell-202 framing if you ever pipe raw demodulator bytes into it — useful
// for the replay mode where you might be feeding a saved .bin capture.

import Foundation

struct TelemetrySummaryBytes {
    // Must mirror firmware/common/include/packet.h — 24 bytes exact.
    var latE7:      Int32
    var lonE7:      Int32
    var altMM:      Int32
    var headingCD:  Int16
    var speedCMS:   Int16
    var battMV:     Int16
    var battPct:    UInt8
    var gpsSats:    UInt8
    var flightMode: UInt8
    var armed:      UInt8
    var rssiEst:    Int16

    static let wireSize = 24

    static func decode(_ b: [UInt8]) -> TelemetrySummaryBytes? {
        guard b.count >= wireSize else { return nil }
        return b.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return nil }
            return TelemetrySummaryBytes(
                latE7:      LE.i32(p, 0),
                lonE7:      LE.i32(p, 4),
                altMM:      LE.i32(p, 8),
                headingCD:  LE.i16(p, 12),
                speedCMS:   LE.i16(p, 14),
                battMV:     LE.i16(p, 16),
                battPct:    p[18],
                gpsSats:    p[19],
                flightMode: p[20],
                armed:      p[21],
                rssiEst:    LE.i16(p, 22)
            )
        }
    }
}

/// Decoded spectrum frame (32 bins of MARK/SPACE band energy).
struct SpectrumFrameBytes {
    static let binCount = 32
    static let wireSize = 4 + 2 * binCount
    var millisStamp: UInt32
    var bins:        [Float]   // normalised 0..1

    static func decode(_ b: [UInt8]) -> SpectrumFrameBytes? {
        guard b.count >= wireSize else { return nil }
        return b.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return nil }
            let stamp = LE.u32(p, 0)
            var bins = [Float](repeating: 0, count: binCount)
            for i in 0..<binCount {
                let raw = LE.u16(p, 4 + i * 2)
                bins[i] = Float(raw) / Float(UInt16.max)
            }
            return SpectrumFrameBytes(millisStamp: stamp, bins: bins)
        }
    }
}

/// Framing state machine for the on-wire Bell-202 packet format.
/// Used only when consuming raw demodulator output (e.g., replay of a
/// saved bitstream), not for the USB receiver path.
final class CustomPacketDecoder {

    enum PktType: UInt8 {
        case mavlink   = 0x00
        case telem     = 0x01
        case spectrum  = 0x02
        case heartbeat = 0xFF
    }

    struct Packet {
        let type: UInt8
        let seq:  UInt8
        let payload: [UInt8]
    }

    private enum State {
        case preamble, sync1, type, seq, lenLo, lenHi, payload, crcLo, crcHi
    }

    private var state: State = .preamble
    private var preambleRun = 0
    private var pktType: UInt8 = 0
    private var pktSeq:  UInt8 = 0
    private var pktLen:  UInt16 = 0
    private var payload: [UInt8] = []
    private var crcAcc: UInt16 = 0xFFFF
    private var crcRx:  UInt16 = 0

    private let syncByte0: UInt8 = 0x2D
    private let syncByte1: UInt8 = 0xD4
    private let preambleByte: UInt8 = 0xAA
    private let preambleThreshold = 3    // need ≥ 3 × 0xAA before 0x2D

    var onPacket: ((Packet) -> Void)?
    var onCRCFail: (() -> Void)?

    private(set) var packetsOK: UInt32 = 0
    private(set) var crcFails:  UInt32 = 0

    func feed(_ bytes: Data) {
        for b in bytes { step(b) }
    }

    private func step(_ b: UInt8) {
        switch state {
        case .preamble:
            if b == preambleByte { preambleRun += 1 }
            else if b == syncByte0 && preambleRun >= preambleThreshold {
                crcAcc = 0xFFFF
                crcAcc = CRC16.update(crcAcc, b)
                state = .sync1
            } else {
                preambleRun = 0
            }

        case .sync1:
            if b == syncByte1 {
                crcAcc = CRC16.update(crcAcc, b)
                state = .type
            } else {
                resetToPreamble()
            }

        case .type:
            pktType = b
            crcAcc = CRC16.update(crcAcc, b)
            state = .seq

        case .seq:
            pktSeq = b
            crcAcc = CRC16.update(crcAcc, b)
            state = .lenLo

        case .lenLo:
            pktLen = UInt16(b)
            crcAcc = CRC16.update(crcAcc, b)
            state = .lenHi

        case .lenHi:
            pktLen |= UInt16(b) << 8
            crcAcc = CRC16.update(crcAcc, b)
            if pktLen > 300 {
                resetToPreamble()
            } else if pktLen == 0 {
                state = .crcLo
            } else {
                payload.removeAll(keepingCapacity: true)
                payload.reserveCapacity(Int(pktLen))
                state = .payload
            }

        case .payload:
            payload.append(b)
            crcAcc = CRC16.update(crcAcc, b)
            if payload.count == Int(pktLen) { state = .crcLo }

        case .crcLo:
            crcRx = UInt16(b)
            state = .crcHi

        case .crcHi:
            crcRx |= UInt16(b) << 8
            if crcRx == crcAcc {
                packetsOK &+= 1
                onPacket?(Packet(type: pktType, seq: pktSeq, payload: payload))
            } else {
                crcFails &+= 1
                onCRCFail?()
            }
            resetToPreamble()
        }
    }

    private func resetToPreamble() {
        state = .preamble
        preambleRun = 0
        payload.removeAll(keepingCapacity: true)
    }
}
