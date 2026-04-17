// FILE: mac_app/Sources/HamTelemetryApp/Services/SerialManager.swift
//
// POSIX termios serial manager.  Chosen over ORSSerialPort so the Swift
// Package has zero external dependencies — open it in Xcode and hit Run.
//
// Responsibilities:
//   • Enumerate /dev/cu.* devices (USB-serial receivers register there)
//   • Open a port at 115200 8N1, raw mode
//   • Stream bytes to `onBytesReceived` on a background DispatchQueue
//   • Detect disconnects and auto-reconnect every 1 s while enabled
//
// Thread model: all I/O happens on a private queue.  Published properties
// are mutated on MainActor so SwiftUI observes them safely.

import Foundation
import Darwin

@MainActor
final class SerialManager: ObservableObject, ByteSource {

    // MARK: Published UI state

    @Published private(set) var availablePorts: [String] = []
    @Published private(set) var isConnected: Bool        = false
    @Published private(set) var currentPort: String?     = nil
    @Published private(set) var lastError: String?       = nil
    @Published private(set) var bytesReceivedTotal: UInt64 = 0

    /// Invoked from the read queue whenever bytes arrive.
    var onBytesReceived: ((Data) -> Void)?

    /// ByteSource conformance.
    var sourceLabel: String? {
        isConnected ? (currentPort?.replacingOccurrences(of: "/dev/", with: "")) : nil
    }

    func stop() { disconnect() }

    // MARK: Private state

    private var fd: Int32 = -1
    private var readQueue = DispatchQueue(label: "ham.serial.read", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var reconnectTask: Task<Void, Never>?
    private var targetPort: String?
    private var targetBaud: speed_t = 115200

    init() {
        refreshPorts()
    }

    // MARK: Port discovery

    func refreshPorts() {
        let fm = FileManager.default
        let dev = "/dev"
        let all = (try? fm.contentsOfDirectory(atPath: dev)) ?? []
        let ports = all
            .filter { $0.hasPrefix("cu.") }
            .filter { !$0.hasPrefix("cu.Bluetooth") }
            .map { "/dev/\($0)" }
            .sorted()
        self.availablePorts = ports
    }

    // MARK: Connection control

    func connect(port: String, baud: Int = 115200) {
        disconnect()
        self.targetPort = port
        self.targetBaud = speed_t(baud)
        self.lastError  = nil
        openPort()
        if !isConnected {
            scheduleReconnect()
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        targetPort    = nil
        closeFD()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if await self.isConnected { return }
                guard await self.targetPort != nil else { return }
                await self.openPort()
            }
        }
    }

    // MARK: Low-level open/close

    private func openPort() {
        guard let path = targetPort else { return }

        let handle = path.withCString { cstr in
            Darwin.open(cstr, O_RDWR | O_NOCTTY | O_NONBLOCK)
        }
        if handle < 0 {
            self.lastError = "open(\(path)) failed: errno \(errno)"
            self.isConnected = false
            return
        }

        // Clear O_NONBLOCK for blocking reads inside the dispatch source loop
        _ = fcntl(handle, F_SETFL, 0)

        var tio = termios()
        if tcgetattr(handle, &tio) != 0 {
            self.lastError = "tcgetattr failed: errno \(errno)"
            Darwin.close(handle)
            return
        }

        // Raw mode 8N1
        cfmakeraw(&tio)
        cfsetispeed(&tio, targetBaud)
        cfsetospeed(&tio, targetBaud)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(PARENB)
        tio.c_cflag &= ~tcflag_t(CSTOPB)
        tio.c_cflag &= ~tcflag_t(CSIZE)
        tio.c_cflag |= tcflag_t(CS8)
        tio.c_cflag &= ~tcflag_t(CRTSCTS)

        // VMIN=0, VTIME=1 — return up to N bytes after 100 ms
        withUnsafeMutablePointer(to: &tio.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { p in
                p[Int(VMIN)]  = 0
                p[Int(VTIME)] = 1
            }
        }

        if tcsetattr(handle, TCSANOW, &tio) != 0 {
            self.lastError = "tcsetattr failed: errno \(errno)"
            Darwin.close(handle)
            return
        }

        self.fd = handle
        self.currentPort = path
        self.isConnected = true
        self.lastError = nil

        startReadLoop()
    }

    private func closeFD() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        self.isConnected = false
        self.currentPort = nil
    }

    // MARK: Read loop (DispatchSource-based)

    private func startReadLoop() {
        guard fd >= 0 else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.pumpBytes() }
        }
        src.setCancelHandler { }
        src.resume()
        self.readSource = src
    }

    private func pumpBytes() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
            Darwin.read(fd, bp.baseAddress, bp.count)
        }
        if n > 0 {
            let data = Data(bytes: buf, count: n)
            self.bytesReceivedTotal &+= UInt64(n)
            onBytesReceived?(data)
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            // Device yanked — schedule reconnect
            self.lastError = "read returned \(n), errno \(errno)"
            closeFD()
            scheduleReconnect()
        }
    }
}
