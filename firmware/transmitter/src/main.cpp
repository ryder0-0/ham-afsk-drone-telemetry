// FILE: firmware/transmitter/src/main.cpp
//
// Drone-side transmitter.
// Reads MAVLink from UART2 (flight controller), packetises, and transmits
// over AFSK Bell 202 via the radio mic input.
//
// Hardware: ESP32 WROOM-32
//   GPIO25  → DAC out  → R divider → radio mic in
//   GPIO4   → PTT      → NPN base  → radio PTT pin
//   GPIO16  ← UART2 RX ← flight controller TX (57600 8N1)
//   GPIO17  → UART2 TX → flight controller RX  (passthrough, not used in TX-only mode)

#include <Arduino.h>
#include "modem_config.h"
#include "afsk_modulator.h"
#include "mavlink_reader.h"
#include "ptt_control.h"
#include "packet.h"

// UART2 is the MAVLink port
HardwareSerial mavSerial(2);

MavlinkReader  mavReader;

static uint8_t  seq_counter    = 0;
static uint32_t last_tx_ms     = 0;
static uint32_t last_mavlink_ms = 0;

// ---------------------------------------------------------------------------
// Build and transmit a heartbeat when no MAVLink arrives
// ---------------------------------------------------------------------------
static void send_heartbeat() {
    Packet pkt;
    pkt.type   = PKT_TYPE_HEARTBEAT;
    pkt.seq    = seq_counter++;
    pkt.length = 0;

    if (!modulator.prepare_packet(pkt)) return;
    modulator.transmit();

    Serial.printf("[TX] Heartbeat seq=%u\n", pkt.seq);
    last_tx_ms = millis();
}

// ---------------------------------------------------------------------------
// Transmit a raw MAVLink frame in tunnel mode
// ---------------------------------------------------------------------------
static void send_mavlink_tunnel(const uint8_t *data, uint16_t len) {
    if (len > MAX_PAYLOAD_LEN) {
        Serial.printf("[TX] Frame too large (%u bytes), skipping\n", len);
        return;
    }

    Packet pkt;
    pkt.type   = PKT_TYPE_MAVLINK;
    pkt.seq    = seq_counter++;
    pkt.length = len;
    memcpy(pkt.payload, data, len);

    if (!modulator.prepare_packet(pkt)) return;
    modulator.transmit();

    Serial.printf("[TX] MAVLink tunnel seq=%u len=%u\n", pkt.seq, len);
    last_tx_ms = millis();
}

// ---------------------------------------------------------------------------
// Transmit compressed telemetry summary
// ---------------------------------------------------------------------------
static void send_telem_summary(const TelemetrySummary &s) {
    Packet pkt;
    pkt.type   = PKT_TYPE_TELEM;
    pkt.seq    = seq_counter++;
    pkt.length = sizeof(TelemetrySummary);
    memcpy(pkt.payload, &s, sizeof(s));

    if (!modulator.prepare_packet(pkt)) return;
    modulator.transmit();

    Serial.printf("[TX] Telem summary seq=%u lat=%.5f lon=%.5f alt=%.1fm\n",
                  pkt.seq,
                  s.lat_e7 / 1e7,
                  s.lon_e7 / 1e7,
                  s.alt_mm / 1000.0f);
    last_tx_ms = millis();
}

// ---------------------------------------------------------------------------
// Arduino entry points
// ---------------------------------------------------------------------------
void setup() {
    Serial.begin(USB_SERIAL_BAUD);
    Serial.println("\n[HAM-AFSK] Transmitter starting");

    ptt_init();
    modulator.begin();

    mavSerial.begin(MAVLINK_UART_BAUD, SERIAL_8N1, GPIO_MAVLINK_RX, GPIO_MAVLINK_TX);
    mavSerial.setRxBufferSize(MAVLINK_UART_RX_BUF);
    mavReader.begin(mavSerial);

    Serial.printf("[TX] Mode: %s\n",
                  TELEM_MODE_SUMMARY ? "telemetry-summary" : "mavlink-tunnel");

    last_tx_ms = millis();
}

void loop() {
    uint32_t now = millis();

    // Drain MAVLink serial and reassemble frames
    bool got_frame = mavReader.update();

    if (got_frame) {
        last_mavlink_ms = now;

#if TELEM_MODE_SUMMARY
        if (mavReader.telem_updated()) {
            send_telem_summary(mavReader.telem_summary());
            mavReader.clear_telem_flag();
        }
#else
        send_mavlink_tunnel(mavReader.raw_frame(), mavReader.raw_len());
#endif
    }

    // Heartbeat if no MAVLink for a while
    if ((now - last_tx_ms) >= HEARTBEAT_INTERVAL_MS) {
        send_heartbeat();
    }

    // Warn on MAVLink silence
    if ((now - last_mavlink_ms) > 3000u && last_mavlink_ms != 0) {
        Serial.println("[TX] WARNING: no MAVLink for >3 s");
    }
}
