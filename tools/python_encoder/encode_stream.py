#!/usr/bin/env python3
"""
FILE: tools/python_encoder/encode_stream.py

CLI tool that reads MAVLink bytes from a serial port (or stdin),
packetises them, AFSK-modulates them, and plays them back through
the system sound card.  Useful for ground-station-side injection
or desktop loopback testing without an ESP32.

Dependencies:
    pip install numpy pyserial sounddevice

Usage:
    # Read from flight controller on /dev/ttyUSB0 and transmit via soundcard
    python encode_stream.py --port /dev/ttyUSB0 --baud 57600

    # Pipe pre-recorded MAVLink bytes
    cat flight.mavlink | python encode_stream.py --stdin

    # List audio output devices
    python encode_stream.py --list-devices
"""

import argparse
import struct
import sys
import threading
import queue
import time
import numpy as np

# ---------------------------------------------------------------------------
# Import modem constants from generator tool (or redefine here)
# ---------------------------------------------------------------------------
SAMPLE_RATE     = 9600
BAUD_RATE       = 1200
SAMPLES_PER_BIT = SAMPLE_RATE // BAUD_RATE

MARK_FREQ  = 1200
SPACE_FREQ = 2200

PREAMBLE_BYTE = 0xAA
PREAMBLE_LEN  = 25
SYNC_BYTE_0   = 0x2D
SYNC_BYTE_1   = 0xD4

PKT_TYPE_MAVLINK   = 0x00
PKT_TYPE_HEARTBEAT = 0xFF

MAX_PAYLOAD_LEN = 260
HEARTBEAT_INTERVAL_S = 5.0

def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = (crc << 1) ^ 0x1021 if (crc & 0x8000) else (crc << 1)
            crc &= 0xFFFF
    return crc

def bytes_to_bits_lsb(data: bytes) -> list:
    return [(b >> i) & 1 for b in data for i in range(8)]

def nrzi_encode(bits: list) -> list:
    current = 1
    tones = []
    for bit in bits:
        if bit == 0:
            current ^= 1
        tones.append(current)
    return tones

def build_packet_wire(pkt_type: int, seq: int, payload: bytes) -> bytes:
    hdr  = bytes([SYNC_BYTE_0, SYNC_BYTE_1, pkt_type, seq])
    hdr += struct.pack('<H', len(payload))
    body = hdr + payload
    crc  = crc16_ccitt(body)
    return bytes([PREAMBLE_BYTE] * PREAMBLE_LEN) + body + struct.pack('<H', crc)

def modulate(wire_bytes: bytes, amplitude: float = 0.8) -> np.ndarray:
    bits   = bytes_to_bits_lsb(wire_bytes)
    tones  = nrzi_encode(bits)
    out    = np.empty(len(tones) * SAMPLES_PER_BIT, dtype=np.float32)
    phase  = 0.0
    idx    = 0
    for tone in tones:
        step = 2.0 * np.pi * (MARK_FREQ if tone else SPACE_FREQ) / SAMPLE_RATE
        for _ in range(SAMPLES_PER_BIT):
            out[idx] = amplitude * np.sin(phase)
            idx += 1
            phase = (phase + step) % (2.0 * np.pi)
    return out

# ---------------------------------------------------------------------------
# MAVLink v1 frame reader (mirrors MavlinkReader in firmware)
# ---------------------------------------------------------------------------
class MavlinkFramer:
    def __init__(self):
        self._buf  = bytearray()
        self._state = 'IDLE'
        self._payload_len = 0
        self._frames = []

    def feed(self, data: bytes):
        for byte in data:
            b = byte if isinstance(byte, int) else ord(byte)
            if self._state == 'IDLE':
                if b == 0xFE:
                    self._buf = bytearray([b])
                    self._state = 'HDR'
                    self._remaining = 5  # 5 more header bytes
            elif self._state == 'HDR':
                self._buf.append(b)
                self._remaining -= 1
                if self._remaining == 0:
                    self._payload_len = self._buf[1]
                    self._remaining   = self._payload_len + 2  # payload + 2 CRC
                    self._state = 'BODY' if self._remaining > 0 else 'DONE'
            elif self._state == 'BODY':
                self._buf.append(b)
                self._remaining -= 1
                if self._remaining == 0:
                    self._frames.append(bytes(self._buf))
                    self._state = 'IDLE'

    def pop_frame(self):
        return self._frames.pop(0) if self._frames else None

