#!/usr/bin/env python3
"""
FILE: tools/wav_test_generator/generate_test_wav.py

Generate a WAV file containing one or more valid AFSK Bell 202 packets.
The output file can be played back through a radio's mic input, or fed
directly to the Python decoder for loopback testing.

Usage:
    python generate_test_wav.py [--out output.wav] [--packets N] [--noise SNR_DB]

All constants MUST match firmware/common/include/modem_config.h exactly.
"""

import argparse
import struct
import wave
import numpy as np

# ---------------------------------------------------------------------------
# Modem constants — mirror of modem_config.h
# ---------------------------------------------------------------------------
SAMPLE_RATE     = 9600
BAUD_RATE       = 1200
SAMPLES_PER_BIT = SAMPLE_RATE // BAUD_RATE   # 8

MARK_FREQ       = 1200   # Bell 202 mark
SPACE_FREQ      = 2200   # Bell 202 space

PREAMBLE_BYTE   = 0xAA
PREAMBLE_LEN    = 25

SYNC_BYTE_0     = 0x2D
SYNC_BYTE_1     = 0xD4

PKT_TYPE_MAVLINK   = 0x00
PKT_TYPE_TELEM     = 0x01
PKT_TYPE_HEARTBEAT = 0xFF

# CRC16-CCITT
def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = (crc << 1) ^ 0x1021
            else:
                crc <<= 1
            crc &= 0xFFFF
    return crc

# ---------------------------------------------------------------------------
# NRZI encoding
# ---------------------------------------------------------------------------
def bytes_to_bits_lsb(data: bytes) -> list:
    """Expand bytes to LSB-first bit list."""
    bits = []
    for byte in data:
        for i in range(8):
            bits.append((byte >> i) & 1)
    return bits

def nrzi_encode(bits: list) -> list:
    """NRZI: bit 0 → transition, bit 1 → no transition.  Initial tone = MARK (1)."""
    tones = []
    current = 1   # start on MARK
    for bit in bits:
        if bit == 0:
            current ^= 1
        tones.append(current)
    return tones

# ---------------------------------------------------------------------------
# Packet builder
# ---------------------------------------------------------------------------
def build_packet_wire(pkt_type: int, seq: int, payload: bytes) -> bytes:
    """
    Return the complete wire-format byte string for one packet.
    Wire format:
        [PREAMBLE × PREAMBLE_LEN] [SYNC_0] [SYNC_1] [TYPE] [SEQ]
        [LEN_LO] [LEN_HI] [PAYLOAD] [CRC_LO] [CRC_HI]
    CRC covers sync word through end of payload.
    """
    hdr = bytes([SYNC_BYTE_0, SYNC_BYTE_1, pkt_type, seq])
    hdr += struct.pack('<H', len(payload))
    body = hdr + payload
    crc = crc16_ccitt(body)
    preamble = bytes([PREAMBLE_BYTE] * PREAMBLE_LEN)
    return preamble + body + struct.pack('<H', crc)

# ---------------------------------------------------------------------------
# AFSK modulator
# ---------------------------------------------------------------------------
def modulate(wire_bytes: bytes, amplitude: float = 0.8) -> np.ndarray:
    """
    AFSK modulate wire_bytes to float32 audio samples in [-1.0, 1.0].
    amplitude: peak amplitude (0.0–1.0).  0.8 leaves headroom for filtering.
    Phase is continuous across bits to avoid clicks.
    """
    bits  = bytes_to_bits_lsb(wire_bytes)
    tones = nrzi_encode(bits)

    total_samples = len(tones) * SAMPLES_PER_BIT
    samples = np.zeros(total_samples, dtype=np.float64)

    phase = 0.0
    idx   = 0
    for tone in tones:
        freq = MARK_FREQ if tone == 1 else SPACE_FREQ
        freq_step = 2.0 * np.pi * freq / SAMPLE_RATE
        for _ in range(SAMPLES_PER_BIT):
            samples[idx] = amplitude * np.sin(phase)
            idx += 1
            phase += freq_step
            phase %= (2.0 * np.pi)   # keep phase in [0, 2π) to avoid float drift

    return samples.astype(np.float32)

# ---------------------------------------------------------------------------
# WAV writer (16-bit PCM, mono)
# ---------------------------------------------------------------------------
def write_wav(filename: str, samples: np.ndarray, sample_rate: int = SAMPLE_RATE):
    # Convert float32 [-1, 1] → int16
    pcm = (np.clip(samples, -1.0, 1.0) * 32767.0).astype(np.int16)
    with wave.open(filename, 'w') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)   # 16-bit
        wf.setframerate(sample_rate)
        wf.writeframes(pcm.tobytes())

# ---------------------------------------------------------------------------
# Test payload builders
# ---------------------------------------------------------------------------
def make_heartbeat_payload() -> bytes:
    return b''   # heartbeat has empty payload

