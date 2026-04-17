#!/usr/bin/env python3
"""
FILE: tools/python_decoder/wav_decoder.py

Decode a WAV file (or stdin audio) containing AFSK Bell 202 packets.
Matches the quadrature IIR demodulator in firmware/receiver/src/afsk_demodulator.cpp.

Usage:
    python wav_decoder.py input.wav
    python wav_decoder.py input.wav --verbose
    python wav_decoder.py input.wav --out decoded.bin
"""

import argparse
import struct
import sys
import wave
import numpy as np

# ---------------------------------------------------------------------------
# Modem constants — must match modem_config.h
# ---------------------------------------------------------------------------
SAMPLE_RATE     = 9600
BAUD_RATE       = 1200
SAMPLES_PER_BIT = SAMPLE_RATE // BAUD_RATE   # 8

MARK_FREQ       = 1200
SPACE_FREQ      = 2200

IIR_ALPHA           = 0.25
IIR_ONE_MINUS_ALPHA = 0.75
TONE_HYSTERESIS     = 1.08

PREAMBLE_BYTE = 0xAA
SYNC_BYTE_0   = 0x2D
SYNC_BYTE_1   = 0xD4

PKT_TYPE_MAVLINK   = 0x00
PKT_TYPE_TELEM     = 0x01
PKT_TYPE_HEARTBEAT = 0xFF

MAX_PAYLOAD_LEN = 260

def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = (crc << 1) ^ 0x1021 if (crc & 0x8000) else (crc << 1)
            crc &= 0xFFFF
    return crc

# ---------------------------------------------------------------------------
# Quadrature demodulator — Python reference implementation of the C++ code
# ---------------------------------------------------------------------------

def demodulate_samples(samples: np.ndarray, verbose: bool = False):
    """
    Demodulate float32 samples [-1.0, 1.0] at SAMPLE_RATE Hz.
    Returns list of decoded bytes.
    """
    n_samples = len(samples)

    # Pre-compute reference tones
    t = np.arange(n_samples, dtype=np.float64)
    mark_cos  = np.cos(2 * np.pi * MARK_FREQ  * t / SAMPLE_RATE)
    mark_sin  = np.sin(2 * np.pi * MARK_FREQ  * t / SAMPLE_RATE)
    space_cos = np.cos(2 * np.pi * SPACE_FREQ * t / SAMPLE_RATE)
    space_sin = np.sin(2 * np.pi * SPACE_FREQ * t / SAMPLE_RATE)

    # IIR filter — implemented as vectorised first-order recursion
    # y[n] = alpha * x[n] + (1-alpha) * y[n-1]
    def iir_filter(x: np.ndarray) -> np.ndarray:
        out = np.zeros_like(x)
        state = 0.0
        for i in range(len(x)):
            state = IIR_ALPHA * x[i] + IIR_ONE_MINUS_ALPHA * state
            out[i] = state
        return out

    s = samples.astype(np.float64)

    mi_f  = iir_filter(s * mark_cos)
    mq_f  = iir_filter(s * mark_sin)
    si_f  = iir_filter(s * space_cos)
    sq_f  = iir_filter(s * space_sin)

    mark_pwr  = iir_filter(mi_f**2 + mq_f**2)
    space_pwr = iir_filter(si_f**2 + sq_f**2)

    # Tone decisions with hysteresis
    tones = np.full(n_samples, -1, dtype=np.int8)  # -1 = unknown
    current_tone = -1
    for i in range(n_samples):
        if mark_pwr[i] > space_pwr[i] * TONE_HYSTERESIS:
            current_tone = 1
        elif space_pwr[i] > mark_pwr[i] * TONE_HYSTERESIS:
            current_tone = 0
        tones[i] = current_tone

    # Bit clock PLL + NRZI decode
    # Two distinct tone-state variables (mirrors the C++ firmware):
    #   current_tone      — tone at the previous sample; used for edge detection
    #   prev_sampled_tone — tone at the last bit-centre sample; used for NRZI decode
    decoded_bytes     = []
    bit_phase         = 0
    current_tone      = -1
    prev_sampled_tone = -1
    byte_accum        = 0
    bit_in_byte       = 0

    for i in range(n_samples):
        new_tone = int(tones[i])

        # Sample-to-sample transition detection → reset bit clock to bit edge
        transition = (new_tone != current_tone) and (current_tone != -1)
        current_tone = new_tone
        if transition:
            bit_phase = 0

        # Sample at centre of bit (mirrors C++: increment-then-test)
        bit_phase += 1
        if bit_phase == SAMPLES_PER_BIT // 2:
            if prev_sampled_tone == -1:
                bit = 1
            else:
                bit = 1 if (current_tone == prev_sampled_tone) else 0

            prev_sampled_tone = current_tone

            # Accumulate bits LSB-first
            byte_accum |= (bit & 1) << bit_in_byte
            bit_in_byte += 1
            if bit_in_byte == 8:
                decoded_bytes.append(byte_accum)
                byte_accum  = 0
                bit_in_byte = 0

        if bit_phase >= SAMPLES_PER_BIT:
            bit_phase = 0

    if verbose:
        print(f'  Demodulated {n_samples} samples → {len(decoded_bytes)} bytes')

    return bytes(decoded_bytes)

