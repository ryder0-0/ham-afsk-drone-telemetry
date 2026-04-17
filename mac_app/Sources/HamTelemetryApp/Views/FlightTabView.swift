// FILE: mac_app/Sources/HamTelemetryApp/Views/FlightTabView.swift
//
// Primary flight display: attitude indicator + altitude tape + speeds.

import SwiftUI
import Charts

struct FlightTabView: View {
    @EnvironmentObject var t: TelemetryModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                attitudeIndicator
                    .frame(width: 260, height: 260)
                VStack(spacing: 16) {
                    numericTile("Altitude (AGL)",
                                t.current.relAltM.map { String(format: "%.1f m", $0) } ?? "—")
                    numericTile("Altitude (AMSL)",
                                t.current.altitudeM.map { String(format: "%.1f m", $0) } ?? "—")
                    numericTile("Ground Speed",
                                t.current.groundspeedMS.map { String(format: "%.1f m/s", $0) } ?? "—")
                    numericTile("Air Speed",
                                t.current.airspeedMS.map { String(format: "%.1f m/s", $0) } ?? "—")
                    numericTile("Climb",
                                t.current.climbMS.map { String(format: "%+.1f m/s", $0) } ?? "—")
                    numericTile("Heading",
                                t.current.yawDeg.map { String(format: "%.0f°", $0) } ?? "—")
                }
            }

            altitudeChart
                .frame(maxWidth: .infinity, minHeight: 180)
        }
        .padding()
    }

    private var attitudeIndicator: some View {
        let roll  = t.current.rollDeg  ?? 0
        let pitch = t.current.pitchDeg ?? 0
        return ZStack {
            // Sky / ground
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let pitchOffset = CGFloat(pitch) * (h / 90.0) * 0.5  // ±90° → ±h/2
                ZStack {
                    Rectangle().fill(Color(red: 0.3, green: 0.6, blue: 0.95))
                        .frame(width: w * 2, height: h * 2)
                        .offset(y: -h / 2 + pitchOffset)
                    Rectangle().fill(Color(red: 0.55, green: 0.35, blue: 0.15))
                        .frame(width: w * 2, height: h * 2)
                        .offset(y:  h / 2 + pitchOffset)
                    Rectangle().fill(.white)
                        .frame(width: w * 2, height: 2)
                        .offset(y: pitchOffset)
                }
                .rotationEffect(.degrees(-roll), anchor: .center)
                .clipShape(Circle())
            }
            // Reticle
            Rectangle().fill(.yellow).frame(width: 100, height: 3)
            Rectangle().fill(.yellow).frame(width: 3, height: 12)
        }
        .overlay(
            Circle().stroke(.white.opacity(0.6), lineWidth: 2)
        )
    }

    private var altitudeChart: some View {
        GroupBox("Altitude history") {
            if t.altHistory.isEmpty {
                placeholder("no data yet")
            } else {
                Chart(t.altHistory) { s in
                    LineMark(x: .value("t", s.t), y: .value("alt", s.value))
                        .foregroundStyle(.blue)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            }
        }
    }

    private func numericTile(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.title3.monospacedDigit())
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
    }
}
