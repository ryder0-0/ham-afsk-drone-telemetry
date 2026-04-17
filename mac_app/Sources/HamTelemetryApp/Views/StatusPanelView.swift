// FILE: mac_app/Sources/HamTelemetryApp/Views/StatusPanelView.swift
//
// High-density live state summary: armed / mode / health / counters.

import SwiftUI

struct StatusPanelView: View {
    @EnvironmentObject var telemetry: TelemetryModel
    @EnvironmentObject var logger:    Logger

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STATUS").font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Circle()
                    .fill(armedColor)
                    .frame(width: 10, height: 10)
                Text(telemetry.current.armed == true ? "ARMED" : "DISARMED")
                    .font(.headline)
                    .foregroundStyle(telemetry.current.armed == true ? .red : .primary)
                Spacer()
                Text(telemetry.current.flightMode ?? "—")
                    .font(.callout)
                    .monospaced()
            }

            Divider()

            gridRow("Health",     "\(telemetry.link.healthPct)%", colorForHealth(telemetry.link.healthPct))
            gridRow("RSSI",       "\(telemetry.link.rssiPct)%",   nil)
            gridRow("Pkt/s",      String(format: "%.1f", telemetry.link.pktsPerSec), nil)
            gridRow("OK / Fail",  "\(telemetry.link.packetsOK) / \(telemetry.link.crcFails)", nil)
            gridRow("Dropped",    "\(telemetry.link.droppedSeq)", nil)

            Divider()

            HStack {
                Circle()
                    .fill(logger.isLogging ? .orange : .gray)
                    .frame(width: 8, height: 8)
                Text(logger.isLogging ? "logging" : "paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(logger.isLogging ? "Pause" : "Resume") {
                    logger.setLogging(!logger.isLogging)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
            if let dir = logger.sessionDir {
                Text(dir.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var armedColor: Color {
        telemetry.current.armed == true ? .red : .secondary
    }

    private func colorForHealth(_ pct: Int) -> Color? {
        switch pct {
        case 70...:  return .green
        case 40..<70: return .orange
        default:     return .red
        }
    }

    private func gridRow(_ k: String, _ v: String, _ accent: Color?) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(accent ?? .primary)
        }
    }
}
