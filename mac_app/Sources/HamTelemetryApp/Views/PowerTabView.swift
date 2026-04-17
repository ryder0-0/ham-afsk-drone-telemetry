// FILE: mac_app/Sources/HamTelemetryApp/Views/PowerTabView.swift
//
// Battery voltage / current / remaining-% tiles plus a voltage history
// chart — useful for spotting sag under load.

import SwiftUI
import Charts

struct PowerTabView: View {
    @EnvironmentObject var t: TelemetryModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                bigTile(settings.batteryProfile.name,
                        t.current.batteryVolts.map { String(format: "%.2f V", $0) } ?? "—",
                        color: voltageColor)
                bigTile("Current",
                        t.current.batteryCurrentA.map { String(format: "%.2f A", $0) } ?? "—",
                        color: .accentColor)
                bigTile("Remaining",
                        t.current.batteryRemaining.map { "\($0) %" } ?? "—",
                        color: batteryPctColor)
                bigTile("Throttle",
                        t.current.throttlePct.map { "\($0) %" } ?? "—",
                        color: .accentColor)
            }

            GroupBox("Battery voltage") {
                if t.battHistory.isEmpty {
                    placeholder("no battery data yet")
                } else {
                    Chart(t.battHistory) { s in
                        LineMark(x: .value("t", s.t), y: .value("V", s.value))
                            .foregroundStyle(voltageColor)
                        AreaMark(x: .value("t", s.t), y: .value("V", s.value))
                            .foregroundStyle(voltageColor.opacity(0.15))
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                }
            }
            .frame(minHeight: 220)

            Spacer()
        }
        .padding()
    }

    private var voltageColor: Color {
        guard let v = t.current.batteryVolts else { return .secondary }
        switch settings.batteryProfile.classify(voltage: v) {
        case .green:   return .green
        case .orange:  return .orange
        case .red:     return .red
        case .unknown: return .secondary
        }
    }

    private var batteryPctColor: Color {
        guard let p = t.current.batteryRemaining else { return .secondary }
        switch p {
        case 60...:  return .green
        case 25..<60: return .orange
        default:     return .red
        }
    }

    private func bigTile(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
    }
}