def make_mavlink_payload() -> bytes:
    """Minimal synthetic MAVLink v1 HEARTBEAT frame (type=0, fc=3, custom_mode=0)."""
    stx         = 0xFE
    payload_len = 9
    seq         = 42
    sysid       = 1
    compid      = 1
    msgid       = 0   # HEARTBEAT
    mav_payload = bytes([0,0,0,0,  # custom_mode
                         6,        # type = GCS (6)
                         8,        # autopilot = ArduPilot (8)
                         0xC1,     # base_mode = armed | stabilize
                         0,        # system_status
                         3])       # mavlink_version
    # MAVLink CRC extra for HEARTBEAT = 50
    crc_data = bytes([payload_len, seq, sysid, compid, msgid]) + mav_payload
    crc = crc16_ccitt(crc_data)
    crc = crc16_ccitt(bytes([50]) + struct.pack('<H', crc))   # apply extra byte
    # Recalculate properly
    crc = 0xFFFF
    for b in bytes([payload_len, seq, sysid, compid, msgid]) + mav_payload:
        crc ^= b << 8
        for _ in range(8):
            crc = (crc << 1) ^ 0x1021 if (crc & 0x8000) else (crc << 1)
            crc &= 0xFFFF
    # apply CRC extra
    crc ^= 50 << 8
    for _ in range(8):
        crc = (crc << 1) ^ 0x1021 if (crc & 0x8000) else (crc << 1)
        crc &= 0xFFFF

    frame = bytes([stx, payload_len, seq, sysid, compid, msgid]) + mav_payload
    frame += struct.pack('<H', crc)
    return frame

def make_telem_summary_payload(lat=37.7749, lon=-122.4194,
                                alt_m=50.0, hdg=180, spd_ms=5.0,
                                batt_mv=11800, batt_pct=85,
                                sats=12, mode=3, armed=1) -> bytes:
    """Pack a TelemetrySummary struct (22 bytes, matches firmware struct)."""
    return struct.pack('<iiihhhBBBBh',
                       int(lat * 1e7),
                       int(lon * 1e7),
                       int(alt_m * 1000),
                       int(hdg * 100),
                       int(spd_ms * 100),
                       batt_mv,
                       batt_pct,
                       sats,
                       mode,
                       armed,
                       75)   # rssi_est placeholder

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description='AFSK Bell 202 test WAV generator')
    ap.add_argument('--out',     default='test_afsk.wav', help='Output WAV filename')
    ap.add_argument('--packets', type=int, default=3,     help='Number of test packets')
    ap.add_argument('--noise',   type=float, default=None,
                    help='Add AWGN at specified SNR dB (e.g. 20)')
    ap.add_argument('--gap-ms',  type=int, default=200,
                    help='Silence gap between packets in ms (default 200)')
    args = ap.parse_args()

    all_samples = []
    gap = np.zeros(int(SAMPLE_RATE * args.gap_ms / 1000.0), dtype=np.float32)

    for seq in range(args.packets):
        pkt_type = seq % 3
        if pkt_type == 0:
            payload = make_mavlink_payload()
            ptype   = PKT_TYPE_MAVLINK
            label   = 'MAVLink tunnel'
        elif pkt_type == 1:
            payload = make_telem_summary_payload(
                lat=37.7749 + seq * 0.001,
                alt_m=50 + seq * 5)
            ptype   = PKT_TYPE_TELEM
            label   = 'Telem summary'
        else:
            payload = make_heartbeat_payload()
            ptype   = PKT_TYPE_HEARTBEAT
            label   = 'Heartbeat'

        wire  = build_packet_wire(ptype, seq, payload)
        audio = modulate(wire)

        duration_ms = len(audio) * 1000 / SAMPLE_RATE
        print(f'  Packet {seq}: type={label:16s} wire={len(wire):4d} B  '
              f'audio={len(audio):6d} smp  ({duration_ms:.0f} ms)')

        all_samples.append(audio)
        all_samples.append(gap)

    combined = np.concatenate(all_samples)

    if args.noise is not None:
        snr_linear = 10.0 ** (args.noise / 10.0)
        signal_pwr = np.mean(combined ** 2)
        noise_std  = np.sqrt(signal_pwr / snr_linear)
        noise = np.random.randn(len(combined)).astype(np.float32) * noise_std
        combined = np.clip(combined + noise, -1.0, 1.0).astype(np.float32)
        print(f'  Added AWGN at {args.noise:.1f} dB SNR (std={noise_std:.4f})')

    write_wav(args.out, combined)
    total_ms = len(combined) * 1000 / SAMPLE_RATE
    print(f'\nWrote {args.out}  ({len(combined)} samples, {total_ms:.0f} ms total)')
    print(f'Sample rate: {SAMPLE_RATE} Hz  Baud: {BAUD_RATE}  Tones: {MARK_FREQ}/{SPACE_FREQ} Hz')


if __name__ == '__main__':
    main()
