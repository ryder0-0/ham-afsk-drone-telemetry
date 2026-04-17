// swift-tools-version: 5.9
// FILE: mac_app/Package.swift
//
// Swift Package describing the HamTelemetryApp macOS executable.
//
// Target platform: macOS 13 (Ventura) or later — required for Charts + the
// newer SwiftUI APIs used in the UI layer.
//
// Serial I/O is implemented against raw Darwin/POSIX termios so the package
// has zero external dependencies and can be opened directly in Xcode by
// selecting "File → Open…" on the Package.swift.  If you want to swap in
// ORSSerialPort later, add it to `dependencies` and update SerialManager.swift
// — the rest of the code depends only on the protocol `SerialTransport`.

import PackageDescription

let package = Package(
    name: "HamTelemetryApp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "HamTelemetryApp", targets: ["HamTelemetryApp"]),
    ],
    dependencies: [
        // No external deps by default — ORSSerialPort can be added here:
        // .package(url: "https://github.com/armadsen/ORSSerialPort.git", from: "2.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "HamTelemetryApp",
            dependencies: [],
            path: "Sources/HamTelemetryApp"
        ),
    ]
)
