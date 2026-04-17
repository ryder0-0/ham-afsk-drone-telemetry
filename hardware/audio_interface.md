# Audio Interface Design Notes

## Transmitter: DAC to Radio Mic

### Level Budget

| Stage                     | Level          |
|---------------------------|----------------|
| ESP32 DAC full scale      | 0–3.3 V (1.65 V centre) |
| After C1 (AC coupling)    | ±1.65 V peak   |
| After R1/R2 divider (10k/4.7k) | ±0.68 V peak |
| Typical HT mic sensitivity | 10–100 mV for full deviation |
| **Required attenuation**  | ~20–30 dB additional |

Set the R1/R2 ratio so the signal into the mic is around 50 mV peak.  For a 100 mV mic input (common), use R1=100 kΩ, R2=4.7 kΩ (ratio ≈ 21:1 → 68 mV peak from 1.65 V source).  Fine-tune with a spectrum analyser or by monitoring deviation with a calibrated service monitor.

**Target: ±3 kHz deviation** for maximum 1200 baud AFSK (Bell 202 spec is ±3 kHz).

### Pre-emphasis Bypass

Many mobile radios and APRS TNCs use a 9600-baud flat audio port (on a DATA or ACC connector on the back of the radio, bypassing the speech processor and pre-emphasis network).  **Use this port if available.**  On Yaesu FT-857/897, use the DATA MIC/AFSK input on the 6-pin mini-DIN.

If you must use the regular mic connector, the pre-emphasis network boosts 2200 Hz by approximately:
```
20 × log10(2200/1200) ≈ 5.3 dB
```
relative to 1200 Hz.  To compensate, add a simple de-emphasis RC on the transmitter output:
```
GPIO25 → C1(100nF) → [series R = 7.5kΩ] → Mic input
                               │
                              C3(68nF) to GND   ← de-emphasis cap
```
Corner frequency = 1/(2π × 7500 × 68e-9) ≈ 312 Hz (too low).

Better: use corner frequency = 1/(2π × 3300 × 15e-9) ≈ 3200 Hz, matching the FM receiver's 75 µs de-emphasis.

### Common-Mode Noise

The drone motor ESCs generate significant common-mode RF noise.  To prevent this from coupling into the audio path:
1. Keep audio wiring short and shielded (coax or twisted pair).
2. Add a ferrite bead (43 or 31 material) on the audio wire at the ESP32 GPIO25 pin.
3. Power the ESP32 from a filtered BEC, not the main motor battery directly.
4. Add a 100 nF + 10 µF decoupling cap between ESP32 3.3V and GND, placed physically close to the ESP32.

---

## Receiver: Radio Speaker to ADC

### Level Budget

| Stage                     | Level          |
|---------------------------|----------------|
| Radio speaker out (typical) | 0.5–2 V peak (into 8 Ω speaker load) |
| Into R3/R4 divider (10k/4.7k, high impedance) | 0.3–1.2 V |
| After DC bias (R4 to GND) | centred near 0–2 V ✓ for ADC |
| ESP32 ADC range (11 dB atten) | 0–3.9 V → use 0–3.3 V |
| **ADC code at mid-scale** | ~2048 (12-bit) |

### Squelch Considerations

Most HT receivers open squelch only when a signal is present.  The squelch will:
1. Delay about 10–50 ms between first RF carrier and audio output — this is absorbed by the 167 ms preamble.
2. Produce a squelch tail (noise burst) for 50–200 ms after the signal ends — the receiver's CRC check will reject any garbage bytes from this burst.

If you hear the squelch tail overlapping the next packet's preamble, slightly increase `PREAMBLE_LEN` in `modem_config.h`.

### External Speaker Jack

The external speaker (EXT SP) jack on most HTs outputs audio **before** the internal volume pot in some models, but **after** in others.  If the audio level is very low, check whether the volume control affects the speaker jack.  Some radios (e.g. Baofeng UV-5R) have an independent external speaker volume.

### Noise Performance

The ESP32 ADC has approximately 30–50 LSB RMS noise (at 12 bits), which corresponds to an input-referred noise of:
```
30 LSB × (3.3 V / 4096) ≈ 24 mV RMS
```
For a 500 mV peak signal (354 mV RMS), SNR ≈ 23 dB — sufficient for reliable demodulation down to about 10 dB SNR with the IIR correlator.

For receiver sensitivity below –110 dBm, consider an external low-noise audio amplifier (e.g. LM358 in single-supply config) between the radio and the ADC to boost the signal before quantisation.
