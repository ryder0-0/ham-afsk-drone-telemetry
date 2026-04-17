// FILE: mac_app/Sources/HamTelemetryApp/Models/BatteryProfile.swift
//
// Battery chemistry + cell-count descriptor used by the Power tab to
// colour-grade the voltage reading.  Thresholds are nominal and can be
// overridden per-profile from the Settings sheet.
//
// The "green / orange / red" bands are picked so:
//   green  → > 20 % remaining (healthy)
//   orange → 10 – 20 % (land soon)
//   red    → < 10 % (critical)
//
// For LiPo/LiHV these map to the conventional 3.5 V / 3.3 V per-cell warn
// thresholds.  Li-ion discharge curves are gentler so the bands sit lower.

import Foundation

struct BatteryProfile: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let cellCount: Int
    let nominalPerCell: Double
    let greenPerCell:  Double
    let orangePerCell: Double
    let redPerCell:    Double

    var nominalV: Double { Double(cellCount) * nominalPerCell }
    var greenV:   Double { Double(cellCount) * greenPerCell }
    var orangeV:  Double { Double(cellCount) * orangePerCell }
    var redV:     Double { Double(cellCount) * redPerCell }

    /// Presets covering the common cases.  Extend as needed.
    static let presets: [BatteryProfile] = [
        .lipo(cells: 2),
        .lipo(cells: 3),
        .lipo(cells: 4),
        .lipo(cells: 6),
        .lihv(cells: 4),
        .lihv(cells: 6),
        .liion(cells: 3),
        .liion(cells: 4),
        .liion(cells: 6),
    ]

    static let `default`: BatteryProfile = .lipo(cells: 4)

    // MARK: Factory helpers

    /// Standard LiPo: 3.7 V nominal, 3.8 / 3.5 / 3.3 V warn thresholds.
    static func lipo(cells n: Int) -> BatteryProfile {
        BatteryProfile(
            id: "lipo-\(n)s",
            name: "\(n)S LiPo",
            cellCount: n,
            nominalPerCell: 3.7,
            greenPerCell:  3.8,
            orangePerCell: 3.5,
            redPerCell:    3.3
        )
    }

    /// High-voltage LiPo: 3.8 V nominal (full = 4.35 V), warn at 3.6 / 3.4.
    static func lihv(cells n: Int) -> BatteryProfile {
        BatteryProfile(
            id: "lihv-\(n)s",
            name: "\(n)S LiHV",
            cellCount: n,
            nominalPerCell: 3.8,
            greenPerCell:  3.9,
            orangePerCell: 3.6,
            redPerCell:    3.4
        )
    }

    /// Li-ion (18650 / 21700): flatter curve, warn at 3.5 / 3.2 / 3.0.
    static func liion(cells n: Int) -> BatteryProfile {
        BatteryProfile(
            id: "liion-\(n)s",
            name: "\(n)S Li-ion",
            cellCount: n,
            nominalPerCell: 3.6,
            greenPerCell:  3.5,
            orangePerCell: 3.2,
            redPerCell:    3.0
        )
    }

    /// Classify a measured pack voltage.
    enum Health { case green, orange, red, unknown }
    func classify(voltage v: Double) -> Health {
        if v >= greenV  { return .green }
        if v >= orangeV { return .orange }
        if v >= redV    { return .red }
        return .red
    }
}
