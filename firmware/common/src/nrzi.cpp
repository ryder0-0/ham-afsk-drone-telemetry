// FILE: firmware/common/src/nrzi.cpp
#include "nrzi.h"

void nrzi_encode(const uint8_t *bits, uint8_t *tones, int count) {
    uint8_t current = 1;  // initial tone = MARK
    for (int i = 0; i < count; ++i) {
        if (bits[i] == 0)
            current ^= 1u;  // bit 0 → transition
        tones[i] = current;
    }
}

void nrzi_decode(const uint8_t *tones, uint8_t *bits, int count) {
    uint8_t prev = 1;  // initial assumed tone = MARK
    for (int i = 0; i < count; ++i) {
        bits[i] = (tones[i] == prev) ? 1u : 0u;
        prev = tones[i];
    }
}
