// FILE: firmware/common/include/nrzi.h
//
// NRZI (Non-Return-to-Zero Inverted) bit encoding / decoding.
//
// Convention (Bell 202 / AX.25 compatible):
//   Bit '0' → tone transition  (mark↔space)
//   Bit '1' → no transition    (tone unchanged)
//
// The initial tone before the first bit is always MARK (1).
// This means a '0' starting bit immediately transitions to SPACE.

#pragma once
#include <stdint.h>

// Encode `count` bits from `bits[]` into `tones[]`.
// tones[i] == 1 → MARK (1200 Hz), tones[i] == 0 → SPACE (2200 Hz).
void nrzi_encode(const uint8_t *bits, uint8_t *tones, int count);

// Decode `count` tone symbols from `tones[]` into `bits[]`.
void nrzi_decode(const uint8_t *tones, uint8_t *bits, int count);
