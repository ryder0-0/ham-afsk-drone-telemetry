// FILE: firmware/receiver/src/afsk_demodulator.cpp
//
// Quadrature AFSK demodulator.  See header for algorithm description.
//
// Bit-clock PLL details:
//   bit_phase_ counts 0..(SAMPLES_PER_BIT-1).
//   On a tone transition we reset bit_phase_ to 0 (we are at a bit edge).
//   We sample the tone decision at bit_phase_ == SAMPLES_PER_BIT/2 (== 4),
//   i.e. the centre of the bit period.
//   Between transitions the clock free-runs; oscillator accuracy is
//   ~0.16 % (timer error), giving < 0.003 samples drift per bit — negligible
//   over a 300-byte packet.

#include "afsk_demodulator.h"
#include "modem_config.h"
#include <math.h>
#include <string.h>

AFSKDemodulator demodulator;

void AFSKDemodulator::begin() {
    for (int i = 0; i < 256; ++i) {
        float theta = 2.0f * (float)M_PI * i / 256.0f;
        cos_lut_[i] = cosf(theta);
        sin_lut_[i] = sinf(theta);
    }
    current_tone_ = -1;
    prev_tone_    = -1;
    bit_phase_    = 0;
    bit_in_byte_  = 0;
    byte_accum_   = 0;
    out_bytes.clear();
}

// ---------------------------------------------------------------------------
// Core per-sample processing — called from ADC timer ISR at ~9615 Hz
// ---------------------------------------------------------------------------
void IRAM_ATTR AFSKDemodulator::process_sample(uint16_t raw_adc) {

    // Centre the 12-bit ADC value around zero (ESP32 ADC mid-scale ≈ 2048)
    float sample = (float)(int16_t)(raw_adc - 2048u);

    // Advance reference oscillator phases
    mark_phase_  += MARK_PHASE_INC;
    space_phase_ += SPACE_PHASE_INC;

    // Quadrature mixing with precomputed LUT
    uint8_t mi = mark_phase_  >> 8;
    uint8_t si = space_phase_ >> 8;

    float m_cos = cos_lut_[mi];
    float m_sin = sin_lut_[mi];
    float s_cos = cos_lut_[si];
    float s_sin = sin_lut_[si];

    // First IIR stage on mixed products (fc ≈ 441 Hz at 9600 Hz fs)
    mark_i_  = IIR_ALPHA * (sample * m_cos) + IIR_ONE_MINUS_ALPHA * mark_i_;
    mark_q_  = IIR_ALPHA * (sample * m_sin) + IIR_ONE_MINUS_ALPHA * mark_q_;
    space_i_ = IIR_ALPHA * (sample * s_cos) + IIR_ONE_MINUS_ALPHA * space_i_;
    space_q_ = IIR_ALPHA * (sample * s_sin) + IIR_ONE_MINUS_ALPHA * space_q_;

    // Power estimate (L2 squared magnitude)
    float mp = mark_i_  * mark_i_  + mark_q_  * mark_q_;
    float sp = space_i_ * space_i_ + space_q_ * space_q_;

    // Second IIR stage to smooth power (reduces bit-rate ripple on power)
    mark_pwr_  = IIR_ALPHA * mp + IIR_ONE_MINUS_ALPHA * mark_pwr_;
    space_pwr_ = IIR_ALPHA * sp + IIR_ONE_MINUS_ALPHA * space_pwr_;

    // Tone decision with hysteresis
    int new_tone;
    if (mark_pwr_ > space_pwr_ * TONE_HYSTERESIS) {
        new_tone = 1;   // MARK
    } else if (space_pwr_ > mark_pwr_ * TONE_HYSTERESIS) {
        new_tone = 0;   // SPACE
    } else {
        new_tone = current_tone_;   // ambiguous — hold last decision
    }

    // RSSI estimate: 50 = no signal, 100 = perfect mark, 0 = perfect space
    float total = mark_pwr_ + space_pwr_;
    if (total > 1e-6f) {
        rssi_est = (uint8_t)(mark_pwr_ / total * 100.0f);
        // Map to a 0–100 "signal quality" score centred on 50 for tone balance
        // Re-interpret: score = |rssi_est - 50| * 2 = sharpness of decision
        // Keep raw ratio for now; application can reinterpret.
    }

    // Detect tone transition (bit edge)
    bool transition = (new_tone != current_tone_) && (current_tone_ != -1);
    current_tone_ = new_tone;

    if (transition) {
        transition_count++;
        // Reset bit clock: we are at a bit edge, next sample point is at 4
        bit_phase_ = 0;
    }

    // Bit clock: sample at centre of bit (phase == SAMPLES_PER_BIT/2)
    bit_phase_++;
    if (bit_phase_ == SAMPLES_PER_BIT / 2) {
        // NRZI decode: same as previous sampled tone → bit 1, different → bit 0
        int bit;
        if (prev_tone_ == -1) {
            bit = 1;   // first bit — assume no transition
        } else {
            bit = (current_tone_ == prev_tone_) ? 1 : 0;
        }
        prev_tone_ = current_tone_;
        emit_bit(bit);
        bit_count++;
    }
    if (bit_phase_ >= SAMPLES_PER_BIT) {
        bit_phase_ = 0;
    }
}

// ---------------------------------------------------------------------------
// Bit → byte assembler (LSB-first)
// ---------------------------------------------------------------------------
void IRAM_ATTR AFSKDemodulator::emit_bit(int bit) {
    byte_accum_ |= (uint8_t)(bit & 1u) << bit_in_byte_;
    bit_in_byte_++;
    if (bit_in_byte_ == 8u) {
        out_bytes.push_isr(byte_accum_);
        byte_accum_   = 0;
        bit_in_byte_  = 0;
    }
}
