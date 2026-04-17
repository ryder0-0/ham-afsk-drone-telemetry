# System Architecture

## Overview

```
┌──────────────────────────────────────────────────────────────┐
│                        DRONE (AIR)                           │
│                                                              │
│  Pixhawk/ArduPilot                                           │
│  Telem1 (57600 8N1)                                          │
│       │ UART                                                 │
│       ▼                                                      │
│  ESP32 WROOM-32  (Transmitter firmware)                      │
│  ┌───────────────────────────────────┐                       │
│  │ MavlinkReader  ─►  PacketEncoder  │                       │
│  │                        │          │                       │
│  │                  AFSKModulator    │                       │
│  │                  (sine LUT+DAC)   │                       │
│  │                        │          │                       │
│  │ PTT GPIO ─────────►  GPIO4        │                       │
│  │ Audio out ────────►  GPIO25 (DAC1)│                       │
│  └───────────────────────────────────┘                       │
│         │ audio (AC-coupled, attenuated)                     │
│         ▼                                                    │
│  Ham radio HT (e.g. Baofeng UV-5R)                           │
│  Mic input + PTT pin                                         │
└──────────────────────────────────────────────────────────────┘
                        │ RF  (VHF/UHF amateur band)
                        ▼
┌──────────────────────────────────────────────────────────────┐
│                    GROUND STATION                            │
│                                                              │
│  Ham radio HT                                                │
│  Speaker output                                              │
│         │ audio (AC-coupled, conditioned)                    │
│         ▼                                                    │
│  ESP32 WROOM-32  (Receiver firmware)                         │
│  ┌───────────────────────────────────┐                       │
│  │ GPIO34 (ADC1) ─► AFSKDemodulator  │                       │
│  │                        │          │                       │
│  │                  PacketDecoder    │                       │
│  │                  (CRC verify)     │                       │
│  │                        │          │                       │
│  │                  MavlinkOutput    │                       │
│  │                  UART2 + USB      │                       │
│  └───────────────────────────────────┘                       │
│       │ UART (57600 8N1)  │ USB Serial                       │
│       ▼                   ▼                                  │
│  Mission Planner       QGroundControl / other GCS            │
└──────────────────────────────────────────────────────────────┘
```

---

## Platform Choice: ESP32 WROOM-32

The **original ESP32** (not S3) was chosen as the sole platform for the following reasons:

| Feature            | Required For        | ESP32 | ESP32-S3 |
|--------------------|---------------------|-------|----------|
| Hardware DAC       | Audio output        | ✓ GPIO25/26 | ✗ (no DAC) |
| 12-bit ADC         | Audio input         | ✓     | ✓        |
| UART × 3           | MAVLink + debug     | ✓     | ✓        |
| USB serial         | GCS forwarding      | via CP2102 | native |
| FPU                | IIR demodulator     | ✓ (LX6) | ✓ |
| Arduino/PlatformIO | Firmware framework  | ✓     | ✓        |

The ESP32-S3 lacks a DAC; audio output would require a PWM + RC low-pass filter or an external I2S DAC, adding hardware complexity.  The ESP32's 8-bit hardware DAC is more than sufficient for 1200 baud AFSK.

---

## Signal Flow — Transmitter

```
MAVLink bytes (UART2)
      │
      ▼
MavlinkReader::update()
  ├─ [tunnel mode]  raw frame → Packet(type=MAVLINK, payload=frame)
  └─ [summary mode] parsed fields → TelemetrySummary → Packet(type=TELEM, ...)
      │
      ▼
AFSKModulator::prepare_packet()
  1. packet_encode() → wire bytes (preamble + header + payload + CRC)
  2. bytes_to_bits_lsb() → bit stream (LSB first)
  3. nrzi_encode() → tone stream (0=SPACE, 1=MARK)
  4. Tone stream → audio samples (phase-continuous sine via LUT)
  5. Samples stored in audio_buf_[20000]
      │
      ▼
AFSKModulator::transmit()
  1. PTT GPIO HIGH  (drives NPN base → radio PTT GND)
  2. delay(80 ms)   — PTT settle time
  3. Enable hw_timer → ISR calls dacWrite(GPIO25, sample) at 9615 Hz
  4. Wait for ISR to drain audio_buf_
  5. delay(60 ms)   — PTT tail, prevents squelch from cutting packet end
  6. PTT GPIO LOW
```

---

## Signal Flow — Receiver

```
ADC samples (GPIO34, 12-bit, 9615 Hz via hw_timer ISR)
      │
      ▼
AFSKDemodulator::process_sample()  ← called from ISR
  1. Centre: sample -= 2048
  2. Advance 16-bit phase accumulators (mark: +8192, space: +15019)
  3. Quadrature mix: sample × cos/sin of each reference
  4. IIR LPF (α=0.25, fc≈441 Hz) on all 4 channels
  5. L2 power: P = I² + Q²
  6. Second IIR on power (smoothing)
  7. Tone decision with 8% hysteresis
  8. Bit-clock PLL: reset phase on transition, sample at phase==4
  9. NRZI decode at sample point → bit
 10. 8-bit LSB-first byte assembler → push to out_bytes ring buffer
      │
      ▼
PacketDecoder::update()  ← called from main loop
  1. pop bytes from out_bytes
  2. packet_decode_byte() state machine:
     PREAMBLE → SYNC1 → TYPE → SEQ → LEN_LO → LEN_HI → PAYLOAD → CRC
  3. On PACKET_OK: route payload to mavlink_out ring buffer
  4. On CRC_FAIL: reset state machine (fast resync)
      │
      ▼
MavlinkOutput::update()
  1. Drain mavlink_out → Serial (USB) + HardwareSerial (UART2 → GCS)
  2. Print stats every 1 s
```

---

## Modem Parameters

| Parameter     | Value       | Rationale |
|---------------|-------------|-----------|
| Sample rate   | 9600 Hz     | Exact integer 8 samples/bit at 1200 baud.  Achievable with ESP32 timer at 9615 Hz (0.16% off). |
| Baud rate     | 1200 baud   | Bell 202 standard; compatible with TNC-style decoders. |
| Mark tone     | 1200 Hz     | Bell 202 mark |
| Space tone    | 2200 Hz     | Bell 202 space |
| Modulation    | AFSK + NRZI | Tone transitions only on '0' bits; self-clocking. |
| Demodulator   | Quadrature IIR | CPU efficient; works without block boundaries. |
| IIR cutoff    | ~441 Hz (α=0.25) | Below 600 Hz (half baud) to reduce ISI. |
| Sync word     | 0x2D 0xD4   | Low autocorrelation side-lobes; different from preamble byte. |
| Preamble      | 25 × 0xAA   | ~167 ms; reliable squelch opening on most HTs. |
| CRC           | CRC16-CCITT | Detects all 1/2-bit errors and most burst errors. |

---

## Software Watchdog

The transmitter main loop monitors `last_mavlink_ms`.  If no MAVLink frame arrives for `HEARTBEAT_INTERVAL_MS` (5 s), a heartbeat packet is transmitted to keep the RF link exercised and confirm the modem is alive.

The ESP32 hardware watchdog timer (`WDT_TIMEOUT_MS = 10 s`) is fed by the main loop.  If the ISR or I²C/SPI driver hangs and starves the loop, the WDT resets the MCU.
