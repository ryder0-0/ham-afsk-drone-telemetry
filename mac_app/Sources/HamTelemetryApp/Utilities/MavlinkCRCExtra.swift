// FILE: mac_app/Sources/HamTelemetryApp/Utilities/MavlinkCRCExtra.swift
//
// MAVLink "CRC_EXTRA" byte per message ID.  Appended to the X.25 CRC
// accumulator after the last payload byte to validate that sender and
// receiver agree on the message schema.
//
// Values pulled from the generated common.xml dialect (pymavlink).
// Only the message types this app decodes are listed here — unknown msgids
// return nil, and the decoder then treats the frame as schema-unverified.

import Foundation

enum MavlinkCRCExtra {

    /// Returns the CRC_EXTRA byte for `msgID`, or nil if unknown.
    static func byte(for msgID: UInt32) -> UInt8? {
        switch msgID {
        case 0:   return 50    // HEARTBEAT
        case 1:   return 124   // SYS_STATUS
        case 24:  return 24    // GPS_RAW_INT
        case 30:  return 39    // ATTITUDE
        case 33:  return 104   // GLOBAL_POSITION_INT
        case 74:  return 20    // VFR_HUD
        default:  return nil
        }
    }

    /// Known minimum payload lengths (post-truncation for v2).  Used to
    /// right-pad a v2 payload before CRC validation, since v2 strips trailing
    /// zero bytes on the wire.
    static func minPayloadLen(for msgID: UInt32) -> Int? {
        switch msgID {
        case 0:   return 9
        case 1:   return 31
        case 24:  return 30
        case 30:  return 28
        case 33:  return 28
        case 74:  return 20
        default:  return nil
        }
    }
}
