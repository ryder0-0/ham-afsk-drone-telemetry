// FILE: firmware/receiver/src/main.cpp
//
// Ground-station receiver.
// Demodulates AFSK audio from radio speaker output, reconstructs packets,
// validates CRC, and forwards MAVLink to UART2 + USB serial.
//
// Hardware: ESP32 WROOM-32
//   GPIO34  ← ADC1 CH6 ← audio conditioning circuit ← radio speaker out
//   GPIO16  → UART2 TX → GCS (Mission Planner / QGC) at 57600 8N1
//   GPIO2   → LED       (blinks on packet receive)

#include <Arduino.h>
#include "modem_config.h"
#include "afsk_demodulator.h"
#include "packet_decoder.h"
#include "mavlink_output.h"
#include "driver/adc.h"

// UART2 → GCS
HardwareSerial gcsSerial(2);
MavlinkOutput  mavOut;

// ---------------------------------------------------------------------------
// ADC timer ISR
// ---------------------------------------------------------------------------
static hw_timer_t *adc_timer = nullptr;

static void IRAM_ATTR adc_isr() {
    // Direct ADC1 register read — safe in ISR, ~15 µs conversion time.
    // At 9615 Hz the ISR budget is 104 µs; this is well within budget.
    uint16_t raw = (uint16_t)adc1_get_raw(ADC1_CHANNEL_6);
    demodulator.process_sample(raw);
}

// ---------------------------------------------------------------------------
// Arduino entry points
// ---------------------------------------------------------------------------
void setup() {
    Serial.begin(USB_SERIAL_BAUD);
#if !TELEM_QUIET
    Serial.println("\n[HAM-AFSK] Receiver starting");
#endif

    // ADC configuration for GPIO34 (ADC1 channel 6)
    // Attenuation 11 dB → full-scale input range 0–3.9 V (effective 0–3.3 V)
    adc1_config_width(ADC_WIDTH_BIT_12);
    // ADC_ATTEN_DB_12 (was DB_11 before IDF 5) → full-scale input ~3.1 V
    adc1_config_channel_atten(ADC1_CHANNEL_6, ADC_ATTEN_DB_12);

    demodulator.begin();
    pkt_decoder.begin();

    gcsSerial.begin(MAVLINK_UART_BAUD, SERIAL_8N1, GPIO_MAVLINK_RX, GPIO_MAVLINK_TX);
    mavOut.begin(&gcsSerial);

    // Hardware timer for ADC sampling at ~9615 Hz
    // 80 MHz APB / prescaler 80 = 1 MHz tick / alarm 104 = 9615 Hz
    adc_timer = timerBegin(1, TIMER_PRESCALER, true);
    timerAttachInterrupt(adc_timer, adc_isr, true);
    timerAlarmWrite(adc_timer, TIMER_ALARM_TICKS, true);
    timerAlarmEnable(adc_timer);

    pinMode(GPIO_STATUS_LED, OUTPUT);

#if !TELEM_QUIET
    Serial.println("[RX] ADC timer started, waiting for signal...");
#endif
}

void loop() {
    // Drain demodulated bytes into packet decoder
    bool got_pkt = pkt_decoder.update(demodulator.out_bytes);

    if (got_pkt) {
        // Blink LED on each successfully decoded packet
        digitalWrite(GPIO_STATUS_LED, HIGH);
        delay(20);
        digitalWrite(GPIO_STATUS_LED, LOW);

#if !TELEM_QUIET
        Serial.printf("[RX] Packet OK type=0x%02X seq=%u len=%u rssi=%u\n",
                      pkt_decoder.last_packet().type,
                      pkt_decoder.last_packet().seq,
                      pkt_decoder.last_packet().length,
                      pkt_decoder.stats().rssi_last);
#endif
    }

    // Forward decoded MAVLink to GCS + USB serial + print stats
    mavOut.update(pkt_decoder);
}
