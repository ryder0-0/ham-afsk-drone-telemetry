// FILE: mac_app/Sources/HamTelemetryApp/Services/ReplayEngine.swift
//
// Reads a raw.bin capture written by Logger and feeds it back into the
// decoder pipeline at configurable speed (0.25× … 8×).  Supports pause,
// resume, and scrub-by-offset.
//
// Without per-byte timestamps in raw.bin we approximate "original timing"
// by assuming the receiver's USB serial runs at 115200 baud → 11520 bytes
// per wall-clock second.  This is accurate within ±10 % for chunked bursts,
// which is plenty for UI playback.

import Foundation
import Combine

@MainActor
final class ReplayEngine: ObservableObject {

    enum State { case idle, playing, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var fileURL: URL?  = nil
    @Published private(set) var totalBytes: Int = 0
    @Published private(set) var cursor:     Int = 0
    @Published var speed: Double = 1.0

    /// Nominal wire rate of the saved stream (bytes/sec).  115200 8N1 ≈ 11520 B/s.
    let nominalByteRate: Double = 11520.0

    /// Chunk size consumed per tick (bytes).  Smaller = smoother but more ticks.
    private let chunkSize = 256

    private var data: Data = Data()
    private var task: Task<Void, Never>?

    var onBytesReplayed: ((Data) -> Void)?

    // MARK: - Public controls

    func load(url: URL) {
        stop()
        do {
            self.data = try Data(contentsOf: url)
            self.fileURL = url
            self.totalBytes = data.count
            self.cursor = 0
        } catch {
            self.data = Data()
            self.totalBytes = 0
            self.cursor = 0
        }
    }

    func play() {
        guard !data.isEmpty else { return }
        if state == .playing { return }
        state = .playing
        task?.cancel()
        task = Task { [weak self] in await self?.runLoop() }
    }

    func pause() {
        if state == .playing { state = .paused }
    }

    func stop() {
        task?.cancel()
        task = nil
        state = .idle
        cursor = 0
    }

    func scrub(to fraction: Double) {
        let clamped = max(0.0, min(1.0, fraction))
        cursor = Int(Double(totalBytes) * clamped)
    }

    // MARK: - Playback loop

    private func runLoop() async {
        while !Task.isCancelled, state == .playing, cursor < data.count {
            let end = min(data.count, cursor + chunkSize)
            let slice = data.subdata(in: cursor ..< end)
            onBytesReplayed?(slice)
            cursor = end

            let sleepSec = Double(slice.count) / (nominalByteRate * max(0.1, speed))
            let ns = UInt64(sleepSec * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }
        if cursor >= data.count {
            state = .idle
        }
    }
}
