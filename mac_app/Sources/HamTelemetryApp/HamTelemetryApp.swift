// FILE: mac_app/Sources/HamTelemetryApp/HamTelemetryApp.swift
//
// SwiftUI @main app entry point.  Owns the long-lived services
// (SerialManager, UDPTransport, PacketDecoder, TelemetryModel, Logger,
// ReplayEngine, AppSettings) and injects them into the view hierarchy as
// @EnvironmentObjects so every tab reads the same live state.
//
// The pipeline is wired once in bootPipeline(): any ByteSource → logger →
// PacketDecoder → TelemetryModel.  Settings can swap sources on the fly
// without re-wiring anything downstream.

import SwiftUI

@main
struct HamTelemetryApp: App {

    // Shared app-wide state.
    @StateObject private var telemetry = TelemetryModel()
    @StateObject private var logger    = Logger()
    @StateObject private var serial    = SerialManager()
    @StateObject private var udp       = UDPTransport()
    @StateObject private var replay    = ReplayEngine()
    @StateObject private var decoder   = PacketDecoder()
    @StateObject private var settings  = AppSettings()

    var body: some Scene {
        WindowGroup("HAM-AFSK Telemetry") {
            ContentView()
                .environmentObject(telemetry)
                .environmentObject(logger)
                .environmentObject(serial)
                .environmentObject(udp)
                .environmentObject(replay)
                .environmentObject(decoder)
                .environmentObject(settings)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear { bootPipeline() }
                .onChange(of: settings.signingKeyHex) { _ in applySigningKey() }
                .onChange(of: settings.enforceSignatureTimestamp) { _ in applySigningKey() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }   // suppress ⌘N
            CommandMenu("Tools") {
                Button("Export current session → .tlog") {
                    exportCurrentSessionToTlog()
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
                Divider()
                Button("Reveal session in Finder") {
                    if let dir = logger.sessionDir {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
            }
        }
    }

    // MARK: - Pipeline wiring

    private func bootPipeline() {
        decoder.onTelemetryUpdate = { [weak telemetry, weak logger] snapshot in
            telemetry?.apply(snapshot)
            logger?.logSnapshot(snapshot)
        }
        decoder.onPacketStats = { [weak telemetry] stats in
            telemetry?.updateLinkStats(stats)
        }
        decoder.onLogLine = { [weak telemetry] line in
            telemetry?.appendLogLine(line)
        }
        decoder.onSpectrum = { [weak telemetry] bins in
            telemetry?.appendSpectrum(bins)
        }

        // Serial and UDP both feed the same decoder + logger chain.
        serial.onBytesReceived = { [weak decoder, weak logger] data in
            logger?.logRawBytes(data)
            decoder?.feed(data)
        }
        udp.onBytesReceived = { [weak decoder, weak logger] data in
            logger?.logRawBytes(data)
            decoder?.feed(data)
        }

        replay.onBytesReplayed = { [weak decoder] data in
            decoder?.feed(data)
        }

        applySigningKey()
    }

    /// Push the current signing key from settings into MavlinkDecoder.
    private func applySigningKey() {
        // We expose a single MavlinkSignatureVerifier through the decoder's
        // inner MavlinkDecoder.  Reach in by convention — see PacketDecoder.
        if settings.signingKey != nil || !settings.signingKeyHex.isEmpty {
            let verifier = MavlinkSignatureVerifier()
            verifier.secretKey = settings.signingKey
            verifier.enforceTimestamp = settings.enforceSignatureTimestamp
            decoder.setSignatureVerifier(verifier)
        } else {
            decoder.setSignatureVerifier(nil)
        }
    }

    // MARK: - Tools menu

    private func exportCurrentSessionToTlog() {
        guard let dir = logger.sessionDir else { return }
        let raw = dir.appendingPathComponent("raw.bin")
        do {
            let (url, n) = try TlogExporter.exportAdjacent(rawURL: raw)
            telemetry.appendLogLine("[app] wrote \(n) frames to \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            telemetry.appendLogLine("[app] tlog export failed: \(error)")
        }
    }
}
