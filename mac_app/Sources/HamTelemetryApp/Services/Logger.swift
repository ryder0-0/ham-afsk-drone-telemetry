// FILE: mac_app/Sources/HamTelemetryApp/Services/Logger.swift
//
// Session logger.  Writes two files per session under
//   ~/Library/Application Support/HamTelemetryApp/sessions/<timestamp>/
//
//   raw.bin       — every received byte, appended as they arrive.  This is
//                   exactly what ReplayEngine consumes.
//   snapshots.jsonl — one JSON object per line per decoded TelemetrySnapshot,
//                     with ISO8601 timestamps.  Human-readable, easy to
//                     post-process with jq / pandas.
//
// Session start is deferred until the first byte arrives so we don't
// leave empty folders laying around.

import Foundation
import Combine

@MainActor
final class Logger: ObservableObject {

    @Published private(set) var isLogging: Bool = true
    @Published private(set) var sessionDir: URL? = nil
    @Published private(set) var bytesWritten: UInt64 = 0
    @Published private(set) var snapshotsWritten: UInt64 = 0

    private var rawHandle: FileHandle?
    private var snapHandle: FileHandle?
    private let iso = ISO8601DateFormatter()

    init() {
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func setLogging(_ on: Bool) {
        isLogging = on
        if !on { closeFiles() }
    }

    func logRawBytes(_ data: Data) {
        guard isLogging, !data.isEmpty else { return }
        ensureOpen()
        rawHandle?.write(data)
        bytesWritten &+= UInt64(data.count)
    }

    func logSnapshot(_ s: TelemetrySnapshot) {
        guard isLogging else { return }
        ensureOpen()
        // Build dictionary with only non-nil values — JSONSerialization
        // rejects embedded Optionals.
        var obj: [String: Any] = ["t": iso.string(from: s.timestamp)]
        if let v = s.latitude         { obj["lat"]   = v }
        if let v = s.longitude        { obj["lon"]   = v }
        if let v = s.altitudeM        { obj["alt_m"] = v }
        if let v = s.relAltM          { obj["rel_m"] = v }
        if let v = s.rollDeg          { obj["roll"]  = v }
        if let v = s.pitchDeg         { obj["pitch"] = v }
        if let v = s.yawDeg           { obj["yaw"]   = v }
        if let v = s.batteryVolts     { obj["vbat"]  = v }
        if let v = s.batteryCurrentA  { obj["ibat"]  = v }
        if let v = s.batteryRemaining { obj["bpct"]  = v }
        if let v = s.throttlePct      { obj["throt"] = v }
        if let v = s.gpsFixType       { obj["fix"]   = v }
        if let v = s.gpsSats          { obj["sats"]  = v }
        if let v = s.armed            { obj["armed"] = v }
        if let v = s.flightMode       { obj["mode"]  = v }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return }
        snapHandle?.write(data)
        snapHandle?.write(Data([0x0A]))  // newline
        snapshotsWritten &+= 1
    }

    // MARK: - Session plumbing

    private func ensureOpen() {
        if rawHandle != nil && snapHandle != nil { return }
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let appDir = base.appendingPathComponent("HamTelemetryApp", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let stamp = timestampFolderName()
        let session = appDir.appendingPathComponent(stamp, isDirectory: true)
        do {
            try fm.createDirectory(at: session, withIntermediateDirectories: true)
        } catch {
            return
        }
        let rawURL  = session.appendingPathComponent("raw.bin")
        let snapURL = session.appendingPathComponent("snapshots.jsonl")
        fm.createFile(atPath: rawURL.path,  contents: nil)
        fm.createFile(atPath: snapURL.path, contents: nil)
        rawHandle  = try? FileHandle(forWritingTo: rawURL)
        snapHandle = try? FileHandle(forWritingTo: snapURL)
        sessionDir = session
    }

    private func closeFiles() {
        try? rawHandle?.close()
        try? snapHandle?.close()
        rawHandle = nil
        snapHandle = nil
    }

    private func timestampFolderName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// List prior session folders (newest first).
    func listSessions() -> [URL] {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return [] }
        let sessions = base
            .appendingPathComponent("HamTelemetryApp", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let list = try? fm.contentsOfDirectory(at: sessions,
                                                     includingPropertiesForKeys: [.creationDateKey],
                                                     options: [.skipsHiddenFiles])
        else { return [] }
        return list.sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
    }
}
