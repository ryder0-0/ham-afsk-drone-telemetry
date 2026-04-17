// FILE: firmware/common/src/crc16.cpp
#include "crc16.h"

uint16_t crc16_ccitt_update(uint16_t crc, uint8_t byte) {
    crc ^= (uint16_t)byte << 8;
    for (int i = 0; i < 8; ++i) {
        if (crc & 0x8000u)
            crc = (crc << 1u) ^ 0x1021u;
        else
            crc <<= 1u;
    }
    return crc;
}

uint16_t crc16_ccitt(const uint8_t *data, size_t len) {
    uint16_t crc = 0xFFFFu;
    for (size_t i = 0; i < len; ++i)
        crc = crc16_ccitt_update(crc, data[i]);
    return crc;
}
