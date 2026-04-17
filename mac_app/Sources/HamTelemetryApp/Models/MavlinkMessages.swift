// FILE: mac_app/Sources/HamTelemetryApp/Models/MavlinkMessages.swift
//
// Plain-Swift decoders for the subset of MAVLink messages this app cares
// about.  We intentionally avoid pulling in the full pymavlink-generated
// Swift dialect — it is huge, and we only need six message types.
//
// All MAVLink numeric fields are **little-endian**.  Every message here
// carries its MAVLink v1 payload layout (byte offsets) as comments.

import Foundation

// MARK: - Message IDs

enum MavMsgID: UInt32 {
    case heartbeat           = 0
    case sysStatus           = 1
    case gpsRawInt           = 24
    case attitude            = 30
    case globalPositionInt   = 33
    case vfrHud              = 74
}

// MARK: - Strongly typed message structs

struct MavHeartbeat {
    let customMode: UInt32
    let type: UInt8
    let autopilot: UInt8
    let baseMode: UInt8
    let systemStatus: UInt8
    let mavlinkVersion: UInt8
    var armed: Bool { (baseMode & 0x80) != 0 }
}

struct MavSysStatus {
    let voltageBatteryMV: UInt16      // mV
    let currentBatteryCA: Int16       // cA (10 mA units, -1 = unknown)
    let dropRateCommPct: UInt16       // 0.01 %
    let errorsComm: UInt16
    let batteryRemaining: Int8        // %
}

struct MavGpsRawInt {
    let timeUsec: UInt64
    let lat: Int32                    // 1e7 degrees
    let lon: Int32
    let alt: Int32                    // mm
    let eph: UInt16                   // HDOP, cm
    let epv: UInt16
    let vel: UInt16                   // cm/s
    let cog: UInt16                   // course-over-ground, cdeg
    let fixType: UInt8
    let satellitesVisible: UInt8
}

struct MavAttitude {
    let timeBootMs: UInt32
    let roll: Float                   // rad
    let pitch: Float
    let yaw: Float
    let rollspeed: Float
    let pitchspeed: Float
    let yawspeed: Float
}

struct MavGlobalPositionInt {
    let timeBootMs: UInt32
    let lat: Int32                    // 1e7 degrees
    let lon: Int32
    let alt: Int32                    // mm AMSL
    let relativeAlt: Int32            // mm above home
    let vx: Int16                     // cm/s
    let vy: Int16
    let vz: Int16
    let hdg: UInt16                   // cdeg
}

struct MavVfrHud {
    let airspeed: Float               // m/s
    let groundspeed: Float            // m/s
    let alt: Float                    // m
    let climb: Float                  // m/s
    let heading: Int16                // deg
    let throttle: UInt16              // 0–100 %
}

// MARK: - Little-endian extraction helpers

enum LE {
    static func u16(_ b: UnsafePointer<UInt8>, _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }
    static func i16(_ b: UnsafePointer<UInt8>, _ o: Int) -> Int16 {
        Int16(bitPattern: u16(b, o))
    }
    static func u32(_ b: UnsafePointer<UInt8>, _ o: Int) -> UInt32 {
        UInt32(b[o]) |
        (UInt32(b[o + 1]) <<  8) |
        (UInt32(b[o + 2]) << 16) |
        (UInt32(b[o + 3]) << 24)
    }
    static func i32(_ b: UnsafePointer<UInt8>, _ o: Int) -> Int32 {
        Int32(bitPattern: u32(b, o))
    }
    static func u64(_ b: UnsafePointer<UInt8>, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * i) }
        return v
    }
    static func f32(_ b: UnsafePointer<UInt8>, _ o: Int) -> Float {
        Float(bitPattern: u32(b, o))
    }
}

// MARK: - Decode dispatch

enum MavlinkMessage {
    case heartbeat(MavHeartbeat)
    case sysStatus(MavSysStatus)
    case gpsRawInt(MavGpsRawInt)
    case attitude(MavAttitude)
    case globalPositionInt(MavGlobalPositionInt)
    case vfrHud(MavVfrHud)

    static func decode(msgID: UInt32, payload: [UInt8]) -> MavlinkMessage? {
        guard let id = MavMsgID(rawValue: msgID) else { return nil }
        return payload.withUnsafeBufferPointer { buf -> MavlinkMessage? in
            guard let p = buf.baseAddress else { return nil }
            switch id {
            case .heartbeat:
                guard payload.count >= 9 else { return nil }
                return .heartbeat(MavHeartbeat(
                    customMode:     LE.u32(p, 0),
                    type:           p[4],
                    autopilot:      p[5],
                    baseMode:       p[6],
                    systemStatus:   p[7],
                    mavlinkVersion: p[8]
                ))
            case .sysStatus:
                guard payload.count >= 31 else { return nil }
                return .sysStatus(MavSysStatus(
                    voltageBatteryMV: LE.u16(p, 14),
                    currentBatteryCA: LE.i16(p, 16),
                    dropRateCommPct:  LE.u16(p, 20),
                    errorsComm:       LE.u16(p, 22),
                    batteryRemaining: Int8(bitPattern: p[30])
                ))
            case .gpsRawInt:
                guard payload.count >= 30 else { return nil }
                return .gpsRawInt(MavGpsRawInt(
                    timeUsec:           LE.u64(p,  0),
                    lat:                LE.i32(p,  8),
                    lon:                LE.i32(p, 12),
                    alt:                LE.i32(p, 16),
                    eph:                LE.u16(p, 20),
                    epv:                LE.u16(p, 22),
                    vel:                LE.u16(p, 24),
                    cog:                LE.u16(p, 26),
                    fixType:            p[28],
                    satellitesVisible:  p[29]
                ))
            case .attitude:
                guard payload.count >= 28 else { return nil }
                return .attitude(MavAttitude(
                    timeBootMs:  LE.u32(p, 0),
                    roll:        LE.f32(p, 4),
                    pitch:       LE.f32(p, 8),
                    yaw:         LE.f32(p, 12),
                    rollspeed:   LE.f32(p, 16),
                    pitchspeed:  LE.f32(p, 20),
                    yawspeed:    LE.f32(p, 24)
                ))
            case .globalPositionInt:
                guard payload.count >= 28 else { return nil }
                return .globalPositionInt(MavGlobalPositionInt(
                    timeBootMs:   LE.u32(p,  0),
                    lat:          LE.i32(p,  4),
                    lon:          LE.i32(p,  8),
                    alt:          LE.i32(p, 12),
                    relativeAlt:  LE.i32(p, 16),
                    vx:           LE.i16(p, 20),
                    vy:           LE.i16(p, 22),
                    vz:           LE.i16(p, 24),
                    hdg:          LE.u16(p, 26)
                ))
            case .vfrHud:
                guard payload.count >= 20 else { return nil }
                return .vfrHud(MavVfrHud(
                    airspeed:     LE.f32(p,  0),
                    groundspeed:  LE.f32(p,  4),
                    alt:          LE.f32(p, 12),
                    climb:        LE.f32(p, 16),
                    heading:      LE.i16(p,  8),
                    throttle:     LE.u16(p, 10)
                ))
            }
        }
    }
}
