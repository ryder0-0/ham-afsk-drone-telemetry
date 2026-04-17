// FILE: mac_app/Sources/HamTelemetryApp/Views/LogsTabView.swift
//
// Live-tailing console for firmware diagnostic lines and app events.
// Also exposes "Reveal session in Finder" and an old-session selector.

import SwiftUI
import AppKit

struct LogsTabView: View {
    @EnvironmentObject var telemetry: TelemetryModel
    @EnvironmentObject var logger:    Logger
    @EnvironmentObject var replay:    ReplayEngine

    @State private var autoScroll = true
    @State private var filter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
    }

    private var toolbar: some View {
        HStack {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Toggle("Auto-scroll", isOn: $autoScroll).toggleStyle(.switch)

            Spacer()

            if let dir = logger.sessionDir {
                Button("Reveal session") {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }

            Menu("Replay past session") {
                ForEach(logger.listSessions(), id: \.path) { url in
                    Button(url.lastPathComponent) {
                        let raw = url.appendingPathComponent("raw.bin")
                        replay.load(url: raw)
                        replay.play()
                    }
                }
            }

            Menu("Export → .tlog") {
                ForEach(logger.listSessions(), id: \.path) { url in
                    Button(url.lastPathComponent) {
                        let raw = url.appendingPathComponent("raw.bin")
                        if let (out, _) = try? TlogExporter.exportAdjacent(rawURL: raw) {
                            NSWorkspace.shared.activateFileViewerSelecting([out])
                        }
                    }
                }
            }
        }
        .padding(10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredLines.indices, id: \.self) { i in
                        Text(filteredLines[i])
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: telemetry.logLines.count) { _ in
                if autoScroll, let last = filteredLines.indices.last {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var filteredLines: [String] {
        if filter.isEmpty { return telemetry.logLines }
        return telemetry.logLines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }
}