# ---------------------------------------------------------------------------
# Packet framer (incremental byte-by-byte)
# ---------------------------------------------------------------------------
class PacketDecoder:
    IDLE    = 0
    SYNC1   = 1
    TYPE    = 2
    SEQ     = 3
    LEN_LO  = 4
    LEN_HI  = 5
    PAYLOAD = 6
    CRC_LO  = 7
    CRC_HI  = 8

    def __init__(self):
        self.reset()
        self.packets = []
        self.stats = {'ok': 0, 'crc_fail': 0, 'overflow': 0}

    def reset(self):
        self.state      = self.IDLE
        self.pkt_type   = 0
        self.pkt_seq    = 0
        self.pkt_len    = 0
        self.payload    = bytearray()
        self.crc_accum  = 0xFFFF
        self.crc_rx     = 0

    def _crc_update(self, byte):
        self.crc_accum ^= byte << 8
        for _ in range(8):
            if self.crc_accum & 0x8000:
                self.crc_accum = (self.crc_accum << 1) ^ 0x1021
            else:
                self.crc_accum <<= 1
            self.crc_accum &= 0xFFFF

    def feed(self, byte):
        """Feed one byte.  Returns 'ok', 'crc_fail', 'overflow', or None."""
        s = self.state

        if s == self.IDLE:
            if byte == SYNC_BYTE_0:
                self.crc_accum = 0xFFFF
                self._crc_update(byte)
                self.state = self.SYNC1

        elif s == self.SYNC1:
            if byte == SYNC_BYTE_1:
                self._crc_update(byte)
                self.state = self.TYPE
            elif byte == SYNC_BYTE_0:
                self.crc_accum = 0xFFFF
                self._crc_update(byte)
            else:
                self.reset()

        elif s == self.TYPE:
            self.pkt_type = byte
            self._crc_update(byte)
            self.state = self.SEQ

        elif s == self.SEQ:
            self.pkt_seq = byte
            self._crc_update(byte)
            self.state = self.LEN_LO

        elif s == self.LEN_LO:
            self.pkt_len = byte
            self._crc_update(byte)
            self.state = self.LEN_HI

        elif s == self.LEN_HI:
            self.pkt_len |= byte << 8
            self._crc_update(byte)
            if self.pkt_len > MAX_PAYLOAD_LEN:
                self.reset()
                self.stats['overflow'] += 1
                return 'overflow'
            self.payload = bytearray()
            self.state = self.PAYLOAD if self.pkt_len > 0 else self.CRC_LO

        elif s == self.PAYLOAD:
            self.payload.append(byte)
            self._crc_update(byte)
            if len(self.payload) == self.pkt_len:
                self.state = self.CRC_LO

        elif s == self.CRC_LO:
            self.crc_rx = byte
            self.state  = self.CRC_HI

        elif s == self.CRC_HI:
            self.crc_rx |= byte << 8
            result = 'ok' if self.crc_rx == self.crc_accum else 'crc_fail'
            if result == 'ok':
                self.packets.append({
                    'type':    self.pkt_type,
                    'seq':     self.pkt_seq,
                    'payload': bytes(self.payload),
                })
                self.stats['ok'] += 1
            else:
                self.stats['crc_fail'] += 1
            self.reset()
            return result

        return None