# ---------------------------------------------------------------------------
# Audio playback thread
# ---------------------------------------------------------------------------
class AudioPlayer(threading.Thread):
    def __init__(self, device=None):
        super().__init__(daemon=True)
        self._q      = queue.Queue(maxsize=4)
        self._device = device
        self._stop   = threading.Event()

    def enqueue(self, samples: np.ndarray, block=True):
        """Enqueue audio samples.  Blocks if the queue is full."""
        self._q.put(samples, block=block)

    def stop(self): self._stop.set()

    def run(self):
        try:
            import sounddevice as sd
        except ImportError:
            print('[AUDIO] sounddevice not installed — audio output disabled')
            print('[AUDIO] Install with: pip install sounddevice')
            while not self._stop.is_set():
                try:
                    self._q.get(timeout=0.5)
                except queue.Empty:
                    pass
            return

        stream = sd.OutputStream(
            samplerate=SAMPLE_RATE,
            channels=1,
            dtype='float32',
            device=self._device,
            blocksize=512,
        )
        stream.start()
        while not self._stop.is_set():
            try:
                samples = self._q.get(timeout=0.5)
                stream.write(samples)
            except queue.Empty:
                pass
        stream.stop()
        stream.close()

# ---------------------------------------------------------------------------
# Main transmit loop
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description='AFSK Bell 202 stream encoder / player')
    ap.add_argument('--port',    default=None,  help='Serial port (e.g. /dev/ttyUSB0)')
    ap.add_argument('--baud',    type=int, default=57600)
    ap.add_argument('--stdin',   action='store_true', help='Read MAVLink bytes from stdin')
    ap.add_argument('--device',  type=int, default=None, help='sounddevice output device index')
    ap.add_argument('--list-devices', action='store_true')
    ap.add_argument('--amplitude', type=float, default=0.6,
                    help='Audio amplitude 0.0–1.0 (default 0.6, leaves headroom for radio pre-emphasis)')
    args = ap.parse_args()

    if args.list_devices:
        try:
            import sounddevice as sd
            print(sd.query_devices())
        except ImportError:
            print('sounddevice not installed')
        return

    player  = AudioPlayer(device=args.device)
    framer  = MavlinkFramer()
    player.start()

    seq = 0
    last_hb = time.time()

    def transmit_frame(data: bytes, ptype=PKT_TYPE_MAVLINK):
        nonlocal seq
        if len(data) > MAX_PAYLOAD_LEN:
            print(f'[TX] Frame too large ({len(data)} B), skipping')
            return
        wire   = build_packet_wire(ptype, seq & 0xFF, data)
        audio  = modulate(wire, amplitude=args.amplitude)
        player.enqueue(audio)
        dur_ms = len(audio) * 1000 / SAMPLE_RATE
        print(f'[TX] seq={seq:3d} type=0x{ptype:02X} len={len(data):4d} B  {dur_ms:.0f} ms')
        seq += 1
        nonlocal last_hb
        last_hb = time.time()

    if args.port:
        import serial
        ser = serial.Serial(args.port, args.baud, timeout=0.05)
        print(f'[TX] Listening on {args.port} @ {args.baud} baud')
        try:
            while True:
                data = ser.read(256)
                if data:
                    framer.feed(data)
                    frame = framer.pop_frame()
                    while frame:
                        transmit_frame(frame)
                        frame = framer.pop_frame()

                if time.time() - last_hb > HEARTBEAT_INTERVAL_S:
                    transmit_frame(b'', PKT_TYPE_HEARTBEAT)
        except KeyboardInterrupt:
            print('\n[TX] Stopped')
        finally:
            ser.close()

    elif args.stdin:
        print('[TX] Reading MAVLink from stdin (pipe or redirect)')
        try:
            while True:
                data = sys.stdin.buffer.read(1)
                if not data:
                    break
                framer.feed(data)
                frame = framer.pop_frame()
                while frame:
                    transmit_frame(frame)
                    frame = framer.pop_frame()
        except KeyboardInterrupt:
            print('\n[TX] Stopped')

    else:
        # Demo mode: send test heartbeats
        print('[TX] No source specified — sending demo heartbeats (Ctrl+C to stop)')
        try:
            while True:
                transmit_frame(b'', PKT_TYPE_HEARTBEAT)
                time.sleep(2.0)
        except KeyboardInterrupt:
            print('\n[TX] Stopped')

    player.stop()


if __name__ == '__main__':
    main()
