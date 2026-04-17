// FILE: firmware/receiver/src/mavlink_output.cpp
#include "mavlink_output.h"
#include "afsk_demodulator.h"
#include "modem_config.h"
#include <Arduino.h>

void MavlinkOutput::begin(HardwareSerial *uart_serial) {
    uart_ = uart_serial;
    last_stats_ms_ = millis();
}

void MavlinkOutput::update(PacketDecoder &decoder) {
    uint8_t byte;
    while (decoder.mavlink_out.pop(byte)) {
        // Forward to USB serial (always)
        Serial.write(byte);

        // Forward to hardware UART if connected (e.g. Mission Planner via RS-232)
        if (uart_) uart_->write(byte);
    }

    // Print stats once per second (suppressed when TELEM_QUIET is set so the
    // USB stream is pure MAVLink — cleaner for the Mac app on marginal links).
#if !TELEM_QUIET
    uint32_t now = millis();
    if (now - last_stats_ms_ >= 1000u) {
        last_stats_ms_ = now;
        print_stats(decoder, demodulator);
    }
#else
    (void)decoder;
#endif
}

void MavlinkOutput::print_stats(const PacketDecoder &decoder,
                                 const AFSKDemodulator &dem) {
#if !TELEM_QUIET
    const ReceiverStats &s = decoder.stats();
    Serial.printf(
        "[RX] ok=%lu crc_fail=%lu overflow=%lu seq_err=%lu "
        "bytes=%lu rssi=%u bits=%lu\n",
        (unsigned long)s.packets_ok,
        (unsigned long)s.packets_crc_fail,
        (unsigned long)s.packets_overflow,
        (unsigned long)s.seq_errors,
        (unsigned long)s.bytes_output,
        (unsigned)s.rssi_last,
        (unsigned long)dem.bit_count);
#else
    (void)decoder; (void)dem;
#endif
}
