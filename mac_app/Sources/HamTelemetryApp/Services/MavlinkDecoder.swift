// FILE: mac_app/Sources/HamTelemetryApp/Services/MavlinkDecoder.swift
//
// Streaming MAVLink v1/v2 frame parser.
//
// v1 wire format:
//   [0xFE][LEN][SEQ][SYS][COMP][MSGID]  payload(LEN bytes)  [CRCl][CRCh]
//
// v2 wire format:
//   [0xFD][LEN][INCOMPAT][COMPAT][SEQ][SYS][COMP][MSGID(3)]
//     payload(LEN bytes)  [CRCl][CRCh]  [signature(13)?]
//
// If INCOMPAT & 0x01 the frame is signed and carries a trailing 13-byte
// signature that we simply skip (we don't verify signatures).  Any other
// INCOMPAT bit set → unknown extension, drop the frame.
//
// CRC validation: X.25 (see CRC16) over every byte from LEN through the
// last payload byte, followed by the CRC_EXTRA byte for the msgid.  If the
// msgid is not in our table we still pass the frame through (with a flag)
// because the caller may want the raw bytes even if we can't verify them.
//
// The parser is robust to byte-stream garbage — it hunts for the STX byte
// and only commits to a frame once it's fully buffered.

import Foundation

struct MavlinkFrame {
    var version: Int          // 1 or 2
    var sequence: UInt8
    var systemID: UInt8
    var componentID: UInt8
    var messageID: UInt32
    var payload: [UInt8]
    var crcVerified: Bool     // true if CRC matched; false if msgid unknown
    var rawBytes: [UInt8]     // full wire bytes for logging

    /// v2 only.  nil on unsigned frames or when no verifier key is set.
    /// .some(true)  → HMAC-SHA256 matched and timestamp was monotonic
    /// .some(false) → frame was signed but failed verification / was a replay
    var signatureValid: Bool?
}

final class MavlinkDecoder {

    // Parser state machine
    private enum State { case idle, header, payload, crc1, crc2, sigCollect }

    private var state: State = .idle
    private var isV2 = false
    private var buf: [UInt8] = []
    private var payloadLen = 0
    private var sigExpected = 0          // v2 signature bytes we still need
    private var sigBuf: [UInt8] = []
    private var pendingFrame: MavlinkFrame?   // held until signature arrives

    // Callbacks
    var onFrame:    ((MavlinkFrame) -> Void)?
    var onBadCRC:   ((UInt32) -> Void)?
    var onDropped:  ((UInt8, String) -> Void)?   // (byte, reason)

    /// Optional signature verifier for MAVLink v2 signed frames.  When set,
    /// signed frames have `signatureValid` populated on the emitted frame.
    var signatureVerifier: MavlinkSignatureVerifier?

    // Counters
    private(set) var framesOK:          UInt32 = 0
    private(set) var framesCRCFail:     UInt32 = 0
    private(set) var framesUnknown:     UInt32 = 0
    private(set) var framesSigFail:     UInt32 = 0
    private(set) var framesSigOK:       UInt32 = 0
    private(set) var bytesDiscarded:    UInt32 = 0

    static let STX_V1: UInt8 = 0xFE
    static let STX_V2: UInt8 = 0xFD

    func feed(_ bytes: Data) {
        for b in bytes { step(b) }
    }

    func feed(_ bytes: [UInt8]) {
        for b in bytes { step(b) }
    }

    // MARK: - Byte-by-byte state machine

    private func step(_ b: UInt8) {
        switch state {
        case .idle:
            if b == Self.STX_V1 {
                isV2 = false
                buf = [b]
                state = .header
            } else if b == Self.STX_V2 {
                isV2 = true
                buf = [b]
                state = .header
            } else {
                bytesDiscarded &+= 1
            }

        case .header:
            buf.append(b)
            let needed = isV2 ? 10 : 6
            if buf.count == needed {
                payloadLen = Int(buf[1])
                if isV2 {
                    let incompat = buf[2]
                    sigExpected = (incompat & 0x01) != 0 ? 13 : 0
                    if (incompat & ~UInt8(0x01)) != 0 {
                        onDropped?(incompat, "unsupported INCOMPAT")
                        resetToIdle()
                        return
                    }
                }
                state = payloadLen > 0 ? .payload : .crc1
            }

        case .payload:
            buf.append(b)
            let fixed = isV2 ? 10 : 6
            if buf.count == fixed + payloadLen {
                state = .crc1
            }

        case .crc1:
            buf.append(b)
            state = .crc2

        case .crc2:
            buf.append(b)
            finishFrameOrSkipSignature()

        case .sigCollect:
            sigBuf.append(b)
            if sigBuf.count >= sigExpected {
                finishSignedFrame()
            }
        }
    }

