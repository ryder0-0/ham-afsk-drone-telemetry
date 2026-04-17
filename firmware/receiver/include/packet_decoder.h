// FILE: firmware/receiver/include/packet_decoder.h
#pragma once
#include <stdint.h>
#include "packet.h"
#include "ring_buffer.h"

struct ReceiverStats {
    uint32_t packets_ok;
    uint32_t packets_crc_fail;
    uint32_t packets_overflow;
    uint32_t bytes_output;
    uint32_t seq_errors;      // gaps in sequence numbers
    uint8_t  last_seq;
    uint8_t  rssi_last;       // last RSSI estimate from demodulator
};

class PacketDecoder {
public:
    void begin();

    // Feed bytes from the demodulator ring buffer.
    // Returns true when a complete valid packet was decoded this call.
    bool update(RingBuffer<uint8_t, 512> &in_bytes);

    // Valid after update() returns true.
    const Packet &last_packet() const { return state_.pkt; }

    const ReceiverStats &stats() const { return stats_; }

    // Emitted MAVLink bytes ready for output UART / USB
    RingBuffer<uint8_t, 1024> mavlink_out;

private:
    PacketDecodeState state_;
    ReceiverStats     stats_ = {};

    void handle_packet(const Packet &pkt);
    void emit_mavlink(const uint8_t *data, uint16_t len);
};

extern PacketDecoder pkt_decoder;
