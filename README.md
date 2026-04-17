# ham-afsk-drone-telemetry

A complete bidirectional-ready drone telemetry system that tunnels MAVLink over **AFSK Bell 202 (1200 baud)** audio, transmitted on amateur radio voice frequencies.

> **Licence requirement:** on-air RF testing of this system requires a valid amateur radio licence. Bench testing with dummy loads, soundcard loopback, and WAV-file tools requires no licence and is covered in [`docs/testing.md`](docs/testing.md).

---

## What this is

A drone flies with a flight controller (Pixhawk / ArduPilot) that speaks MAVLink over UART.  A small ESP32 board on the drone reads those bytes, frames them into packets with CRC, modulates them as Bell 202 AFSK audio, injects the audio into a handheld ham radio's mic input, and keys PTT.

On the ground, a mirror-image ESP32 reads audio from another handheld, demodulates the AFSK, checks CRC, and hands the recovered MAVLink bytes to Mission Planner / QGroundControl over USB or UART.

Two modes are supported at compile time:
- **MAVLink tunnel** — raw MAVLink frames are carried byte-for-byte.  Full GCS functionality but uses more airtime.
- **Telemetry summary** — 22-byte compressed struct (GPS, altitude, battery, mode, armed).  ~10× less airtime; suitable for 1 Hz basic telemetry.

---

## Features

- Bell 202 (1200/2200 Hz) AFSK at 1200 baud, NRZI encoded
- Packet framing with preamble, sync word, length, CRC16-CCITT, sequence numbers
- Quadrature IIR demodulator with PLL bit-clock recovery
- Fast resynchronisation after dropouts (per-byte state-machine resync)
- Periodic modem heartbeat packets
- PTT lead/tail timing to handle radio PA settle and squelch tail
- Built-in RSSI estimate from tone-power ratio
- Matching Python tools for loopback testing without any radio hardware
- Compile-time mode flag for MAVLink tunnel vs telemetry summary

---

## Repository Structure

```
ham-afsk-drone-telemetry/
├── README.md                      ← you are here
├── docs/
│   ├── architecture.md            ← block diagrams, signal flow, algorithm
│   ├── packet_format.md           ← wire format, CRC, NRZI details
│   ├── wiring.md                  ← pin assignments, conditioning circuits
│   ├── testing.md                 ← staged test procedure
│   └── building_flashing.md       ← PlatformIO build/flash instructions
├── firmware/
│   ├── common/                    ← shared lib: CRC, packet, NRZI, ring buffer
│   ├── transmitter/               ← drone ESP32 firmware
│   └── receiver/                  ← ground ESP32 firmware
├── tools/
│   ├── wav_test_generator/        ← generate AFSK WAV files with test packets
│   ├── python_decoder/            ← decode WAV files back to packets
│   └── python_encoder/            ← pipe serial MAVLink to soundcard audio
└── hardware/
    ├── schematics.md              ← ASCII schematics + BOM
    ├── ptt_interface.md           ← NPN PTT driver, timing details
    └── audio_interface.md         ← level budget, pre/de-emphasis, noise
```

---

## Quick Start

### Step 1 — flash both ESP32s

```bash
# Transmitter (drone)
cd firmware/transmitter
pio run -e esp32dev -t upload

# Receiver (ground)
cd ../receiver
pio run -e esp32dev -t upload
```

See [`docs/building_flashing.md`](docs/building_flashing.md) for details.

### Step 2 — verify without a radio (WAV loopback)

```bash
cd tools/wav_test_generator
pip install -r requirements.txt
python generate_test_wav.py --out /tmp/test.wav --packets 5

cd ../python_decoder
python wav_decoder.py /tmp/test.wav --verbose
```

Expected: `5 OK  0 CRC-fail`.

### Step 3 — wire the radios

Follow the schematics in [`hardware/schematics.md`](hardware/schematics.md) and the conditioning circuits in [`docs/wiring.md`](docs/wiring.md).

### Step 4 — go on-air

Both radios on same simplex frequency, narrow FM, squelch open.  Power on the transmitter and watch the receiver's serial output for `[RX] Packet OK ...` lines.

