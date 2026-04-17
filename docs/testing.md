# Testing Procedure

Testing is staged so you can debug each layer independently before adding the next.

---

## Stage 1: Python Loopback (No Hardware)

This proves the packet format, NRZI encoding, CRC, and demodulator all agree.

```bash
cd tools/wav_test_generator
pip install -r requirements.txt
python generate_test_wav.py --out ../test.wav --packets 5

cd ../python_decoder
pip install -r requirements.txt
python wav_decoder.py ../test.wav --verbose
```

**Expected output:**
```
Reading ../test.wav...
  48000 samples @ 9600 Hz  (5000 ms)
Demodulating...
  → 500 raw bytes
Decoding packets...

Results: 5 OK  0 CRC-fail  0 overflow

  [PKT] seq=  0 type=MAVLink tunnel   len=  17  MAVLink msgid=0
  [PKT] seq=  1 type=Telem summary    len=  22  lat=37.77590 lon=-122.41940 alt=55.0m ...
  [PKT] seq=  2 type=Heartbeat        len=   0
  ...
```

**If this fails:** the Python tools have a bug or are out of sync with the firmware constants.  Check `SAMPLE_RATE`, `MARK_FREQ`, `SPACE_FREQ`, `PREAMBLE_LEN`, and the CRC in both `generate_test_wav.py` and `wav_decoder.py`.

### Noise Robustness

```bash
python generate_test_wav.py --noise 20   # add 20 dB SNR AWGN
python wav_decoder.py test_afsk.wav
```

Expected: at 20 dB SNR all 3 packets decode.  At 10 dB SNR expect ~1–2 CRC failures out of 3.

---

## Stage 2: Transmitter → Soundcard → Python Decoder

Proves the ESP32 transmitter firmware produces correct audio, without needing a radio.

1. Flash the transmitter firmware (see `building_flashing.md`).
2. Connect GPIO25 → 100 nF cap → PC line-in jack, with a 10 kΩ resistor to ground.  **Do not** connect directly to mic input (too hot).
3. Record with `arecord` / `sox` / Audacity at 48 kHz, 16-bit mono:
   ```bash
   arecord -f S16_LE -r 48000 -c 1 capture.wav
   ```
4. Power up the transmitter.  It will send a heartbeat every 5 seconds.
5. Stop recording after ~30 seconds.
6. Decode:
   ```bash
   python tools/python_decoder/wav_decoder.py capture.wav
   ```

**Expected:** at least 4–5 heartbeat packets decoded out of the ~6 sent.  If all fail, check:
- Audio level: signal in the WAV should be ±0.3 to ±0.8, not clipped and not too quiet.
- Sample rate: the decoder auto-resamples 48 kHz → 9600 Hz via scipy.

---

## Stage 3: Python Encoder → Soundcard → ESP32 Receiver

Proves the ESP32 receiver firmware works without needing a radio.

1. Flash the receiver firmware.
2. Connect PC headphone jack (left channel) → 100 nF cap → 10 kΩ → ESP32 GPIO34, with 4.7 kΩ to GND (same conditioning as real receiver).
3. Open serial monitor on the ESP32 at 115200:
   ```bash
   pio device monitor -e esp32dev -p /dev/ttyUSB1 -b 115200
   ```
4. Run the Python encoder:
   ```bash
   cd tools/python_encoder
   pip install -r requirements.txt sounddevice
   python encode_stream.py --amplitude 0.4
   ```
5. Watch the ESP32 serial monitor — you should see `[RX] Packet OK ...` lines appearing every ~2 seconds.

**Tuning:** adjust PC volume so the ESP32 sees roughly ±0.5 V peak at GPIO34 (check with an oscilloscope or scope trace via the ESP32's built-in ADC by enabling raw-sample dumps).

---

## Stage 4: Full RF Link (Transmitter Radio → Receiver Radio)

1. Set both radios to the same simplex frequency on a low-power band plan allocation (VHF 2 m: 144.390 MHz is the US APRS frequency; only use if you are a licensed amateur and APRS activity is low).  **Never test on public-service, military, or aviation frequencies.**
2. Set both radios to narrow FM (12.5 kHz), CTCSS/DCS off, squelch open or at minimum.
3. Power up transmitter first, verify heartbeats on a scanner / SDR.
4. Power up receiver; watch serial monitor.
5. Walk the receiver away from the transmitter — note RSSI and packet-success rate as distance increases.

### Range Expectations

| Scenario                      | Expected Range (line of sight) |
|-------------------------------|-------------------------------|
| 5 W HT → 5 W HT, rubber duck antennas | 1–3 km |
| 5 W HT → 5 W HT, 1/4-wave vertical both ends | 3–8 km |
| 5 W HT (drone airborne, 100 m) → 5 W ground w/ yagi | 20–50 km |
| 25 W mobile → 50 W base, good antennas | 30–80 km |

Amateur drone telemetry relies on altitude for range.  Line-of-sight from 100 m AGL is theoretically 36 km; in practice 20–40 km is achievable with modest antennas.

---

## Debugging Checklist

| Symptom                                | Likely Cause | Fix |
|----------------------------------------|--------------|-----|
| No packets at all                      | Wrong audio wiring; ADC saturated | Check with `analogRead()` dump; expect values 1800–2300 |
| Many CRC failures                       | Weak signal; audio clipping | Lower TX level or increase RX gain |
| Only first byte correct, rest garbled  | Bit clock not syncing | Check that preamble length is correct; look at raw bit stream |
| First few packets OK, then silence     | TX heap leak or buffer overflow | Check `[TX]` serial output for warnings |
| Works Python→Python, fails with ESP32  | Sample rate mismatch | ESP32 timer is 9615 Hz not 9600; PLL should handle this |
| Heartbeats work, MAVLink doesn't       | MAVLink frames > 260 bytes | Enable summary mode (`TELEM_MODE_SUMMARY=1`) |
