// FILE: mac_app/Sources/HamTelemetryApp/Services/ByteSource.swift
//
// Transport abstraction.  Anything that hands us a stream of bytes (serial
// port, UDP socket, TCP, file tail, replay engine) conforms to this so the
// PacketDecoder pipeline is source-agnostic.
//
// Kept deliberately minimal — just a bytes-arrived callback.  Connection
// state / port lists are UI concerns handled by concrete implementations
// via their own @Published properties.

import Foundation

@MainActor
protocol ByteSource: AnyObject {
    /// Closure fired whenever new bytes arrive.  May be called on any queue;
    /// implementations are responsible for marshalling to the main actor
    /// before mutating shared state.
    var onBytesReceived: ((Data) -> Void)? { get set }

    /// Human-readable name of the active input (e.g. "/dev/cu.usbserial-0001"
    /// or "UDP :14550").  Used by the status indicator.
    var sourceLabel: String? { get }

    /// Disconnect / stop reading.  Should be idempotent.
    func stop()
}