    private func finishSignedFrame() {
        guard var frame = pendingFrame else {
            resetToIdle()
            return
        }
        // Verify the signature.  frame.rawBytes here is the pre-signature
        // bytes (STX + header + payload + CRC) — we pass it verbatim.
        if let verifier = signatureVerifier {
            let result = verifier.verify(frameBytes: frame.rawBytes, trailer: sigBuf)
            switch result {
            case .ok:
                frame.signatureValid = true
                framesSigOK &+= 1
            case .noKey:
                frame.signatureValid = nil
            case .badTrailerLength, .signatureMismatch, .replay:
                frame.signatureValid = false
                framesSigFail &+= 1
            }
        } else {
            frame.signatureValid = nil
        }
        // Append the trailer to rawBytes so on-disk captures are faithful.
        frame.rawBytes.append(contentsOf: sigBuf)
        onFrame?(frame)
        resetToIdle()
    }

    private func finishFrameOrSkipSignature() {
        // Validate the CRC now
        let fixed = isV2 ? 10 : 6
        let payloadEnd = fixed + payloadLen
        // CRC covers bytes [1 ..< payloadEnd] plus CRC_EXTRA
        let msgID: UInt32
        let seq: UInt8
        let sys: UInt8
        let comp: UInt8
        if isV2 {
            seq  = buf[4]
            sys  = buf[5]
            comp = buf[6]
            msgID = UInt32(buf[7]) | (UInt32(buf[8]) << 8) | (UInt32(buf[9]) << 16)
        } else {
            seq  = buf[2]
            sys  = buf[3]
            comp = buf[4]
            msgID = UInt32(buf[5])
        }

        // For v2, the payload on the wire has trailing zeros truncated.
        // Pad back up to the min length before CRC so CRC_EXTRA math matches.
        var crcPayload = Array(buf[fixed ..< payloadEnd])
        if isV2, let minLen = MavlinkCRCExtra.minPayloadLen(for: msgID), crcPayload.count < minLen {
            crcPayload.append(contentsOf: repeatElement(0, count: minLen - crcPayload.count))
        }

        // Start CRC at the LEN byte, include the full (padded) payload.
        var crc: UInt16 = 0xFFFF
        crc = CRC16.update(crc, buf[1])                    // LEN
        if isV2 {
            crc = CRC16.update(crc, buf[2])                // INCOMPAT
            crc = CRC16.update(crc, buf[3])                // COMPAT
        }
        crc = CRC16.update(crc, seq)
        crc = CRC16.update(crc, sys)
        crc = CRC16.update(crc, comp)
        if isV2 {
            crc = CRC16.update(crc, buf[7])
            crc = CRC16.update(crc, buf[8])
            crc = CRC16.update(crc, buf[9])
        } else {
            crc = CRC16.update(crc, buf[5])
        }
        for b in crcPayload { crc = CRC16.update(crc, b) }

        let verified: Bool
        if let extra = MavlinkCRCExtra.byte(for: msgID) {
            crc = CRC16.update(crc, extra)
            let crcRx = UInt16(buf[payloadEnd]) | (UInt16(buf[payloadEnd + 1]) << 8)
            verified = (crc == crcRx)
            if !verified {
                framesCRCFail &+= 1
                onBadCRC?(msgID)
                // We still drop the frame when CRC fails for known msgids.
                if isV2 && sigExpected > 0 {
                    // Consume the signature trailer so the next frame parses
                    // correctly, but discard the frame itself.
                    pendingFrame = nil
                    sigBuf.removeAll(keepingCapacity: true)
                    state = .sigCollect
                    return
                }
                resetToIdle()
                return
            }
        } else {
            verified = false
            framesUnknown &+= 1
        }

        framesOK &+= 1

        let payloadSlice = Array(buf[fixed ..< payloadEnd])
        let frame = MavlinkFrame(
            version:     isV2 ? 2 : 1,
            sequence:    seq,
            systemID:    sys,
            componentID: comp,
            messageID:   msgID,
            payload:     payloadSlice,
            crcVerified: verified,
            rawBytes:    buf,
            signatureValid: nil
        )

        if isV2 && sigExpected > 0 {
            // Hold the frame; emit it once the signature trailer arrives.
            pendingFrame = frame
            sigBuf.removeAll(keepingCapacity: true)
            state = .sigCollect
        } else {
            onFrame?(frame)
            resetToIdle()
        }
    }

    private func resetToIdle() {
        state = .idle
        buf.removeAll(keepingCapacity: true)
        sigBuf.removeAll(keepingCapacity: true)
        pendingFrame = nil
        payloadLen = 0
        sigExpected = 0
    }
}
