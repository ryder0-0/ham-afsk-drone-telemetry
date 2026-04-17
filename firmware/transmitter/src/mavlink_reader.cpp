// FILE: firmware/transmitter/src/mavlink_reader.cpp
#include "mavlink_reader.h"
#include "crc16.h"
#include <string.h>

// MAVLink X.25 CRC extra bytes (per message ID, subset we use)
static const uint8_t MAV_CRC_EXTRA[] = {
    [MAVMSG_HEARTBEAT]           = 50,
    [MAVMSG_SYS_STATUS]          = 124,
    [MAVMSG_GLOBAL_POSITION_INT] = 104,
    [MAVMSG_VFR_HUD]             = 20,
};
static const uint8_t MAV_CRC_EXTRA_MAX =
    sizeof(MAV_CRC_EXTRA) / sizeof(MAV_CRC_EXTRA[0]);

void MavlinkReader::begin(HardwareSerial &serial) {
    serial_ = &serial;
    state_  = State::IDLE;
}

bool MavlinkReader::update() {
    if (!serial_) return false;

    while (serial_->available()) {
        uint8_t b = (uint8_t)serial_->read();

        switch (state_) {
        case State::IDLE:
            if (b == MAV_V1_STX) {
                frame_buf_[0] = b;
                frame_len_ = 1;
                is_v2_ = false;
                state_ = State::HDR;
                expect_ = MAV_V1_HDR_LEN - 1;  // already consumed STX
            } else if (b == MAV_V2_STX) {
                frame_buf_[0] = b;
                frame_len_ = 1;
                is_v2_ = true;
                state_ = State::HDR;
                expect_ = 9;  // v2 header is 10 bytes, consumed STX
            } else {
                stats_.bytes_discarded++;
            }
            break;

        case State::HDR:
            frame_buf_[frame_len_++] = b;
            if (--expect_ == 0) {
                uint16_t payload_len;
                if (!is_v2_) {
                    payload_len = frame_buf_[1];  // LEN byte
                } else {
                    payload_len = frame_buf_[1];  // v2 LEN byte (low)
                }
                expect_ = payload_len;
                state_ = (payload_len > 0) ? State::PAYLOAD : State::CRC;
            }
            break;

        case State::PAYLOAD:
            frame_buf_[frame_len_++] = b;
            if (--expect_ == 0) {
                expect_ = 2;  // 2 CRC bytes
                state_ = State::CRC;
            }
            break;

        case State::CRC:
            frame_buf_[frame_len_++] = b;
            if (--expect_ == 0) {
                state_ = State::IDLE;
                process_frame();
                return true;
            }
            break;
        }
    }
    return false;
}

void MavlinkReader::process_frame() {
    if (is_v2_) {
        // For v2, just pass raw bytes through in tunnel mode
        stats_.frames_received++;
        return;
    }

    uint8_t payload_len = frame_buf_[1];
    uint8_t msg_id      = frame_buf_[5];

    // Verify CRC (MAVLink X.25 with CRC extra byte)
    uint16_t crc_calc = 0xFFFFu;
    for (uint16_t i = 1; i < (uint16_t)(MAV_V1_HDR_LEN + payload_len); ++i)
        crc_calc = crc16_ccitt_update(crc_calc, frame_buf_[i]);

    if (msg_id < MAV_CRC_EXTRA_MAX)
        crc_calc = crc16_ccitt_update(crc_calc, MAV_CRC_EXTRA[msg_id]);

    uint16_t crc_rx = (uint16_t)frame_buf_[MAV_V1_HDR_LEN + payload_len]
                    | ((uint16_t)frame_buf_[MAV_V1_HDR_LEN + payload_len + 1] << 8u);

    if (crc_calc != crc_rx) {
        stats_.frames_crc_fail++;
        return;
    }

    stats_.frames_received++;

#if TELEM_MODE_SUMMARY
    const uint8_t *pl = frame_buf_ + MAV_V1_HDR_LEN;
    switch (msg_id) {
    case MAVMSG_HEARTBEAT:           parse_heartbeat(pl);           break;
    case MAVMSG_SYS_STATUS:          parse_sys_status(pl);          break;
    case MAVMSG_GLOBAL_POSITION_INT: parse_global_position_int(pl); break;
    case MAVMSG_VFR_HUD:             parse_vfr_hud(pl);             break;
    default: break;
    }
#endif
}

// ---------- field parsers (little-endian) -----------------------------------

static inline int32_t get_i32(const uint8_t *p) {
    return (int32_t)((uint32_t)p[0] | (uint32_t)p[1]<<8 |
                     (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24);
}
static inline int16_t get_i16(const uint8_t *p) {
    return (int16_t)((uint16_t)p[0] | (uint16_t)p[1]<<8);
}
static inline uint16_t get_u16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1]<<8);
}

void MavlinkReader::parse_heartbeat(const uint8_t *pl) {
    // HEARTBEAT: type(1) autopilot(1) base_mode(1) custom_mode(4) system_status(1) mavlink_ver(1)
    summary_.flight_mode = pl[7];               // custom_mode low byte
    summary_.armed       = (pl[2] & 0x80u) ? 1u : 0u;  // base_mode bit 7
    telem_dirty_ = true;
}

void MavlinkReader::parse_sys_status(const uint8_t *pl) {
    // SYS_STATUS layout (v1, 31 bytes):
    // sensors_present(4) sensors_enabled(4) sensors_health(4)
    // load(2) voltage_battery(2) current_battery(2) drop_rate_comm(2)
    // errors_comm(2) ... battery_remaining(1)
    summary_.batt_mv  = (int16_t)get_u16(pl + 14);
    summary_.batt_pct = pl[30];
    telem_dirty_ = true;
}

void MavlinkReader::parse_global_position_int(const uint8_t *pl) {
    // time_boot_ms(4) lat(4) lon(4) alt(4) relative_alt(4)
    // vx(2) vy(2) vz(2) hdg(2)
    summary_.lat_e7    = get_i32(pl + 4);
    summary_.lon_e7    = get_i32(pl + 8);
    summary_.alt_mm    = get_i32(pl + 12);
    summary_.heading_cd = (int16_t)get_u16(pl + 26);
    telem_dirty_ = true;
}

void MavlinkReader::parse_vfr_hud(const uint8_t *pl) {
    // airspeed(4f) groundspeed(4f) heading(2) throttle(2) alt(4f) climb(4f)
    float gs;
    memcpy(&gs, pl + 4, 4);
    summary_.speed_cms = (int16_t)(gs * 100.0f);
    telem_dirty_ = true;
}
