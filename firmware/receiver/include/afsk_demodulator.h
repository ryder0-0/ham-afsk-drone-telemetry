// FILE: firmware/receiver/include/afsk_demodulator.h
//
// Bell 202 AFSK demodulator using quadrature (I/Q) correlation + IIR LPF.
//
// Algorithm per sample:
//  1. Advance 16-bit phase accumulators for MARK and SPACE reference tones.
//  2. Mix incoming sample with cos/sin of each reference (4 multiplies).
//  3. Apply single-pole IIR LPF to each I/Q channel (alpha = 0.25).
//  4. Compute L2 power for MARK and SPACE: P = I² + Q².
//  5. Apply second IIR stage to smooth power estimates.
//  6. Tone decision with 8% hysteresis to suppress false transitions.
//  7. Bit-clock PLL: reset phase on tone transition → sample at bit centre.
//  8. NRZI decode at sample point: same tone = 1, transition = 0.
//  9. Feed decoded bits into packet assembler byte by byte.
//
// RSSI estimate = mark_power / (mark_power + space_power) × 100
// A value near 50 means no signal; strong signal pushes it towards 100 or 0.

#pragma once
#include <stdint.h>
#include "ring_buffer.h"
#include "packet.h"

// Output ring buffer — decoded bytes destined for packet_decoder
// Must hold at least one worst-case packet (PREAMBLE + overhead + MAX_PAYLOAD)
#define DEMOD_OUT_BUF  512u

class AFSKDemodulator {
public:
    void begin();

    // Feed one raw ADC sample (0–4095, 12-bit).  Call at ~9600 Hz.
    // MUST be called from ISR context or a dedicated high-priority task.
    void IRAM_ATTR process_sample(uint16_t raw_adc);

    // Demodulated byte stream (consumed by PacketDecoder in main loop)
    RingBuffer<uint8_t, DEMOD_OUT_BUF> out_bytes;

    // Statistics — read from main loop, written by process_sample
    volatile uint32_t bit_count       = 0;
    volatile uint32_t transition_count = 0;
    volatile uint8_t  rssi_est        = 50;  // 0–100

private:
    // Trig LUT — precomputed at begin()
    float cos_lut_[256];
    float sin_lut_[256];

    // Phase accumulators (16-bit, index into 256-entry LUT via >> 8)
    uint16_t mark_phase_  = 0;
    uint16_t space_phase_ = 0;

    // IIR state (quadrature channels)
    float mark_i_  = 0.0f, mark_q_  = 0.0f;
    float space_i_ = 0.0f, space_q_ = 0.0f;

    // Smoothed power
    float mark_pwr_  = 0.0f;
    float space_pwr_ = 0.0f;

    // Tone state
    int  current_tone_ = -1;   // -1=unknown, 0=SPACE, 1=MARK
    int  prev_tone_    = -1;

    // Bit clock PLL
    int bit_phase_ = 0;         // counts 0–(SAMPLES_PER_BIT-1)

    // Byte assembler
    uint8_t  byte_accum_   = 0;
    uint8_t  bit_in_byte_  = 0;

    void emit_bit(int bit);
};

extern AFSKDemodulator demodulator;
