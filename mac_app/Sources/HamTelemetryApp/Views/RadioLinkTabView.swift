// FILE: mac_app/Sources/HamTelemetryApp/Views/RadioLinkTabView.swift
//
// RF link quality diagnostics: RSSI history, packet error rate, pkts/sec,
// dropped MAVLink sequence count.

import SwiftUI
import Charts

struct RadioLinkTabView: View {
    @EnvironmentObject var t: TelemetryModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                statTile("Link health", "\(t.link.healthPct) %", healthColor)
                statTile("RSSI",        "\(t.link.rssiPct) %",   rssiColor)
                statTile("Pkt/s",       String(format: "%.1f", t.link.pktsPerSec), .primary)
                statTile("OK / Fail",   "\(t.link.packetsOK) / \(t.link.crcFails)", .primary)
                statTile("Seq drops",   "\(t.link.droppedSeq)", t.link.droppedSeq > 0 ? .orange : .primary)
            }

            GroupBox("RSSI history") {
                if t.rssiHistory.isEmpty {
                    placeholder("waiting for data")
                } else {
                    Chart(t.rssiHistory) { s in
                        LineMark(x: .value("t", s.t), y: .value("rssi", s.value))
                            .foregroundStyle(.purple)
                        AreaMark(x: .value("t", s.t), y: .value("rssi", s.value))
                            .foregroundStyle(.purple.opacity(0.15))
                    }
                    .chartYScale(domain: 0...100)
                }
            }
            .frame(minHeight: 220)

            GroupBox("Packet error rate") {
                HStack(alignment: .bottom, spacing: 20) {
                    barTile(label: "OK",        value: Int(t.link.packetsOK), color: .green)
                    barTile(label: "CRC fail",  value: Int(t.link.crcFails),  color: .red)
                    barTile(label: "Seq drop",  value: Int(t.link.droppedSeq), color: .orange)
                    Spacer()
                    VStack(alignment: .leading) {
                        if let at = t.link.lastPacketAt {
                            Text("Last pkt: \(at.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let at = t.link.lastMavlinkAt {
                            Text("Last MAVLink: \(at.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Bytes RX: \(t.link.bytesReceived)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            Spacer()
        }
        .padding()
    }

    private var healthColor: Color {
        switch t.link.healthPct {
        case 70...:  return .green
        case 40..<70: return .orange
        default:     return .red
        }
    }

    private var rssiColor: Color {
        switch t.link.rssiPct {
        case 70...:  return .green
        case 40..<70: return .orange
        default:     return .red
        }
    }

    private func statTile(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit()).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func barTile(label: String, value: Int, color: Color) -> some View {
        VStack {
            Text("\(value)").font(.title3.monospacedDigit())
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 36, height: max(2, CGFloat(min(value, 1000)) * 0.15))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
    }
}
