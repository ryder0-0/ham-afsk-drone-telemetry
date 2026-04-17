// FILE: firmware/receiver/src/packet_decoder.cpp
#include "packet_decoder.h"
#include "afsk_demodulator.h"
#include <string.h>
#include <stdio.h>

PacketDecoder pkt_decoder;

void PacketDecoder::begin() {
    state_.reset();
    memset(&stats_, 0, sizeof(stats_));
    mavlink_out.clear();
}

bool PacketDecoder::update(RingBuffer<uint8_t, 512> &in_bytes) {
    bool got_packet = false;
    uint8_t byte;

    while (in_bytes.pop(byte)) {
        DecodeResult r = packet_decode_byte(state_, byte);

        switch (r) {
        case DecodeResult::PACKET_OK:
            stats_.packets_ok++;
            // Sequence number gap detection
            if (stats_.packets_ok > 1) {
                uint8_t expected = (uint8_t)(stats_.last_seq + 1u);
                if (state_.pkt.seq != expected)
                    stats_.seq_errors++;
            }
            stats_.last_seq = state_.pkt.seq;
            stats_.rssi_last = demodulator.rssi_est;
            handle_packet(state_.pkt);
            got_packet = true;
            break;

        case DecodeResult::CRC_FAIL:
            stats_.packets_crc_fail++;
            // state_ is auto-reset inside packet_decode_byte on CRC_FAIL
            break;

        case DecodeResult::OVERFLOW:
            stats_.packets_overflow++;
            break;

        case DecodeResult::NEED_MORE:
            break;
        }
    }
    return got_packet;
}

void PacketDecoder::handle_packet(const Packet &pkt) {
    switch (pkt.type) {

    case PKT_TYPE_MAVLINK:
        emit_mavlink(pkt.payload, pkt.length);
        break;

    case PKT_TYPE_TELEM:
        // Telemetry summary — emit a synthetic MAVLink-style binary blob.
        // In a real GCS integration you would synthesise proper MAVLink frames.
        // Here we emit the raw TelemetrySummary struct prefixed with a marker
        // so the host PC tools/python_decoder can identify it.
        if (pkt.length == sizeof(TelemetrySummary)) {
            const TelemetrySummary *t =
                reinterpret_cast<const TelemetrySummary *>(pkt.payload);
            // Print to debug; a real implementation would build MAVLink frames
            (void)t;  // suppress unused warning
            emit_mavlink(pkt.payload, pkt.length);
        }
        break;

    case PKT_TYPE_HEARTBEAT:
        // No payload — just a keepalive; already counted in stats
        break;

    default:
        break;
    }
}

void PacketDecoder::emit_mavlink(const uint8_t *data, uint16_t len) {
    for (uint16_t i = 0; i < len; ++i) {
        if (!mavlink_out.push(data[i])) break;  // drop on overflow
    }
    stats_.bytes_output += len;
}
