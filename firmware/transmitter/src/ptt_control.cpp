// FILE: firmware/transmitter/src/ptt_control.cpp
#include "ptt_control.h"
#include "modem_config.h"
#include <Arduino.h>

static bool ptt_active = false;

void ptt_init() {
    pinMode(GPIO_PTT, OUTPUT);
    digitalWrite(GPIO_PTT, LOW);
}

void ptt_on() {
    if (ptt_active) return;
    ptt_active = true;
    digitalWrite(GPIO_PTT, HIGH);
    // Wait for PA to stabilise.  Most HTs need 50–100 ms; 80 ms is safe.
    delay(PTT_SETTLE_MS);
}

void ptt_off() {
    if (!ptt_active) return;
    // Hold PTT briefly so the squelch tail does not cut the last packet byte.
    delay(PTT_TAIL_MS);
    digitalWrite(GPIO_PTT, LOW);
    ptt_active = false;
}

bool ptt_is_active() { return ptt_active; }
