// FILE: mac_app/Sources/HamTelemetryApp/Views/ContentView.swift
//
// Root window layout: left sidebar (connection + status + replay controls)
// and a main area containing five tabs.

import SwiftUI

enum AppTab: Hashable {
    case flight, map, power, radio, spectrogram, logs
}

struct ContentView: View {
    @EnvironmentObject var telemetry: TelemetryModel
    @EnvironmentObject var serial:    SerialManager
    @EnvironmentObject var logger:    Logger
    @EnvironmentObject var replay:    ReplayEngine
    @EnvironmentObject var settings:  AppSettings

    @State private var selectedTab: AppTab = .flight
    @State private var showSettings = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

            VStack(spacing: 0) {
                tabBar
                Divider()
                mainArea
            }
            .frame(minWidth: 720)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ConnectionPanelView()
                .padding(12)
            Divider()
            StatusPanelView()
                .padding(12)
            Divider()
            replayPanel
                .padding(12)
            Spacer()
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var replayPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REPLAY").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Load…") { openReplayFile() }
                Button(replay.state == .playing ? "Pause" : "Play") {
                    replay.state == .playing ? replay.pause() : replay.play()
                }
                .disabled(replay.totalBytes == 0)
                Button("Stop") { replay.stop() }
                    .disabled(replay.state == .idle)
            }
            HStack {
                Text("Speed").font(.caption)
                Slider(value: $replay.speed, in: 0.25...8.0)
                Text(String(format: "%.2f×", replay.speed)).font(.caption).monospacedDigit()
            }
            if replay.totalBytes > 0 {
                ProgressView(value: Double(replay.cursor),
                             total: Double(max(1, replay.totalBytes)))
                    .progressViewStyle(.linear)
                Text("\(replay.cursor) / \(replay.totalBytes) bytes")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func openReplayFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK, let url = panel.url {
            replay.load(url: url)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.flight,      "Flight",      "airplane")
            tabButton(.map,         "Map",         "map")
            tabButton(.power,       "Power",       "battery.75")
            tabButton(.radio,       "Radio Link",  "antenna.radiowaves.left.and.right")
            tabButton(.spectrogram, "Spectrum",    "waveform")
            tabButton(.logs,        "Logs",        "doc.text")
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("Settings (battery profile, MAVLink signing, input source)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func tabButton(_ tab: AppTab, _ label: String, _ icon: String) -> some View {
        let selected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var mainArea: some View {
        switch selectedTab {
        case .flight:       FlightTabView()
        case .map:          MapTabView()
        case .power:        PowerTabView()
        case .radio:        RadioLinkTabView()
        case .spectrogram:  SpectrogramTabView()
        case .logs:         LogsTabView()
        }
    }
}
