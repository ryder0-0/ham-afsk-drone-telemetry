// FILE: firmware/common/include/packet.h
#pragma once
#include <stdint.h>
#include <stddef.h>
#include "modem_config.h"

// Telemetry summary payload — 22 bytes, sent in PKT_TYPE_TELEM packets.
// All fields little-endian.
struct __attribute__((packed)) TelemetrySummary {
    int32_t  lat_e7;       // latitude  × 1e7 (degrees)
    int32_t  lon_e7;       // longitude × 1e7 (degrees)
    int32_t  alt_mm;       // altitude MSL in mm
    int16_t  heading_cd;   // heading × 100 (centi-degrees)
    int16_t  speed_cms;    // ground speed cm/s
    int16_t  batt_mv;      // battery voltage mV
    uint8_t  batt_pct;     // battery remaining %
    uint8_t  gps_sats;     // visible satellites
    uint8_t  flight_mode;  // ArduPilot custom mode byte
    uint8_t  armed;        // 1 = armed
    int16_t  rssi_est;     // modem RSSI estimate 0–100
};
static_assert(sizeof(TelemetrySummary) == 22, "TelemetrySummary size mismatch");

// Full packet (in-memory representation, not wire format).
struct Packet {
    uint8_t  type;
    uint8_t  seq;
    uint16_t length;                      // payload byte count
    uint8_t  payload[MAX_PAYLOAD_LEN];
    uint16_t crc;                         // computed by encode; verified by decode
};

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

// Serialise `pkt` into `out_buf`.  The buffer must be at least
// packet_wire_size(pkt.length) bytes.  Returns number of bytes written.
// Writes: preamble | sync | type | seq | len_lo | len_hi | payload | crc_lo | crc_hi
size_t packet_encode(const Packet &pkt, uint8_t *out_buf, size_t out_size);

// Return total wire bytes for a payload of `payload_len` bytes.
inline size_t packet_wire_size(uint16_t payload_len) {
    return PREAMBLE_LEN + 2u /*sync*/ + 1u /*type*/ + 1u /*seq*/
           + 2u /*len*/ + payload_len + 2u /*crc*/;
}

// ---------------------------------------------------------------------------
// Decoding (incremental — feed one byte at a time)
// ---------------------------------------------------------------------------
enum class DecodeResult {
    NEED_MORE,      // normal — still accumulating bytes
    PACKET_OK,      // complete + CRC passes; pkt is populated
    CRC_FAIL,       // complete but CRC failed; re-synchronise
    OVERFLOW,       // payload length exceeded MAX_PAYLOAD_LEN
};

struct PacketDecodeState {
    enum class Phase { PREAMBLE, SYNC1, TYPE, SEQ, LEN_LO, LEN_HI, PAYLOAD, CRC_LO, CRC_HI };
    Phase    phase        = Phase::PREAMBLE;
    uint8_t  sync_match   = 0;
    Packet   pkt;
    uint16_t bytes_read   = 0;
    uint16_t crc_accum    = 0xFFFF;

    void reset();
};

// Feed one decoded byte into the state machine.
// When result == PACKET_OK the caller should read state.pkt.
DecodeResult packet_decode_byte(PacketDecodeState &state, uint8_t byte);
