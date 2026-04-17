// FILE: mac_app/Sources/HamTelemetryApp/Models/TelemetryModel.swift
//
// Central @ObservableObject that holds the latest decoded telemetry state
// and link statistics.  Every SwiftUI view reads from this.
//
// Intentionally plain Swift values (no Codable wizardry) — makes diffing in
// Combine/SwiftUI cheap and makes it trivial to snapshot for the log file.

import Foundation
import Combine
import CoreLocation

// MARK: - Snapshots produced by decoders

struct TelemetrySnapshot {
    var timestamp: Date = Date()

    // Position
    var latitude:  Double?     // degrees
    var longitude: Double?
    var altitudeM: Double?     // m AMSL
    var relAltM:   Double?     // m AGL

    // Attitude
    var rollDeg:  Double?
    var pitchDeg: Double?
    var yawDeg:   Double?      // heading, 0–360

    // Speed
    var airspeedMS:    Double?
    var groundspeedMS: Double?
    var climbMS:       Double?

    // Power
    var batteryVolts:     Double?
    var batteryCurrentA:  Double?
    var batteryRemaining: Int?    // %
    var throttlePct:      Int?

    // GPS
    var gpsFixType: Int?
    var gpsSats:    Int?
    var gpsHDOP:    Double?

    // System
    var armed:      Bool?
    var flightMode: String?
    var heartbeatAge: TimeInterval?
}

struct LinkStats {
    var packetsOK:     UInt32 = 0
    var crcFails:      UInt32 = 0
    var mavlinkFrames: UInt32 = 0
    var bytesReceived: UInt64 = 0
    var rssiPct:       Int    = 0
    var lastPacketAt:  Date?
    var lastMavlinkAt: Date?
    var droppedSeq:    UInt32 = 0

    /// Packets-per-second over the last sample window.
    var pktsPerSec: Double = 0

    /// Link "health" heuristic combining RSSI + crc fail rate + recency.
    var healthPct: Int {
        let now = Date()
        let recency = lastPacketAt.map { max(0, 1 - min(10, now.timeIntervalSince($0)) / 10) } ?? 0
        let errRate = (crcFails + packetsOK) == 0 ? 0 : Double(crcFails) / Double(crcFails + packetsOK)
        let rssi = Double(rssiPct) / 100.0
        let score = 0.4 * recency + 0.4 * rssi + 0.2 * (1 - errRate)
        return Int((score * 100).rounded())
    }
}

// MARK: - Observable model

@MainActor
final class TelemetryModel: ObservableObject {

    @Published var current:    TelemetrySnapshot = .init()
    @Published var link:       LinkStats         = .init()
    @Published var trail:      [CLLocationCoordinate2D] = []
    @Published var altHistory: [TimeSample] = []
    @Published var battHistory:[TimeSample] = []
    @Published var rssiHistory:[TimeSample] = []
    @Published var logLines:   [String] = []

    /// Rolling waterfall of audio-band spectrum frames (newest last).
    /// Each column is 32 bins; rows cap at `maxSpectrumRows`.
    @Published var spectrum:   [[Float]] = []
    let maxSpectrumRows = 240

    struct TimeSample: Identifiable {
        let id = UUID()
        let t: Date
        let value: Double
    }

    private let maxHistory = 600   // ~10 min at 1 Hz

    func apply(_ s: TelemetrySnapshot) {
        // Merge non-nil fields from the incoming snapshot into `current`.
        if let v = s.latitude     { current.latitude     = v }
        if let v = s.longitude    { current.longitude    = v }
        if let v = s.altitudeM    { current.altitudeM    = v }
        if let v = s.relAltM      { current.relAltM      = v }
        if let v = s.rollDeg      { current.rollDeg      = v }
        if let v = s.pitchDeg     { current.pitchDeg     = v }
        if let v = s.yawDeg       { current.yawDeg       = v }
        if let v = s.airspeedMS   { current.airspeedMS   = v }
        if let v = s.groundspeedMS { current.groundspeedMS = v }
        if let v = s.climbMS      { current.climbMS      = v }
        if let v = s.batteryVolts { current.batteryVolts = v }
        if let v = s.batteryCurrentA  { current.batteryCurrentA  = v }
        if let v = s.batteryRemaining { current.batteryRemaining = v }
        if let v = s.throttlePct  { current.throttlePct  = v }
        if let v = s.gpsFixType   { current.gpsFixType   = v }
        if let v = s.gpsSats      { current.gpsSats      = v }
        if let v = s.gpsHDOP      { current.gpsHDOP      = v }
        if let v = s.armed        { current.armed        = v }
        if let v = s.flightMode   { current.flightMode   = v }
        current.timestamp = s.timestamp

        // Append to trail + history
        if let lat = current.latitude, let lon = current.longitude {
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if trail.last?.latitude != lat || trail.last?.longitude != lon {
                trail.append(c)
                if trail.count > 5000 { trail.removeFirst(trail.count - 5000) }
            }
        }
        let now = Date()
        if let alt = current.relAltM ?? current.altitudeM {
            altHistory.append(.init(t: now, value: alt))
            if altHistory.count > maxHistory { altHistory.removeFirst() }
        }
        if let v = current.batteryVolts {
            battHistory.append(.init(t: now, value: v))
            if battHistory.count > maxHistory { battHistory.removeFirst() }
        }
    }

    func appendSpectrum(_ bins: [Float]) {
        spectrum.append(bins)
        if spectrum.count > maxSpectrumRows {
            spectrum.removeFirst(spectrum.count - maxSpectrumRows)
        }
    }

    func updateLinkStats(_ s: LinkStats) {
        self.link = s
        let now = Date()
        rssiHistory.append(.init(t: now, value: Double(s.rssiPct)))
        if rssiHistory.count > maxHistory { rssiHistory.removeFirst() }
    }

    func appendLogLine(_ line: String) {
        logLines.append(line)
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    func reset() {
        current = .init()
        link    = .init()
        trail.removeAll()
        altHistory.removeAll()
        battHistory.removeAll()
        rssiHistory.removeAll()
    }
}
