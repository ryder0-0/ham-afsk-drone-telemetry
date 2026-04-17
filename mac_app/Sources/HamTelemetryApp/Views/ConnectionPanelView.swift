// FILE: mac_app/Sources/HamTelemetryApp/Views/ConnectionPanelView.swift
//
// Connection panel with a Serial | UDP segmented picker.  Both transports
// conform to the same ByteSource protocol so the pipeline downstream is
// agnostic to which is live.

import SwiftUI

struct ConnectionPanelView: View {
    @EnvironmentObject var serial:   SerialManager
    @EnvironmentObject var udp:      UDPTransport
    @EnvironmentObject var settings: AppSettings

    @State private var selectedPort: String = ""
    @State private var baud: Int = 115200

    private let baudRates = [9600, 19200, 38400, 57600, 115200, 230400]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CONNECTION").font(.caption).foregroundStyle(.secondary)

            Picker("", selection: $settings.preferredSource) {
                ForEach(AppSettings.InputSource.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch settings.preferredSource {
            case .serial: serialControls
            case .udp:    udpControls
            }

            if let err = activeError {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .onAppear {
            if selectedPort.isEmpty, let first = serial.availablePorts.first {
                selectedPort = first
            }
        }
    }

    // MARK: - Serial

    private var serialControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Port", selection: $selectedPort) {
                    Text("— select —").tag("")
                    ForEach(serial.availablePorts, id: \.self) { p in
                        Text(p.replacingOccurrences(of: "/dev/", with: "")).tag(p)
                    }
                }
                .labelsHidden()

                Button {
                    serial.refreshPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan ports")
            }

            HStack {
                Picker("Baud", selection: $baud) {
                    ForEach(baudRates, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 120)

                Spacer()

                if serial.isConnected {
                    Button("Disconnect") { serial.disconnect() }
                        .tint(.red)
                } else {
                    Button("Connect") {
                        udp.stop()
                        guard !selectedPort.isEmpty else { return }
                        serial.connect(port: selectedPort, baud: baud)
                    }
                    .disabled(selectedPort.isEmpty)
                }
            }

            statusPill(connected: serial.isConnected,
                       label: serial.sourceLabel ?? "not connected",
                       bytes: serial.bytesReceivedTotal)
        }
    }

    // MARK: - UDP

    private var udpControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Port").font(.caption)
                Stepper(value: $settings.udpPort, in: 1024...65535) {
                    Text("\(settings.udpPort)").monospacedDigit()
                }
                Spacer()
                if udp.isListening {
                    Button("Stop") { udp.stop() }
                        .tint(.red)
                } else {
                    Button("Listen") {
                        serial.disconnect()
                        udp.start(port: UInt16(settings.udpPort))
                    }
                }
            }

            statusPill(connected: udp.isListening,
                       label: udp.sourceLabel ?? "not listening",
                       bytes: udp.bytesReceivedTotal)

            if let peer = udp.peer {
                Text("peer: \(peer)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Common

    private func statusPill(connected: Bool, label: String, bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(connected ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(label).font(.caption)
            Spacer()
            Text(byteString(bytes))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var activeError: String? {
        switch settings.preferredSource {
        case .serial: return serial.lastError
        case .udp:    return udp.lastError
        }
    }

    private func byteString(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024.0) }
        return String(format: "%.2f MB", Double(n) / (1024.0 * 1024.0))
    }
}