---

## Hardware Platform

Primary target: **ESP32 WROOM-32** (original ESP32, not S3).  Chosen because:
- Has a hardware 8-bit DAC (GPIO25) — the S3 does not
- 12-bit ADC, 3 UARTs, hardware timers, floating-point unit
- Cheap (≈ $5 dev board), widely available
- Arduino + PlatformIO supported

### GPIO map
| Pin     | Function                          |
|---------|-----------------------------------|
| GPIO25  | DAC out → radio mic (via attenuator)       |
| GPIO34  | ADC in ← radio speaker (via attenuator)    |
| GPIO4   | PTT out → NPN transistor base              |
| GPIO16  | UART2 RX ← flight controller / GCS         |
| GPIO17  | UART2 TX → flight controller / GCS         |
| GPIO2   | Status LED                                 |

---

## Modem Parameters

| Parameter    | Value       |
|--------------|-------------|
| Sample rate  | 9600 Hz (actual 9615 Hz; PLL absorbs the 0.16% error) |
| Baud rate    | 1200 baud   |
| Mark tone    | 1200 Hz     |
| Space tone   | 2200 Hz     |
| Line coding  | NRZI        |
| CRC          | CRC16-CCITT (poly 0x1021, init 0xFFFF) |
| Preamble     | 25 × 0xAA (≈ 167 ms)   |
| Sync word    | 0x2D 0xD4   |
| Max payload  | 260 bytes   |

---

## Full Test Procedure

Complete stage-by-stage test plan is in [`docs/testing.md`](docs/testing.md).  Summary:

1. **Python loopback** — `generate_test_wav.py` → `wav_decoder.py`.  Proves the protocol is self-consistent.
2. **TX firmware → PC soundcard → Python decoder.**  Proves ESP32 TX audio is correct.
3. **Python encoder → PC soundcard → RX firmware.**  Proves ESP32 RX demodulation works.
4. **Full RF link.**  Two radios, walk apart, observe packet-error rate vs distance.

---

## Recommended Radios

| Model            | Band    | Power | Notes |
|------------------|---------|-------|-------|
| Baofeng UV-5R    | 2m/70cm | 5 W HT | Cheap, widely available, 3.5mm TRRS mic/PTT jack.  No dedicated data port — audio goes through the speech pre-emphasis. |
| Kenwood TM-V71A  | 2m/70cm | 50 W mobile | 6-pin mini-DIN DATA port with flat audio (9600 baud mode).  Recommended for ground station. |
| Yaesu FT-857D    | HF+VHF+UHF | 100 W HF / 50 W VHF | Data port with flat audio; good for long-range telemetry on 6 m / 2 m. |
| Icom IC-705      | HF/VHF/UHF | 10 W | Built-in USB audio CODEC — can replace the receiver ESP32 entirely by using sounddevice on a PC. |

For the drone side, weight matters.  A Baofeng UV-5R is 130 g without battery, small Li-ion packs bring it to ~200 g.  For smaller drones consider a bare RDA1846 transceiver module (≈ 5 g), though TX power is limited to ~100 mW.

### Expected Range (line of sight)

| Link                                               | Range     |
|----------------------------------------------------|-----------|
| 5 W HT, rubber duck both ends, ground level        | 1–3 km    |
| 5 W HT, 1/4 vertical both ends                     | 3–8 km    |
| 5 W drone (100 m AGL) → 5 W ground w/ Yagi         | 20–50 km  |
| 25 W mobile → 50 W base, gain antennas             | 30–80 km  |

---

## Licences & Warnings

- All transmissions on amateur bands require a valid amateur radio licence for the operating region.
- This project is intended for educational and experimental use.  It is **not** a replacement for certified C2 (command-and-control) radios in drones operated under regulatory C2 requirements.
- Do **not** transmit test packets on APRS frequencies (144.390 MHz in ITU R2) without coordinating with local operators — this will disrupt APRS traffic.
- Check deviation on a service monitor before flying.  Incorrect audio level can cause splatter into adjacent channels.

---

## Licence

MIT — see individual files for SPDX headers.  Contributions welcome.
