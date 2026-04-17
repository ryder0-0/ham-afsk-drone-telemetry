# Building and Flashing

## Prerequisites

1. **PlatformIO Core** — install via pip:
   ```bash
   pip install platformio
   ```
   or install the VS Code PlatformIO IDE extension.

2. **ESP32 board drivers** — most ESP32 dev boards use a CP210x or CH340 USB-UART chip.  Install the appropriate driver for your OS:
   - Silicon Labs CP210x: https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers
   - WCH CH340: http://www.wch.cn/download/CH341SER_ZIP.html

3. **Python 3.9+** with `numpy`, `scipy`, `pyserial` (for test tools).

## Repository Layout

```
ham-afsk-drone-telemetry/
├── firmware/
│   ├── common/              ← shared library (CRC, packet, NRZI, ring buffer)
│   ├── transmitter/         ← drone-side firmware  (PlatformIO project)
│   └── receiver/            ← ground-side firmware (PlatformIO project)
├── tools/
│   ├── wav_test_generator/  ← generate AFSK WAV files
│   ├── python_decoder/      ← decode WAV back to packets
│   └── python_encoder/      ← stream MAVLink to soundcard / serial
├── hardware/                ← schematics, BOM, PTT interface
└── docs/                    ← this file, architecture, packet format, testing
```

The `common/` directory is pulled in by both firmware projects via a `file://` library dependency declared in each `platformio.ini`.

## Flashing the Transmitter

```bash
cd firmware/transmitter

# build
pio run -e esp32dev

# flash (auto-detects port; use --upload-port /dev/ttyUSB0 to override)
pio run -e esp32dev -t upload

# open serial monitor
pio device monitor -b 115200
```

### Build-time Mode Switch

Edit `firmware/transmitter/platformio.ini`:

```ini
build_flags = ... -DTELEM_MODE_SUMMARY=0    ; MAVLink tunnel (default)
build_flags = ... -DTELEM_MODE_SUMMARY=1    ; compressed telemetry summary
```

Rebuild and reflash after changing.

## Flashing the Receiver

```bash
cd firmware/receiver

pio run -e esp32dev
pio run -e esp32dev -t upload
pio device monitor -b 115200
```

## Verifying the Build

On successful boot you should see on the USB serial monitor:

**Transmitter:**
```
[HAM-AFSK] Transmitter starting
[TX] Mode: mavlink-tunnel
[TX] Heartbeat seq=0
```

**Receiver:**
```
[HAM-AFSK] Receiver starting
[RX] ADC timer started, waiting for signal...
[RX] ok=0 crc_fail=0 overflow=0 seq_err=0 bytes=0 rssi=50 bits=0
```

Once the transmitter starts sending heartbeats to the receiver (either over RF or via the soundcard loopback described in `testing.md`), the `ok` counter on the receiver will increment every ~5 seconds.

## Common Build Issues

| Error                                      | Fix |
|--------------------------------------------|-----|
| `fatal error: driver/adc.h: No such file`  | ESP32 platform not installed; run `pio platform install espressif32` |
| `Library not found: file://../common`      | Run from the correct project dir; PlatformIO resolves the path relative to the ini file |
| `dacWrite() not declared`                  | You're using ESP32-S3; this project targets original ESP32 |
| `hw_timer_t` undefined                     | `framework` in ini must be `arduino` (not `espidf`) |

## Updating the Common Library

After editing `firmware/common/include/*.h` or `firmware/common/src/*.cpp`, rebuild both firmware projects.  PlatformIO will automatically recompile the shared library.
