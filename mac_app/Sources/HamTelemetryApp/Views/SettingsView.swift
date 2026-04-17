// FILE: mac_app/Sources/HamTelemetryApp/Views/SettingsView.swift
//
// Settings sheet surfaced from the main menu.  Edits the AppSettings
// @EnvironmentObject directly — changes persist immediately to
// UserDefaults via the didSet hooks on AppSettings.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            batteryTab.tabItem { Label("Battery", systemImage: "battery.75") }
            mavlinkTab.tabItem { Label("MAVLink", systemImage: "lock.shield") }
            sourceTab.tabItem  { Label("Input",   systemImage: "cable.connector") }
        }
        .padding(20)
        .frame(width: 520, height: 380)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: Battery

    private var batteryTab: some View {
        Form {
            Picker("Battery profile", selection: $settings.batteryProfileID) {
                ForEach(BatteryProfile.presets) { p in
                    Text(p.name).tag(p.id)
                }
            }

            let p = settings.batteryProfile
            LabeledContent("Cells",  value: "\(p.cellCount)")
            LabeledContent("Nominal", value: String(format: "%.2f V", p.nominalV))
            LabeledContent("Green ≥", value: String(format: "%.2f V", p.greenV))
            LabeledContent("Orange ≥", value: String(format: "%.2f V", p.orangeV))
            LabeledContent("Red <",   value: String(format: "%.2f V", p.redV))

            Divider()
            Text("Colour thresholds on the Power tab use the selected profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: MAVLink

    private var mavlinkTab: some View {
        Form {
            SecureField("Signing key (64-char hex)", text: $settings.signingKeyHex)
                .textFieldStyle(.roundedBorder)
                .help("Paste the 32-byte MAVLink 2.0 signing key as 64 hex chars (no 0x prefix).")

            HStack {
                let ok = settings.signingKey != nil
                Circle().fill(ok ? .green : (settings.signingKeyHex.isEmpty ? .gray : .red))
                    .frame(width: 8, height: 8)
                Text(ok
                     ? "valid 32-byte key — signed v2 frames will be HMAC-verified"
                     : settings.signingKeyHex.isEmpty
                        ? "no key — signature field ignored"
                        : "invalid hex or wrong length (\(settings.signingKeyHex.count)/64)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Reject replayed timestamps", isOn: $settings.enforceSignatureTimestamp)
                .help("Reject frames whose timestamp is ≤ the last seen timestamp for the same link ID.")

            Divider()
            Text("Unsigned v2 frames and unknown msgids always pass through; this setting only affects frames that carry the 13-byte signature trailer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Source

    private var sourceTab: some View {
        Form {
            Picker("Preferred input", selection: $settings.preferredSource) {
                ForEach(AppSettings.InputSource.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)

            Stepper("UDP port: \(settings.udpPort)",
                    value: $settings.udpPort, in: 1024...65535)

            Divider()
            Text("When UDP is selected, the app binds 127.0.0.1:\(settings.udpPort) and treats every inbound datagram's payload as bytes — the same pipeline the serial path uses.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
