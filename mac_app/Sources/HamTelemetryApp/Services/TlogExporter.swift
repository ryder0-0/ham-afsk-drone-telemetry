// FILE: mac_app/Sources/HamTelemetryApp/Services/TlogExporter.swift
//
// Convert a raw.bin capture into an APM .tlog file so Mission Planner /
// MAVExplorer / mavlogdump.py can open it.
//
// .tlog format (ArduPilot / MAVLink convention):
//
//   for each MAVLink frame in the capture:
//     [8-byte big-endian uint64   timestamp, microseconds since Unix epoch]
//     [N bytes                    full MAVLink frame on the wire]
//
// No other framing.  Readers stream through the file, find an MAVLink
// STX, and rewind if the 8 preceding bytes don't look like a plausible
// timestamp.
//
// Since raw.bin doesn't carry per-byte timestamps, we approximate one by
// distributing the file's wall-clock window (file creation → now) evenly
// across the captured bytes at 115200 8N1 nominal rate.  Good enough for
// relative-time analysis; absolute timestamps will be off by the
// difference between file-creation and first-byte-arrival, typically
// sub-second.

import Foundation

enum TlogExporter {

    enum ExportError: Error {
        case readFailed(Error)
        case writeFailed(Error)
        case nothingToWrite
    }

    /// Read bytes from `rawURL`, extract MAVLink v1/v2 frames, and write
    /// a .tlog at `outputURL`.  Returns the number of frames written.
    @discardableResult
    static func export(rawURL: URL, outputURL: URL, startDate: Date? = nil) throws -> Int {
        let data: Data
        do { data = try Data(contentsOf: rawURL) }
        catch { throw ExportError.readFailed(error) }

        let fileStart: Date
        if let d = startDate { fileStart = d }
        else if let attr = try? FileManager.default.attributesOfItem(atPath: rawURL.path),
                let d = attr[.creationDate] as? Date { fileStart = d }
        else { fileStart = Date() }

        // Extract frames with MavlinkDecoder.  We reuse the production
        // parser so quirks (signed frames, CRC failures) are consistent.
        let dec = MavlinkDecoder()
        var frames: [(offset: Int, bytes: [UInt8])] = []
        var byteCursor = 0

        dec.onFrame = { frame in
            frames.append((offset: byteCursor, bytes: frame.rawBytes))
        }
        // Feed byte-by-byte so we know each frame's ending offset.
        for b in data {
            byteCursor += 1
            dec.feed([b])
        }

        guard !frames.isEmpty else { throw ExportError.nothingToWrite }

        // Nominal byte rate (µs per byte) at 115200 8N1 → 86.8 µs.
        let usPerByte: Double = 1_000_000.0 / 11520.0
        let startUs = UInt64(fileStart.timeIntervalSince1970 * 1_000_000)

        var out = Data()
        out.reserveCapacity(frames.reduce(0) { $0 + 8 + $1.bytes.count })

        for f in frames {
            // Timestamp of the last byte of the frame.
            let frameUs = startUs &+ UInt64(Double(f.offset) * usPerByte)
            var be = frameUs.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            out.append(contentsOf: f.bytes)
        }

        do {
            try out.write(to: outputURL, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error)
        }
        return frames.count
    }

    /// Convenience: place the output .tlog next to the raw.bin it came from.
    @discardableResult
    static func exportAdjacent(rawURL: URL) throws -> (URL, Int) {
        let stem = rawURL.deletingPathExtension().lastPathComponent
        let parent = rawURL.deletingLastPathComponent()
        let tlog = parent.appendingPathComponent("\(stem).tlog")
        let n = try export(rawURL: rawURL, outputURL: tlog)
        return (tlog, n)
    }
}
