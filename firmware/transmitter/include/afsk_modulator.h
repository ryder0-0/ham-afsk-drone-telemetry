// FILE: firmware/transmitter/include/afsk_modulator.h
//
// AFSK Bell 202 modulator.
//
// Architecture:
//   prepare_packet() fills an internal audio sample buffer (NRZI-encoded).
//   start_tx()       asserts PTT, waits settle time, then starts ISR.
//   The hardware timer ISR drains the sample buffer to the DAC at ~9600 Hz.
//   When the buffer empties the ISR clears itself and PTT is released.
//
// The sine lookup table uses a 16-bit phase accumulator:
//   Mark  increment = 65536 * 1200 / 9600 = 8192   (zero error)
//   Space increment = 65536 * 2200 / 9600 = 15019  (< 0.005% error)

#pragma once
#include <Arduino.h>
#include "modem_config.h"
#include "packet.h"

// Maximum audio samples in one transmission.
// Worst case: 25-byte preamble + 8 overhead + 260 payload = 293 bytes
//             × 8 bits × 8 samples/bit = 18752 samples + 200 extra
#define AUDIO_BUF_SAMPLES   20000u

class AFSKModulator {
public:
    void begin();

    // Encode `pkt` into audio and prepare for transmission.
    // Returns false if a previous transmission is still active.
    bool prepare_packet(const Packet &pkt);

    // Actually transmit: PTT on → settle → audio ISR → PTT off.
    // Blocks until complete.
    void transmit();

    // True while the ISR is draining audio samples.
    bool is_active() const { return active_; }

    // Called from ISR context — do NOT call from application code.
    void isr_tick();

private:
    hw_timer_t *timer_    = nullptr;
    volatile bool active_ = false;

    uint8_t  audio_buf_[AUDIO_BUF_SAMPLES];
    volatile uint32_t audio_head_ = 0;   // write position (set before ISR starts)
    volatile uint32_t audio_tail_ = 0;   // read position  (advanced by ISR)

    void build_audio(const uint8_t *wire_bytes, size_t wire_len);
    uint8_t sine_sample(uint16_t phase) const;

    // 256-entry sine LUT, values 0–255 (centre 128)
    static uint8_t sine_table_[256];
    static bool    sine_table_ready_;
    static void    init_sine_table();
};

extern AFSKModulator modulator;
