// FILE: firmware/common/include/crc16.h
#pragma once
#include <stdint.h>
#include <stddef.h>

// CRC16-CCITT: polynomial 0x1021, initial value 0xFFFF, no final XOR.
// This matches the variant used by AX.25 / KISS framing.

uint16_t crc16_ccitt(const uint8_t *data, size_t len);

// Incremental variant — call crc16_ccitt_update() for each byte, start with 0xFFFF.
uint16_t crc16_ccitt_update(uint16_t crc, uint8_t byte);
