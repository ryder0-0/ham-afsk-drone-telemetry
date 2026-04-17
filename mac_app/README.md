# HamTelemetryApp — macOS live telemetry viewer

A native SwiftUI ground-station app that plugs into the project's USB-serial
receiver (the ESP32 running `firmware/receiver`) and displays live drone
telemetry decoded from AFSK Bell-202 over ham radio.

## What it does

- **Reads** the mixed byte stream coming out of the receiver's USB serial
  port at 115200 8N1 (MAVLink v1/v2 frames interleaved with ASCII `[RX]`
  diagnostic lines).
- **Decodes** the six MAVLink message types the firmware cares about —
  `HEARTBEAT`, `SYS_STATUS`, `GPS_RAW_INT`, `ATTITUDE`, `GLOBAL_POSITION_INT`,
  `VFR_HUD` — with X.25 CRC + CRC_EXTRA validation.
- **Falls back** to the project's custom Bell-202 packet framing
  (`firmware/common/src/packet.cpp`) when replaying raw on-wire captures or
  when the transmitter runs in `TELEM_MODE_SUMMARY` and emits 24-byte
  `TelemetrySummary` blobs.
- **Displays** six live tabs: Flight (attitude + altitude), Map (MapKit
  with flight trail), Power (battery + throttle), Radio Link (RSSI / packet
  error chart), Spectrum (32-bin audio waterfall with MARK/SPACE guides),
  Logs (scrolling console).
- **Logs** every session to `~/Library/Application Support/HamTelemetryApp/
  sessions/<timestamp>/` — raw bytes for replay, JSON-per-line snapshots
  for post-processing.
- **Replays** any previous session file at 0.25×–8× speed with pause /
  scrub, feeding the same decoder pipeline as live capture.
- **Exports** any session to APM `.tlog` format (Tools → Export current
  session → .tlog, ⇧⌘E) for Mission Planner / MAVExplorer.
- **Verifies** MAVLink 2.0 signed frames (HMAC-SHA256 with CRC_EXTRA) when
  a 32-byte signing key is configured in Settings — including replay
  protection via monotonic-timestamp enforcement.
- **Ingests** bytes from either a USB-serial receiver (POSIX termios; swap
  in ORSSerialPort by flipping the `ORSSerialTransport.swift` guard) **or**
  a local UDP port (default 14550) for `mavproxy --out=udp:...` bridges.
- **Settings sheet** for battery chemistry + cell count (2S–6S LiPo / LiHV
  / Li-ion presets with per-cell thresholds) and the MAVLink signing key.

## Requirements

- macOS 13 (Ventura) or later — Charts and newer SwiftUI APIs.
- Xcode 15+ **or** Swift 5.9+ command-line toolchain.
- A USB-serial ESP32 receiver (see `firmware/receiver/`).  The app will
  enumerate `/dev/cu.*` devices automatically.

## Run it

```bash
cd mac_app
swift run -c release
```

Or open `Package.swift` in Xcode and hit the Run button.

## First-run checklist

1. Plug in the ESP32 receiver.  `ls /dev/cu.*` should now show something
   like `/dev/cu.usbserial-0001` or `/dev/cu.SLAB_USBtoUART`.
2. Launch the app.  Pick that port in the **Connection** panel, leave
   baud at 115200, and click **Connect**.
3. Either replay a capture, or get the transmitter talking — within a few
   seconds the **Status** panel should show `pkt/s > 0` and the tabs start
   populating.

## Architecture

```
┌─────────────────┐    Data bursts    ┌─────────────────┐
│  SerialManager  │──────────────────▶│   PacketDecoder │
│ (termios /dev/cu)│                  │ (line extractor │
└─────────────────┘                   │  + MAVLink feed)│
        │                              └────────┬────────┘
        ▼                                       ▼
┌─────────────────┐              ┌────────────────────────┐
│     Logger      │              │    MavlinkDecoder      │
│  raw.bin        │              │  v1/v2 + CRC_EXTRA     │
│  snapshots.jsonl│              └────────┬───────────────┘
└─────────────────┘                       ▼
                                  ┌────────────────┐
                                  │ TelemetryModel │
                                  │  @Published    │
                                  └────────┬───────┘
                                           ▼
                                    SwiftUI views
```

## Swapping in ORSSerialPort

The current `SerialManager` uses raw POSIX termios so the package builds
with no external dependencies.  To switch to ORSSerialPort:

1. Add `.package(url: "https://github.com/armadsen/ORSSerialPort.git",
   from: "2.1.0")` to `Package.swift`'s `dependencies`.
2. Add `.product(name: "ORSSerial", package: "ORSSerialPort")` to the
   target's `dependencies` array.
3. Replace the body of `SerialManager.swift` with an ORSSerialPort-driven
   implementation — keep the same `@Published` surface so views don't need
   to change.

## Known caveats

- MAVLink v2 signed frames: HMAC-SHA256 verification runs only when a
  32-byte signing key is pasted into Settings → MAVLink.  Without a key
  the 13-byte signature trailer is consumed and ignored, and the frame
  passes through with `signatureValid = nil`.
- Unknown `INCOMPAT_FLAGS` bits (anything other than bit 0 = signed) drop
  the frame.
- RSSI % is derived from the firmware's `rssi=N` diagnostic line, which is
  `mark_power / (mark_power + space_power)` — a *link quality* proxy, not a
  dBm reading.  If you build the receiver firmware with
  `-DTELEM_QUIET=1`, RSSI % won't update in the Mac app (no diagnostic
  lines to parse); use the RF Link tab's packet-error graph instead.
- The app does **not** send commands back to the drone.  This is a
  receive-only viewer by design.
- Spectrogram tab stays empty until the receiver firmware is extended to
  emit `PKT_TYPE_SPECTRUM` frames (packet type `0x02`, 32 × u16 magnitude
  bins + 4-byte uptime).  The wire format is defined in
  `firmware/common/include/packet.h` so the Mac side is ready when the
  firmware side ships.
