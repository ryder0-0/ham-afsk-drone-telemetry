# Packet Format Specification

## Wire Format

All integers are little-endian.  Bits are transmitted LSB-first.  NRZI encoding is applied to the entire bit stream before modulation.

```
┌─────────────────────────────────────────────────────────────────┐
│ PREAMBLE × 25 bytes (0xAA each)  ← 167 ms at 1200 baud         │
├────────────┬─────────────────────────────────────────────────────┤
│ SYNC_0     │ 0x2D                                                │
│ SYNC_1     │ 0xD4              ← CRC window starts here         │
│ TYPE       │ 1 byte                                              │
│ SEQ        │ 1 byte                                              │
│ LEN_LO     │ payload length, low byte                           │
│ LEN_HI     │ payload length, high byte                          │
│ PAYLOAD    │ 0–260 bytes                                         │
│ CRC_LO     │ CRC16-CCITT low byte                               │
│ CRC_HI     │ CRC16-CCITT high byte  ← CRC window ends here      │
└────────────┴─────────────────────────────────────────────────────┘
```

**Overhead:** 8 bytes (sync + type + seq + len + crc) + 25 byte preamble = 33 bytes/packet.

---

## Field Descriptions

| Field     | Size | Description |
|-----------|------|-------------|
| PREAMBLE  | 25 B | Repeating `0xAA`.  After NRZI encoding this produces a regular alternating mark/space pattern that opens the radio squelch and synchronises the receiver bit clock.  25 bytes ≈ 167 ms is enough for virtually any amateur HT. |
| SYNC      | 2 B  | `0x2D 0xD4` — fixed sync word to unambiguously mark the start of a decodable frame. |
| TYPE      | 1 B  | Packet type (see table below). |
| SEQ       | 1 B  | Transmitter sequence number, wraps 0–255.  Receiver uses this to detect dropped packets. |
| LEN       | 2 B  | Payload byte count (little-endian `uint16`), 0–260. |
| PAYLOAD   | 0–260 B | Type-specific data (see below). |
| CRC       | 2 B  | CRC16-CCITT (poly `0x1021`, init `0xFFFF`, no final XOR) over bytes from SYNC_0 through end of payload. |

---

## Packet Types

| Value | Name               | Payload |
|-------|--------------------|---------|
| 0x00  | `PKT_TYPE_MAVLINK` | Raw MAVLink v1/v2 frame bytes (tunnel mode). |
| 0x01  | `PKT_TYPE_TELEM`   | 22-byte `TelemetrySummary` struct (see below). |
| 0xFF  | `PKT_TYPE_HEARTBEAT` | Empty (len = 0).  Modem keepalive. |

---

## Telemetry Summary Struct (22 bytes)

```c
struct __attribute__((packed)) TelemetrySummary {
    int32_t  lat_e7;       //  4: latitude  × 1e7
    int32_t  lon_e7;       //  4: longitude × 1e7
    int32_t  alt_mm;       //  4: altitude MSL mm
    int16_t  heading_cd;   //  2: heading × 100 (centi-degrees)
    int16_t  speed_cms;    //  2: ground speed cm/s
    int16_t  batt_mv;      //  2: battery mV
    uint8_t  batt_pct;     //  1: battery %
    uint8_t  gps_sats;     //  1: satellites
    uint8_t  flight_mode;  //  1: ArduPilot custom mode
    uint8_t  armed;        //  1: 1 = armed
    int16_t  rssi_est;     //  2: modem RSSI 0–100
};                          // = 22 bytes total
```

---

## NRZI Encoding

The entire bit stream (preamble through CRC) is NRZI-encoded before AFSK modulation:

- Bit `0` → **tone transition** (mark↔space)
- Bit `1` → **no transition** (tone unchanged)
- Initial tone before bit 0 of preamble: **MARK**

`0xAA` = `1010 1010` in LSB-first order sends bits `0,1,0,1,0,1,0,1`, which after NRZI produces a regular alternating tone pattern — ideal for squelch opening and bit-clock acquisition.

---

## CRC

CRC16-CCITT, polynomial `0x1021`, initial value `0xFFFF`:

```python
def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = (crc << 1) ^ 0x1021 if (crc & 0x8000) else (crc << 1)
            crc &= 0xFFFF
    return crc
```

---

## Timing Budget (1200 baud)

| Component            | Bytes | Bits | Time (ms) |
|----------------------|-------|------|-----------|
| Preamble             | 25    | 200  | 167       |
| Header (sync–len)    | 6     | 48   | 40        |
| Payload (MAVLink HB) | 17    | 136  | 113       |
| CRC                  | 2     | 16   | 13        |
| **Total**            | **50**| **400** | **333** |
| + PTT settle         |       |      | 80        |
| + PTT tail           |       |      | 60        |
| **Channel time**     |       |      | **~473 ms** |

At 1 Hz telemetry rate the channel is occupied for ~47% of the time, leaving adequate margin for other users.

---

## Worst-Case Packet (260-byte payload)

| Component  | Bytes | Time (ms) |
|------------|-------|-----------|
| Preamble   | 25    | 167       |
| Header     | 6     | 40        |
| Payload    | 260   | 1733      |
| CRC        | 2     | 13        |
| **Total**  | **293** | **1953 ms ≈ 2 s** |
