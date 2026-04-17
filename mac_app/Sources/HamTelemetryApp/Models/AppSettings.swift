// FILE: mac_app/Sources/HamTelemetryApp/Models/AppSettings.swift
//
// Persistent app settings backed by UserDefaults.  Rendered by SettingsView.
//
// Surface:
//   • Battery profile (chemistry + cell count)
//   • MAVLink signing key (hex-encoded, 32 bytes) — optional, enables v2
//     signature verification via MavlinkSignatureVerifier
//   • Preferred input source (serial vs. UDP) and default UDP port
//
// Everything lives on MainActor so the SwiftUI bindings are simple.

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {

    // MARK: Published state

    @Published var batteryProfileID: String {
        didSet { UserDefaults.standard.set(batteryProfileID, forKey: Keys.batteryProfileID) }
    }

    @Published var signingKeyHex: String {
        didSet { UserDefaults.standard.set(signingKeyHex, forKey: Keys.signingKeyHex) }
    }

    @Published var enforceSignatureTimestamp: Bool {
        didSet { UserDefaults.standard.set(enforceSignatureTimestamp,
                                           forKey: Keys.enforceSignatureTimestamp) }
    }

    @Published var preferredSource: InputSource {
        didSet { UserDefaults.standard.set(preferredSource.rawValue, forKey: Keys.preferredSource) }
    }

    @Published var udpPort: Int {
        didSet { UserDefaults.standard.set(udpPort, forKey: Keys.udpPort) }
    }

    enum InputSource: String, CaseIterable, Identifiable {
        case serial, udp
        var id: String { rawValue }
        var label: String {
            switch self {
            case .serial: return "Serial"
            case .udp:    return "UDP"
            }
        }
    }

    // MARK: Derived

    var batteryProfile: BatteryProfile {
        BatteryProfile.presets.first { $0.id == batteryProfileID }
            ?? BatteryProfile.default
    }

    /// Returns 32-byte signing key if `signingKeyHex` is a valid 64-char
    /// hex string, otherwise nil.
    var signingKey: Data? {
        let clean = signingKeyHex.replacingOccurrences(of: " ", with: "")
        guard clean.count == 64 else { return nil }
        var out = Data(capacity: 32)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    // MARK: Init

    init() {
        let d = UserDefaults.standard
        self.batteryProfileID = d.string(forKey: Keys.batteryProfileID)
            ?? BatteryProfile.default.id
        self.signingKeyHex = d.string(forKey: Keys.signingKeyHex) ?? ""
        self.enforceSignatureTimestamp = (d.object(forKey: Keys.enforceSignatureTimestamp)
                                          as? Bool) ?? true
        self.preferredSource = InputSource(rawValue: d.string(forKey: Keys.preferredSource) ?? "serial")
            ?? .serial
        self.udpPort = d.integer(forKey: Keys.udpPort) == 0 ? 14550
                                                            : d.integer(forKey: Keys.udpPort)
    }

    // MARK: Keys

    private enum Keys {
        static let batteryProfileID          = "battery.profileID"
        static let signingKeyHex             = "mavlink.signingKeyHex"
        static let enforceSignatureTimestamp = "mavlink.enforceTimestamp"
        static let preferredSource           = "source.preferred"
        static let udpPort                   = "source.udpPort"
    }
}