# ---------------------------------------------------------------------------
# WAV reader
# ---------------------------------------------------------------------------
def read_wav(filename: str):
    """Return (samples as float32 ndarray, actual_sample_rate)."""
    with wave.open(filename, 'r') as wf:
        n_channels  = wf.getnchannels()
        samp_width  = wf.getsampwidth()
        actual_rate = wf.getframerate()
        n_frames    = wf.getnframes()
        raw         = wf.readframes(n_frames)

    dtype = np.int16 if samp_width == 2 else np.int8
    pcm = np.frombuffer(raw, dtype=dtype)
    if n_channels > 1:
        pcm = pcm[::n_channels]   # take left channel only

    samples = pcm.astype(np.float32) / 32768.0
    return samples, actual_rate

# ---------------------------------------------------------------------------
# Packet renderer
# ---------------------------------------------------------------------------
def render_packet(pkt: dict, verbose: bool):
    ptype   = pkt['type']
    seq     = pkt['seq']
    payload = pkt['payload']

    type_name = {
        PKT_TYPE_MAVLINK:   'MAVLink tunnel',
        PKT_TYPE_TELEM:     'Telem summary',
        PKT_TYPE_HEARTBEAT: 'Heartbeat',
    }.get(ptype, f'Unknown(0x{ptype:02X})')

    print(f'  [PKT] seq={seq:3d} type={type_name:16s} len={len(payload):4d}', end='')

    if ptype == PKT_TYPE_TELEM and len(payload) == 24:
        lat, lon, alt_mm, hdg_cd, spd_cms, batt_mv, batt_pct, sats, mode, armed, rssi = \
            struct.unpack('<iiihhhBBBBh', payload)
        print(f'  lat={lat/1e7:.5f} lon={lon/1e7:.5f} alt={alt_mm/1000:.1f}m '
              f'hdg={hdg_cd/100:.0f}° spd={spd_cms/100:.1f}m/s '
              f'batt={batt_mv}mV({batt_pct}%) sats={sats} rssi={rssi}')
    elif ptype == PKT_TYPE_MAVLINK and len(payload) >= 6:
        msg_id = payload[5]
        print(f'  MAVLink msgid={msg_id}')
    else:
        print()

    if verbose and payload:
        hex_str = ' '.join(f'{b:02X}' for b in payload[:32])
        suffix  = '...' if len(payload) > 32 else ''
        print(f'        payload: {hex_str}{suffix}')

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description='AFSK Bell 202 WAV file decoder')
    ap.add_argument('input',          help='Input WAV file')
    ap.add_argument('--verbose', '-v', action='store_true')
    ap.add_argument('--out',          help='Write decoded payloads to binary file')
    args = ap.parse_args()

    print(f'Reading {args.input}...')
    samples, actual_rate = read_wav(args.input)
    print(f'  {len(samples)} samples @ {actual_rate} Hz  ({len(samples)/actual_rate*1000:.0f} ms)')

    if actual_rate != SAMPLE_RATE:
        # Resample to SAMPLE_RATE
        try:
            from scipy.signal import resample_poly
            from math import gcd
            g = gcd(SAMPLE_RATE, actual_rate)
            up, down = SAMPLE_RATE // g, actual_rate // g
            samples = resample_poly(samples, up, down).astype(np.float32)
            print(f'  Resampled {actual_rate} → {SAMPLE_RATE} Hz')
        except ImportError:
            print('  WARNING: scipy not available; skipping resample — results may be wrong')

    print('Demodulating...')
    raw_bytes = demodulate_samples(samples, verbose=args.verbose)
    print(f'  → {len(raw_bytes)} raw bytes')

    print('Decoding packets...')
    decoder = PacketDecoder()
    for b in raw_bytes:
        decoder.feed(b)

    print(f'\nResults: {decoder.stats["ok"]} OK  '
          f'{decoder.stats["crc_fail"]} CRC-fail  '
          f'{decoder.stats["overflow"]} overflow\n')

    for pkt in decoder.packets:
        render_packet(pkt, args.verbose)

    if args.out and decoder.packets:
        with open(args.out, 'wb') as f:
            for pkt in decoder.packets:
                if pkt['type'] in (PKT_TYPE_MAVLINK, PKT_TYPE_TELEM):
                    f.write(pkt['payload'])
        print(f'\nWrote decoded payloads to {args.out}')


if __name__ == '__main__':
    main()
