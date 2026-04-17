// FILE: mac_app/Sources/HamTelemetryApp/Views/SpectrogramTabView.swift
//
// Live audio-band waterfall.  Consumes 32-bin magnitude arrays from
// TelemetryModel.spectrum (populated by PacketDecoder when the firmware
// emits PKT_TYPE_SPECTRUM frames at ~4 Hz) and draws them as a scrolling
// colour map alongside a "current frame" bar chart.
//
// Bins span 0 → SAMPLE_RATE/2 = 4800 Hz in 32 steps of 150 Hz.  The MARK
// (1200 Hz) and SPACE (2200 Hz) tones sit at bins 8 and 14 respectively;
// we annotate them as vertical guide lines so you can see at a glance
// whether the radio audio is delivering clean energy at the right spots.

import SwiftUI

struct SpectrogramTabView: View {
    @EnvironmentObject var t: TelemetryModel

    private let binCount = 32
    private let markBin  = 8    // 8 * 150 Hz = 1200 Hz
    private let spaceBin = 14   // 14 * 150 Hz = 2100 Hz (closest to 2200)

    var body: some View {
        VStack(spacing: 12) {
            header
            GroupBox("Waterfall") {
                waterfall
                    .frame(minHeight: 320)
            }
            GroupBox("Current frame") {
                currentBars
                    .frame(height: 180)
            }
            legend
        }
        .padding()
    }

    private var header: some View {
        HStack(spacing: 16) {
            Label("1200 Hz (MARK)",  systemImage: "circle.fill").foregroundStyle(.blue)
            Label("2200 Hz (SPACE)", systemImage: "circle.fill").foregroundStyle(.orange)
            Spacer()
            Text("\(t.spectrum.count) frames buffered")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Waterfall

    private var waterfall: some View {
        GeometryReader { geo in
            if t.spectrum.isEmpty {
                placeholder("waiting for PKT_TYPE_SPECTRUM frames (requires firmware support)")
            } else {
                let rowH = max(1, geo.size.height / CGFloat(t.spectrum.count))
                let colW = geo.size.width / CGFloat(binCount)
                Canvas { ctx, size in
                    for (rowIdx, row) in t.spectrum.enumerated() {
                        let y = CGFloat(rowIdx) * rowH
                        for (binIdx, mag) in row.enumerated() {
                            let x = CGFloat(binIdx) * colW
                            let rect = CGRect(x: x, y: y, width: colW + 0.5, height: rowH + 0.5)
                            ctx.fill(Path(rect), with: .color(colorFor(mag: mag)))
                        }
                    }
                    // Guide lines at MARK/SPACE bins.
                    for (bin, color): (Int, Color) in [(markBin, .blue), (spaceBin, .orange)] {
                        let x = CGFloat(bin) * colW + colW / 2
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 1)
                    }
                }
            }
        }
    }

    private var currentBars: some View {
        GeometryReader { geo in
            if let last = t.spectrum.last {
                let w = geo.size.width / CGFloat(binCount)
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(0..<binCount, id: \.self) { i in
                        Rectangle()
                            .fill(colorFor(mag: last[i]))
                            .frame(width: max(1, w - 1),
                                   height: max(1, CGFloat(last[i]) * geo.size.height))
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.blue.opacity(0.6))
                        .frame(width: 1)
                        .offset(x: w * CGFloat(markBin) + w / 2)
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.orange.opacity(0.6))
                        .frame(width: 1)
                        .offset(x: w * CGFloat(spaceBin) + w / 2)
                }
            } else {
                placeholder("no data")
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 0) {
            ForEach(0..<20, id: \.self) { i in
                Rectangle().fill(colorFor(mag: Float(i) / 19))
                    .frame(height: 10)
            }
        }
        .overlay(
            HStack {
                Text("0")
                Spacer()
                Text("mag")
                Spacer()
                Text("1")
            }
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
        )
        .cornerRadius(3)
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Viridis-ish palette: black → purple → orange → yellow.
    private func colorFor(mag: Float) -> Color {
        let m = max(0, min(1, mag))
        // Piecewise linear through a few anchors.
        let stops: [(Float, (Double, Double, Double))] = [
            (0.00, (0.00, 0.00, 0.10)),
            (0.25, (0.20, 0.05, 0.40)),
            (0.50, (0.55, 0.15, 0.45)),
            (0.75, (0.90, 0.40, 0.20)),
            (1.00, (1.00, 0.95, 0.40)),
        ]
        for i in 0..<(stops.count - 1) {
            let (a, ca) = stops[i]
            let (b, cb) = stops[i + 1]
            if m >= a && m <= b {
                let f = Double((m - a) / (b - a))
                let r = ca.0 + (cb.0 - ca.0) * f
                let g = ca.1 + (cb.1 - ca.1) * f
                let bl = ca.2 + (cb.2 - ca.2) * f
                return Color(red: r, green: g, blue: bl)
            }
        }
        return .black
    }
}
