// FILE: mac_app/Sources/HamTelemetryApp/Utilities/CRC16.swift
//
// CRC16-CCITT (X.25, poly 0x1021) — used for:
//   1. The project's custom packet framing (see firmware/common/src/packet.cpp)
//   2. MAVLink v1/v2 frame validation (with CRC_EXTRA byte per msgid)
//
// Both variants init to 0xFFFF.  MAVLink expects the CRC transmitted
// little-endian after the payload; for v1 after adding all header+payload
// bytes, we additionally update with the CRC_EXTRA byte from the message
// dialect.

import Foundation

enum CRC16 {

    /// Standard CRC16-CCITT update (MAVLink / X.25).
    @inline(__always)
    static func update(_ crc: UInt16, _ b: UInt8) -> UInt16 {
        var tmp = UInt16(b) ^ (crc & 0x00FF)
        tmp = (tmp ^ (tmp << 4)) & 0x00FF
        return (crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)
    }

    static func compute(_ bytes: [UInt8], init initial: UInt16 = 0xFFFF) -> UInt16 {
        var crc = initial
        for b in bytes { crc = update(crc, b) }
        return crc
    }

    static func compute<S: Sequence>(_ bytes: S, init initial: UInt16 = 0xFFFF)
        -> UInt16 where S.Element == UInt8
    {
        var crc = initial
        for b in bytes { crc = update(crc, b) }
        return crc
    }
}
