// FILE: firmware/transmitter/include/mavlink_reader.h
//
// Lightweight MAVLink v1/v2 frame reader.
// In PKT_TYPE_MAVLINK mode  : passes raw frame bytes through unchanged.
// In PKT_TYPE_TELEM mode    : parses a small subset of messages and
//                             populates a TelemetrySummary struct.
//
// We do NOT link the full ArduPilot MAVLink library to keep binary size
// small and avoid dependency hell.  Only the fields we actually need are
// extracted.

#pragma once
#include <Arduino.h>
#include "packet.h"
#include "ring_buffer.h"

// MAVLink v1 magic byte and minimum frame size
#define MAV_V1_STX      0xFEu
#define MAV_V1_HDR_LEN  6u      // STX LEN SEQ SYSID COMPID MSGID
#define MAV_V1_CRC_LEN  2u

// MAVLink v2 magic byte
#define MAV_V2_STX      0xFDu

// Message IDs we care about for summary mode
#define MAVMSG_HEARTBEAT            0u
#define MAVMSG_SYS_STATUS           1u
#define MAVMSG_GLOBAL_POSITION_INT  33u
#define MAVMSG_VFR_HUD              74u

struct MavlinkReaderStats {
    uint32_t frames_received;
    uint32_t frames_crc_fail;
    uint32_t bytes_discarded;
};

class MavlinkReader {
public:
    void begin(HardwareSerial &serial);

    // Call frequently from main loop.
    // Returns true if a complete MAVLink frame is ready.
    bool update();

    // Valid after update() returns true.
    // raw_frame / raw_len: full wire bytes of the latest frame (tunnel mode).
    const uint8_t *raw_frame() const { return frame_buf_; }
    uint16_t       raw_len()   const { return frame_len_; }

    // Valid after update() returns true and message was parsed for summary mode.
    TelemetrySummary &telem_summary() { return summary_; }
    bool              telem_updated() const { return telem_dirty_; }
    void              clear_telem_flag()    { telem_dirty_ = false; }

    const MavlinkReaderStats &stats() const { return stats_; }

private:
    HardwareSerial *serial_ = nullptr;

    // Frame assembly
    enum class State { IDLE, HDR, PAYLOAD, CRC };
    State    state_     = State::IDLE;
    uint8_t  frame_buf_[MAV_V1_HDR_LEN + 255 + MAV_V1_CRC_LEN];
    uint16_t frame_len_ = 0;
    uint16_t expect_    = 0;   // bytes remaining to complete current section
    bool     is_v2_     = false;

    TelemetrySummary   summary_     = {};
    bool               telem_dirty_ = false;
    MavlinkReaderStats stats_       = {};

    void process_frame();
    void parse_heartbeat(const uint8_t *payload);
    void parse_sys_status(const uint8_t *payload);
    void parse_global_position_int(const uint8_t *payload);
    void parse_vfr_hud(const uint8_t *payload);
};
