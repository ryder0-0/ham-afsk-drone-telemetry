// FILE: firmware/common/src/packet.cpp
#include "packet.h"
#include "crc16.h"
#include <string.h>

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------
size_t packet_encode(const Packet &pkt, uint8_t *out, size_t out_size) {
    size_t wire = packet_wire_size(pkt.length);
    if (wire > out_size) return 0;

    size_t pos = 0;

    // Preamble
    for (uint8_t i = 0; i < PREAMBLE_LEN; ++i)
        out[pos++] = PREAMBLE_BYTE;

    // Sync word — CRC window starts here
    size_t crc_start = pos;
    out[pos++] = SYNC_BYTE_0;
    out[pos++] = SYNC_BYTE_1;
    out[pos++] = pkt.type;
    out[pos++] = pkt.seq;
    out[pos++] = (uint8_t)(pkt.length & 0xFFu);
    out[pos++] = (uint8_t)(pkt.length >> 8u);

    memcpy(out + pos, pkt.payload, pkt.length);
    pos += pkt.length;

    uint16_t crc = crc16_ccitt(out + crc_start, pos - crc_start);
    out[pos++] = (uint8_t)(crc & 0xFFu);
    out[pos++] = (uint8_t)(crc >> 8u);

    return pos;
}

// ---------------------------------------------------------------------------
// Incremental decode
// ---------------------------------------------------------------------------
void PacketDecodeState::reset() {
    phase       = Phase::PREAMBLE;
    sync_match  = 0;
    bytes_read  = 0;
    crc_accum   = 0xFFFFu;
    memset(&pkt, 0, sizeof(pkt));
}

DecodeResult packet_decode_byte(PacketDecodeState &s, uint8_t byte) {
    using P = PacketDecodeState::Phase;

    switch (s.phase) {

    case P::PREAMBLE:
        // Absorb preamble bytes; transition on first sync byte.
        if (byte == SYNC_BYTE_0) {
            s.crc_accum = crc16_ccitt_update(0xFFFFu, byte);
            s.phase = P::SYNC1;
        }
        return DecodeResult::NEED_MORE;

    case P::SYNC1:
        if (byte == SYNC_BYTE_1) {
            s.crc_accum = crc16_ccitt_update(s.crc_accum, byte);
            s.phase = P::TYPE;
        } else {
            // False sync_0 match; check if this is a new sync_0
            if (byte == SYNC_BYTE_0)
                s.crc_accum = crc16_ccitt_update(0xFFFFu, byte);
            else
                s.phase = P::PREAMBLE;
        }
        return DecodeResult::NEED_MORE;

    case P::TYPE:
        s.pkt.type  = byte;
        s.crc_accum = crc16_ccitt_update(s.crc_accum, byte);
        s.phase = P::SEQ;
        return DecodeResult::NEED_MORE;

    case P::SEQ:
        s.pkt.seq   = byte;
        s.crc_accum = crc16_ccitt_update(s.crc_accum, byte);
        s.phase = P::LEN_LO;
        return DecodeResult::NEED_MORE;

    case P::LEN_LO:
        s.pkt.length = byte;
        s.crc_accum  = crc16_ccitt_update(s.crc_accum, byte);
        s.phase = P::LEN_HI;
        return DecodeResult::NEED_MORE;

    case P::LEN_HI:
        s.pkt.length |= (uint16_t)byte << 8u;
        s.crc_accum   = crc16_ccitt_update(s.crc_accum, byte);
        if (s.pkt.length > MAX_PAYLOAD_LEN) {
            s.reset();
            return DecodeResult::OVERFLOW;
        }
        s.bytes_read = 0;
        s.phase = (s.pkt.length > 0) ? P::PAYLOAD : P::CRC_LO;
        return DecodeResult::NEED_MORE;

    case P::PAYLOAD:
        s.pkt.payload[s.bytes_read++] = byte;
        s.crc_accum = crc16_ccitt_update(s.crc_accum, byte);
        if (s.bytes_read == s.pkt.length)
            s.phase = P::CRC_LO;
        return DecodeResult::NEED_MORE;

    case P::CRC_LO:
        s.pkt.crc = byte;
        s.phase = P::CRC_HI;
        return DecodeResult::NEED_MORE;

    case P::CRC_HI: {
        s.pkt.crc |= (uint16_t)byte << 8u;
        DecodeResult result;
        if (s.pkt.crc == s.crc_accum)
            result = DecodeResult::PACKET_OK;
        else
            result = DecodeResult::CRC_FAIL;
        s.reset();
        return result;
    }
    }
    return DecodeResult::NEED_MORE;
}
