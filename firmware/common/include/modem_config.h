// FILE: firmware/common/include/modem_config.h
//
// Central constants shared by transmitter, receiver, and Python tools.
// All values must be kept in sync with tools/wav_test_generator/generate_test_wav.py.

#pragma once
#include <stdint.h>

// ---------------------------------------------------------------------------
// Sample rate / modulation
// ---------------------------------------------------------------------------
// 9600 Hz was chosen because 9600 / 1200 = 8 exactly, giving a clean integer
// number of samples per bit with no rounding error in the phase accumulator.
// The hardware timer fires at 80 MHz / 80 / 104 = 9615 Hz, ~0.16 % off.
// The receiver's bit-clock PLL absorbs this and any inter-board crystal drift.

#define SAMPLE_RATE         9600u        // nominal, see actual timer below
#define BAUD_RATE           1200u
#define SAMPLES_PER_BIT     8u           // SAMPLE_RATE / BAUD_RATE

#define MARK_FREQ           1200u        // Bell 202 mark tone (Hz)
#define SPACE_FREQ          2200u        // Bell 202 space tone (Hz)

// 16-bit phase accumulator increments (2^16 * freq / sample_rate)
// Mark:  65536 * 1200 / 9600 = 8192    (exact integer — zero phase error)
// Space: 65536 * 2200 / 9600 = 15019.7 (truncated; 0.005 % error per cycle)
#define MARK_PHASE_INC      8192u
#define SPACE_PHASE_INC     15019u

// Hardware timer: 80 MHz APB / prescaler 80 = 1 MHz tick, alarm 104 → 9615 Hz
#define TIMER_PRESCALER     80u
#define TIMER_ALARM_TICKS   104u

// IIR LPF coefficient for quadrature demodulator.
// y[n] = ALPHA*x[n] + (1-ALPHA)*y[n-1]
// fc = -ln(1-ALPHA) * fs / (2*pi) = -ln(0.75) * 9600 / 6.283 ≈ 441 Hz
// This is comfortably below half the baud rate (600 Hz).
#define IIR_ALPHA           0.25f
#define IIR_ONE_MINUS_ALPHA 0.75f

// Hysteresis for tone decision: the stronger tone must exceed the weaker by
// this factor to flip the output, preventing noise-induced false transitions.
#define TONE_HYSTERESIS     1.08f

// RSSI estimate: ratio of winning-tone power to total power, 0–100.
// Reported in heartbeat and stats output.

// ---------------------------------------------------------------------------
// Packet framing
// ---------------------------------------------------------------------------
// Wire format (NRZI-encoded, sent LSB-first):
//
//  [PREAMBLE × PREAMBLE_LEN] [SYNC_0] [SYNC_1] [TYPE] [SEQ]
//  [LEN_LO] [LEN_HI] [PAYLOAD × LEN] [CRC_LO] [CRC_HI]
//
// CRC16-CCITT covers: SYNC_0 through last payload byte (NOT preamble).
// Total overhead: 2 (sync) + 1 (type) + 1 (seq) + 2 (len) + 2 (crc) = 8 bytes.

#define PREAMBLE_BYTE       0xAAu   // alternating 1/0 → predictable NRZI transitions
#define PREAMBLE_LEN        25u     // 25 bytes × 8 bits / 1200 baud ≈ 167 ms
                                    // enough preamble to open squelch + sync bit clock

#define SYNC_BYTE_0         0x2Du
#define SYNC_BYTE_1         0xD4u

#define MAX_PAYLOAD_LEN     260u    // MAVLink v1 max is 255 bytes payload + header

// Packet type field
#define PKT_TYPE_MAVLINK    0x00u   // raw MAVLink bytes in payload (tunnel mode)
#define PKT_TYPE_TELEM      0x01u   // compressed telemetry summary
#define PKT_TYPE_HEARTBEAT  0xFFu   // modem alive, no MAVLink payload

// Compile-time mode switch.  Override in platformio.ini build_flags.
#ifndef TELEM_MODE_SUMMARY
#define TELEM_MODE_SUMMARY  0       // 0 = tunnel, 1 = summary
#endif

// ---------------------------------------------------------------------------
// GPIO pin assignments (ESP32 WROOM-32)
// ---------------------------------------------------------------------------
#define GPIO_DAC_OUT        25      // DAC channel 1 — audio to radio mic
#define GPIO_ADC_IN         34      // ADC1 channel 6 — audio from radio speaker
#define GPIO_PTT            4       // PTT output — drives NPN transistor base
#define GPIO_STATUS_LED     2       // on-board LED
#define GPIO_MAVLINK_RX     16      // UART2 RX — from flight controller / GCS
#define GPIO_MAVLINK_TX     17      // UART2 TX — to flight controller / GCS

// ---------------------------------------------------------------------------
// PTT timing (ms)
// ---------------------------------------------------------------------------
#define PTT_SETTLE_MS       80u     // after PTT assert, before first audio sample
                                    // most radios need 50–100 ms to open PA
#define PTT_TAIL_MS         60u     // hold PTT after last sample to avoid squelch
                                    // cutting the packet tail

// ---------------------------------------------------------------------------
// Watchdog / heartbeat
// ---------------------------------------------------------------------------
#define HEARTBEAT_INTERVAL_MS  5000u   // send modem heartbeat if no MAVLink
#define WDT_TIMEOUT_MS         10000u  // software watchdog reset timeout

// ---------------------------------------------------------------------------
// UART
// ---------------------------------------------------------------------------
#define MAVLINK_UART_BAUD   57600u  // default ArduPilot telemetry port baud rate
#define MAVLINK_UART_RX_BUF 512u
#define USB_SERIAL_BAUD     115200u // USB debug / GCS forward port
