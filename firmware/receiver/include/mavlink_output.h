// FILE: firmware/receiver/include/mavlink_output.h
//
// Drains the PacketDecoder's mavlink_out ring buffer to UART2
// (for a GCS connected via 3.3 V serial) and to USB Serial
// (for Mission Planner / QGC connected via USB).

#pragma once
#include <Arduino.h>
#include "packet_decoder.h"

class MavlinkOutput {
public:
    // uart_serial: HardwareSerial instance for UART GCS port (optional, pass nullptr to skip)
    void begin(HardwareSerial *uart_serial);

    // Drain mavlink_out buffer.  Call frequently from main loop.
    void update(PacketDecoder &decoder);

    // Print a one-line stats summary to USB serial
    void print_stats(const PacketDecoder &decoder, const AFSKDemodulator &dem);

private:
    HardwareSerial *uart_ = nullptr;
    uint32_t last_stats_ms_ = 0;
};
