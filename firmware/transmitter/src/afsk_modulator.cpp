// FILE: firmware/transmitter/src/afsk_modulator.cpp
//
// Bell 202 AFSK modulator using a 16-bit phase accumulator and a 256-entry
// sine LUT.  Audio is pre-rendered into audio_buf_[] then played back by a
// hardware timer ISR that calls dacWrite() at ~9615 Hz.
//
// Phase increments (16-bit accumulator, 256-entry table):
//   Mark  (1200 Hz): inc = 65536 * 1200 / 9600 = 8192   (exact)
//   Space (2200 Hz): inc = 65536 * 2200 / 9600 = 15019  (< 0.005% error)

#include "afsk_modulator.h"
#include "ptt_control.h"
#include "nrzi.h"
#include "modem_config.h"
#include <Arduino.h>
#include <math.h>
#include <string.h>

AFSKModulator modulator;

uint8_t AFSKModulator::sine_table_[256];
bool    AFSKModulator::sine_table_ready_ = false;

// ---------------------------------------------------------------------------
// ISR
// ---------------------------------------------------------------------------
static void IRAM_ATTR audio_isr() { modulator.isr_tick(); }

void IRAM_ATTR AFSKModulator::isr_tick() {
    if (audio_tail_ < audio_head_) {
        dacWrite(GPIO_DAC_OUT, audio_buf_[audio_tail_++]);
    } else {
        dacWrite(GPIO_DAC_OUT, 128);   // silence / mid-scale
        active_ = false;
        timerAlarmDisable(timer_);
    }
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------
void AFSKModulator::init_sine_table() {
    for (int i = 0; i < 256; ++i)
        sine_table_[i] = (uint8_t)(128 + 127.0 * sin(2.0 * M_PI * i / 256.0));
    sine_table_ready_ = true;
}

void AFSKModulator::begin() {
    if (!sine_table_ready_) init_sine_table();

    pinMode(GPIO_DAC_OUT, ANALOG);
    dacWrite(GPIO_DAC_OUT, 128);

    // Timer 0, prescaler 80 → 1 MHz tick
    timer_ = timerBegin(0, TIMER_PRESCALER, true);
    timerAttachInterrupt(timer_, audio_isr, true);
    timerAlarmWrite(timer_, TIMER_ALARM_TICKS, true);
    // Do NOT enable alarm yet; enable in transmit()
}

// ---------------------------------------------------------------------------
// Audio buffer builder
// ---------------------------------------------------------------------------
inline uint8_t AFSKModulator::sine_sample(uint16_t phase) const {
    return sine_table_[phase >> 8];
}

void AFSKModulator::build_audio(const uint8_t *wire_bytes, size_t wire_len) {
    // Expand bytes → bits (LSB first)
    uint32_t total_bits = wire_len * 8u;
    if (total_bits * SAMPLES_PER_BIT > AUDIO_BUF_SAMPLES) {
        // Truncate — should never happen with current constants
        total_bits = AUDIO_BUF_SAMPLES / SAMPLES_PER_BIT;
    }

    // NRZI-encode the bit stream
    uint8_t bits[AUDIO_BUF_SAMPLES / SAMPLES_PER_BIT];
    uint8_t tones[AUDIO_BUF_SAMPLES / SAMPLES_PER_BIT];

    for (uint32_t i = 0; i < total_bits; ++i)
        bits[i] = (wire_bytes[i / 8u] >> (i % 8u)) & 1u;

    nrzi_encode(bits, tones, (int)total_bits);

    // Render audio samples
    uint16_t phase = 0;
    uint32_t sample_idx = 0;

    for (uint32_t i = 0; i < total_bits; ++i) {
        uint16_t inc = (tones[i] == 1u) ? MARK_PHASE_INC : SPACE_PHASE_INC;
        for (uint8_t s = 0; s < SAMPLES_PER_BIT; ++s) {
            audio_buf_[sample_idx++] = sine_sample(phase);
            phase += inc;
        }
    }

    audio_head_ = sample_idx;
    audio_tail_ = 0;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
bool AFSKModulator::prepare_packet(const Packet &pkt) {
    if (active_) return false;

    uint8_t wire_buf[sizeof(uint8_t) * (PREAMBLE_LEN + 8 + MAX_PAYLOAD_LEN)];
    size_t  wire_len = packet_encode(pkt, wire_buf, sizeof(wire_buf));
    if (wire_len == 0) return false;

    build_audio(wire_buf, wire_len);
    return true;
}

void AFSKModulator::transmit() {
    ptt_on();                         // assert PTT, wait PTT_SETTLE_MS

    active_ = true;
    timerAlarmEnable(timer_);

    // Block until ISR drains the buffer
    while (active_) { yield(); }

    ptt_off();                        // wait PTT_TAIL_MS, release PTT
}
