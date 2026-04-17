// FILE: mac_app/Sources/HamTelemetryApp/Services/MavlinkSignatureVerifier.swift
//
// MAVLink 2.0 packet signing verification.
//
// Per MAVLink 2.0 spec (https://mavlink.io/en/guide/message_signing.html):
//
//   signature = HMAC-SHA256(secret_key, H | header | payload | CRC | link_id | timestamp)[0..5]
//
// Where:
//   secret_key  = 32 bytes, user-supplied
//   H           = single byte 0xFD (v2 STX)
//   header      = 9 bytes (LEN, INCOMPAT, COMPAT, SEQ, SYS, COMP, MSGID × 3)
//   payload     = LEN bytes (NOT padded back up like CRC — only the on-wire bytes)
//   CRC         = 2 bytes (little-endian)
//   link_id     = 1 byte  (first byte of the signature trailer)
//   timestamp   = 6 bytes (next 6 bytes of signature trailer, µs / 10 since MAVLink epoch)
//   signature[] = last 6 bytes of signature trailer (HMAC truncated)
//
// Trailer layout (13 bytes total):
//   [link_id][timestamp × 6][hmac_truncated × 6]
//
// We optionally enforce monotonicity on the (link_id, timestamp) tuple to
// reject replay attacks — but only if enforceTimestamp is enabled.

import Foundation
import CryptoKit

final class MavlinkSignatureVerifier {

    /// 32-byte symmetric key.  nil disables verification.
    var secretKey: Data?

    /// If true, reject frames with a timestamp ≤ the last-seen timestamp
    /// for the same link_id (replay protection).  Default: true.
    var enforceTimestamp: Bool = true

    /// Last-seen (link_id → timestamp) per the MAVLink spec.
    private var lastTimestamp: [UInt8: UInt64] = [:]

    /// Result of verifying a frame's signature trailer.
    enum Result {
        case ok
        case noKey               // verifier not configured — caller may treat as unknown
        case badTrailerLength
        case signatureMismatch
        case replay              // timestamp went backwards
    }

    /// Verify a signed v2 frame.
    /// - Parameters:
    ///   - frameBytes: The full on-wire frame **without** the 13-byte
    ///     signature trailer — i.e. STX + header + payload + CRC.
    ///   - trailer: The 13 trailing bytes (link_id + timestamp + hmac).
    func verify(frameBytes: [UInt8], trailer: [UInt8]) -> Result {
        guard let key = secretKey else { return .noKey }
        guard trailer.count == 13 else { return .badTrailerLength }

        let linkID = trailer[0]
        var ts: UInt64 = 0
        for i in 0..<6 { ts |= UInt64(trailer[1 + i]) << (8 * i) }
        let providedSig = Array(trailer[7..<13])

        // Replay check (µs-since-MAVLink-epoch / 10 is monotonic per link)
        if enforceTimestamp, let last = lastTimestamp[linkID], ts <= last {
            return .replay
        }

        // HMAC input = frameBytes + link_id + timestamp (7 bytes of trailer)
        var hmacInput = Data()
        hmacInput.append(contentsOf: frameBytes)
        hmacInput.append(contentsOf: trailer[0..<7])

        let mac = HMAC<SHA256>.authenticationCode(for: hmacInput,
                                                   using: SymmetricKey(data: key))
        let macBytes = Array(mac).prefix(6)

        guard Array(macBytes) == providedSig else {
            return .signatureMismatch
        }

        lastTimestamp[linkID] = ts
        return .ok
    }

    /// Reset replay state (call when key changes or user restarts session).
    func resetReplayState() {
        lastTimestamp.removeAll()
    }
}
