// FILE: mac_app/Sources/HamTelemetryApp/Services/UDPTransport.swift
//
// UDP byte source — listens on a local port and hands every inbound
// datagram's payload to `onBytesReceived`.  Mission Planner / QGC /
// mavproxy can forward MAVLink here with e.g.:
//
//   mavproxy.py --master=/dev/tty.usbserial --out=udp:127.0.0.1:14550
//
// or the user's own bridge.  We don't try to be an actual MAVLink router —
// this is strictly "give me your bytes, I'll decode them".

import Foundation
import Network

@MainActor
final class UDPTransport: ObservableObject, ByteSource {

    @Published private(set) var isListening: Bool = false
    @Published private(set) var localPort:   UInt16 = 14550
    @Published private(set) var lastError:   String?
    @Published private(set) var bytesReceivedTotal: UInt64 = 0
    @Published private(set) var peer: String?        // last sender endpoint

    var onBytesReceived: ((Data) -> Void)?

    var sourceLabel: String? {
        isListening ? "UDP :\(localPort)" : nil
    }

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let udpQueue = DispatchQueue(label: "ham.udp.listener", qos: .userInitiated)

    // MARK: - Lifecycle

    func start(port: UInt16 = 14550) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            self.lastError = "invalid port \(port)"
            return
        }
        self.localPort = port

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params, on: nwPort)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleStateChange(state) }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.adoptConnection(conn) }
            }
            l.start(queue: udpQueue)
            self.listener = l
        } catch {
            self.lastError = "NWListener: \(error.localizedDescription)"
            self.isListening = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in connections { c.cancel() }
        connections.removeAll()
        isListening = false
        peer = nil
    }

    // MARK: - Plumbing

    private func handleStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            self.isListening = true
            self.lastError = nil
        case .failed(let err):
            self.isListening = false
            self.lastError = "listener failed: \(err.localizedDescription)"
        case .cancelled:
            self.isListening = false
        default:
            break
        }
    }

    private func adoptConnection(_ conn: NWConnection) {
        connections.append(conn)
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                Task { @MainActor in
                    self?.peer = conn.endpoint.debugDescription
                }
            }
        }
        conn.start(queue: udpQueue)
        receiveLoop(on: conn)
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self?.bytesReceivedTotal &+= UInt64(data.count)
                    self?.onBytesReceived?(data)
                }
            }
            if error == nil {
                // Keep reading on the same connection.  Hop to MainActor
                // because receiveLoop touches isolated state; bouncing
                // through an isolated Task keeps Swift 6 concurrency happy.
                Task { @MainActor [weak self] in
                    self?.receiveLoop(on: conn)
                }
            }
        }
    }
}
