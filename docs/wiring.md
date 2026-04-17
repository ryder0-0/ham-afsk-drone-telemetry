# Wiring Guide

## Transmitter (Drone) — ESP32 to Radio

### GPIO Summary

| ESP32 Pin | Direction | Signal              | Connected To |
|-----------|-----------|---------------------|--------------|
| GPIO25    | OUT       | Audio (DAC1)        | Radio mic input (via conditioning) |
| GPIO4     | OUT       | PTT (active HIGH)   | NPN transistor base (see PTT section) |
| GPIO16    | IN        | UART2 RX (MAVLink)  | Flight controller TELEM TX |
| GPIO17    | OUT       | UART2 TX (MAVLink)  | Flight controller TELEM RX |
| GND       | —         | Ground              | Common ground with radio + FC |
| 3.3V      | OUT       | Logic supply        | — |
| 5V (VIN)  | IN        | Power supply        | BEC / regulator from drone power |

---

### Audio Output Conditioning (GPIO25 → Radio Mic)

The ESP32 DAC outputs 0–3.3 V (mid-scale 1.65 V).  Most amateur HT mic inputs expect:
- **Level:** 10–100 mV peak
- **Impedance:** 600 Ω – 10 kΩ
- **DC isolation:** required (AC coupling)

```
                     C1          R2
GPIO25 ─────────┤├──────┬──── Radio MIC
(0–3.3V)       100 nF  R1    (to radio)
                        10kΩ  4.7kΩ
                        │
                       GND
```

**Component values:**
- **C1:** 100 nF ceramic (DC blocking / AC coupling)
- **R1:** 10 kΩ to GND (sets output impedance; together with R2 forms voltage divider)
- **R2:** 4.7 kΩ in series to mic pin (limits current; protects ESP32)

**Attenuation:** This network attenuates by ~32× (R1/(R1+R2) × DAC swing ≈ 68 mV peak).  Adjust R1/R2 if the radio overdrives.  Start with maximum attenuation and increase signal level while watching for audio distortion (most HTs have ALC on the mic input).

**Pre-emphasis note:** FM radios apply 75 µs pre-emphasis to the TX audio path.  This boosts high frequencies before transmission and the receiver applies de-emphasis.  At 1200 baud AFSK, the 2200 Hz space tone will be boosted by approximately 3 dB relative to the 1200 Hz mark tone after the pre-emphasis network.  The firmware's modulator produces equal-amplitude mark and space tones; the receiver demodulator's IIR filter partially compensates, but for best results:
- Use a radio with pre-emphasis **bypass** (many radios have a "flat" or "9600 baud" mode — e.g., Kenwood TM-V71 DATA connector, Yaesu FT-857 DATA port).
- Alternatively, add a simple first-order de-emphasis on the transmitter audio: a 10 kΩ + 15 nF RC low-pass with 1 kHz corner frequency in the audio path.

---

### Receiver (Ground Station) — Radio to ESP32

| ESP32 Pin | Direction | Signal         | Connected To |
|-----------|-----------|----------------|--------------|
| GPIO34    | IN        | ADC1 CH6 (audio in) | Radio speaker out (via conditioning) |
| GPIO16    | IN        | UART2 RX       | GCS computer RX (unused at ground) |
| GPIO17    | OUT       | UART2 TX       | GCS computer RX / Mission Planner |
| GND       | —         | Ground         | Common with radio |

**GPIO34 is input-only** on ESP32; it can withstand up to 3.3 V.

### Audio Input Conditioning (Radio Speaker → GPIO34)

Radio speaker output levels vary widely:
- **Handheld speaker (at volume):** 0.5–2 V peak
- **External speaker jack (typical HT):** 100–500 mV peak

```
Radio                   C2           R3
SPK+  ─────────────┤├──────┬──── GPIO34 (ADC1)
                   100 nF  R4    ESP32
SPK- / GND ─────────────────┘
                            4.7kΩ
                             │
                            GND
```

**Component values:**
- **C2:** 100 nF (DC blocking)
- **R3:** 10 kΩ to GPIO34 (limits ADC input current; forms low-pass with stray capacitance)
- **R4:** 4.7 kΩ to GND (biases signal to mid-scale ≈ 1.65 V for the ADC)

Add a voltage divider (2:1) if the radio speaker output exceeds 3 V peak:
- **R_top:** 10 kΩ, **R_bot:** 10 kΩ → halves the signal

**ADC configuration:** The firmware uses ADC1 channel 6 (GPIO34) with 11 dB attenuation (`ADC_ATTEN_DB_11`), which gives a full-scale input range of ~3.9 V, effectively using the full 3.3 V GPIO range.

**ADC noise:** The ESP32's internal ADC is noisy (~30–50 LSB of noise floor at 12 bits).  This is acceptable for AFSK at moderate SNR.  For improved sensitivity, an external ADC (MCP3201, ADS1115) connected via SPI/I²C and sampled in the ISR can replace `adc1_get_raw()` with minimal code change.

---

## Power Supply

- **Drone transmitter:** power from a dedicated 5 V BEC or the flight controller's 5 V servo rail.  Do NOT use the same BEC as the motors — switching noise will couple into the audio DAC output.
- **Ground receiver:** USB power or separate 5 V supply.

---

## MAVLink UART to Pixhawk

Pixhawk **TELEM2** or **TELEM1** connector (JST-GH 6-pin):

| Pixhawk Pin | Signal  | ESP32 Pin |
|-------------|---------|-----------|
| 1           | 5V out  | VIN (via 500 mA regulator) |
| 2           | TX      | GPIO16 (ESP32 RX) |
| 3           | RX      | GPIO17 (ESP32 TX) |
| 4           | CTS     | — |
| 5           | RTS     | — |
| 6           | GND     | GND |

Set `SERIAL2_BAUD = 57` (57600) and `SERIAL2_PROTOCOL = 2` (MAVLink 2) in ArduPilot parameters.
