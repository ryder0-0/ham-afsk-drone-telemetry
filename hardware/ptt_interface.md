# PTT Interface

## Overview

Most amateur radios use an active-low PTT: shorting the PTT pin to GND begins transmission.  The ESP32 GPIO4 output (active HIGH) drives an NPN transistor to pull the radio's PTT pin to ground.

## Schematic

```
ESP32 GPIO4 (PTT)
     │
    [R1]  1 kΩ
     │
     ├────── NPN Base  (2N2222, BC547, or similar)
                │
            Collector ──── Radio PTT Pin
                │
            Emitter ────── GND (common with radio)
```

**Parts:**
- **Q1:** NPN transistor — 2N2222, BC547, 2N3904, or MMBT2222 (SMD)
- **R1:** 1 kΩ base resistor — limits GPIO current and sets base drive
- **Optional: D1:** 1N4148 diode from Collector to +3.3 V — protects against inductive kick if PTT pin has a pull-up resistor or reed relay internally

## Radio PTT Wiring by Connector Type

| Radio Type              | PTT Connection |
|-------------------------|----------------|
| Baofeng UV-5R / UV-82   | 3.5 mm TRRS jack, tip = PTT, sleeve = GND |
| Kenwood/Icom 2-pin       | 2.5 mm tip = PTT, 3.5 mm = MIC, sleeve = GND |
| Yaesu HT (3-pin Yaesu)  | 2.5 mm jack, ring = PTT, sleeve = GND |
| Mobile radio (6-pin MIC) | Pin 4 typically PTT, Pin 1 or 2 = GND |

Always verify with the radio's service manual.  Wiring PTT incorrectly with a voltage source (rather than GND) can damage the radio front-end.

## Timing

| Event              | Delay       | Reason |
|--------------------|-------------|--------|
| PTT assert → audio | 80 ms       | Radio PA and PLL settle time.  Most HTs are specified at 50–100 ms.  Baofeng HTs are slow; 80 ms is conservative. |
| Last audio → PTT release | 60 ms | The FM receiver's squelch circuit introduces a 50–200 ms "squelch tail" after a transmission ends.  Holding PTT for 60 ms after the last audio sample ensures the receiver is done decoding before the channel goes silent. |

These delays are defined in `modem_config.h` as `PTT_SETTLE_MS` and `PTT_TAIL_MS`.

## Adjusting for Your Radio

If packets are consistently clipped at the start, increase `PTT_SETTLE_MS` by 20 ms increments.

If the receiver drops the last few bytes of every packet, increase `PTT_TAIL_MS` by 20 ms increments.

Both changes are in a single header file with no other code impact.
