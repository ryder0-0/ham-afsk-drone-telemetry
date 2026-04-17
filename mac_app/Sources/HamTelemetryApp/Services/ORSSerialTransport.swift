// FILE: mac_app/Sources/HamTelemetryApp/Services/ORSSerialTransport.swift
//
// Alternate serial transport backed by ORSSerialPort
// (https://github.com/armadsen/ORSSerialPort).
//
// The default build uses `SerialManager` (raw POSIX termios) so the
// package has zero external dependencies.  To switch to ORSSerialPort:
//
//   1.  Edit `mac_app/Package.swift`:
//
//       dependencies: [
//           .package(url: "https://github.com/armadsen/ORSSerialPort.git",
//                    from: "2.1.0"),
//       ],
//
//       And add the product to the target:
//
//       .executableTarget(
//           name: "HamTelemetryApp",
//           dependencies: [
//               .product(name: "ORSSerial", package: "ORSSerialPort"),
//           ],
//           path: "Sources/HamTelemetryApp"
//       ),
//
//   2.  In `HamTelemetryApp.swift`, replace
//
//           @StateObject private var serial = SerialManager()
//
//       with
//
//           @StateObject private var serial = ORSSerialTransport()
//
//       Both types expose the same ByteSource surface so no other code
//       needs to change.
//
// The entire file is wrapped in `#if canImport(ORSSerial)` so it's a
// compile-time no-op until the dependency is added.

#if canImport(ORSSerial)

import Foundation
import ORSSerial

@MainActor
final class ORSSerialTransport: NSObject, ObservableObject, ByteSource {

    @Published private(set) var availablePorts: [String] = []
    @Published private(set) var isConnected: Bool        = false
    @Published private(set) var currentPort: String?     = nil
    @Published private(set) var lastError: String?       = nil
    @Published private(set) var bytesReceivedTotal: UInt64 = 0

    var onBytesReceived: ((Data) -> Void)?

    var sourceLabel: String? {
        isConnected ? currentPort : nil
    }

    private var port: ORSSerialPort?
    private let manager = ORSSerialPortManager.shared()

    override init() {
        super.init()
        refreshPorts()
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.ORSSerialPortsWereConnected,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPorts() }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.ORSSerialPortsWereDisconnected,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPorts() }
    }

    func refreshPorts() {
        availablePorts = manager.availablePorts.map { $0.path }.sorted()
    }

    func connect(port path: String, baud: Int = 115200) {
        disconnect()
        guard let p = ORSSerialPort(path: path) else {
            self.lastError = "ORSSerialPort(path:) returned nil for \(path)"
            return
        }
        p.baudRate = NSNumber(value: baud)
        p.numberOfDataBits = 8
        p.numberOfStopBits = 1
        p.parity = .none
        p.usesRTSCTSFlowControl = false
        p.delegate = self
        self.port = p
        p.open()
    }

    func disconnect() {
        port?.close()
        port = nil
        isConnected = false
        currentPort = nil
    }

    func stop() { disconnect() }
}

extension ORSSerialTransport: ORSSerialPortDelegate {
    func serialPortWasOpened(_ port: ORSSerialPort) {
        isConnected = true
        currentPort = port.path
        lastError = nil
    }
    func serialPortWasClosed(_ port: ORSSerialPort) {
        isConnected = false
        currentPort = nil
    }
    func serialPort(_ port: ORSSerialPort, didReceive data: Data) {
        bytesReceivedTotal &+= UInt64(data.count)
        onBytesReceived?(data)
    }
    func serialPort(_ port: ORSSerialPort, didEncounterError error: Error) {
        lastError = error.localizedDescription
    }
    func serialPortWasRemovedFromSystem(_ port: ORSSerialPort) {
        disconnect()
    }
}

#endif  // canImport(ORSSerial)
