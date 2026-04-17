// FILE: firmware/transmitter/include/ptt_control.h
#pragma once
#include <stdint.h>

// PTT is driven active-high.  An NPN transistor inverts this so the radio
// PTT pin is pulled to ground (most radios: PTT = GND to transmit).
// See hardware/ptt_interface.md for the full circuit.

void ptt_init();

// Assert PTT and wait PTT_SETTLE_MS for the PA to stabilise before audio.
void ptt_on();

// Release PTT after PTT_TAIL_MS so squelch tail does not clip packet end.
void ptt_off();

bool ptt_is_active();
