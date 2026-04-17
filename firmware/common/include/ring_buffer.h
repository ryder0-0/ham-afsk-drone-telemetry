// FILE: firmware/common/include/ring_buffer.h
//
// Lock-free single-producer / single-consumer ring buffer.
// SIZE must be a power of two.  head is written only by the producer,
// tail only by the consumer — no mutex needed for SPSC use.

#pragma once
#include <stdint.h>
#include <string.h>

template<typename T, uint16_t SIZE>
class RingBuffer {
    static_assert((SIZE & (SIZE - 1)) == 0, "SIZE must be a power of 2");

    volatile T       buf_[SIZE];
    volatile uint16_t head_ = 0;   // next write position
    volatile uint16_t tail_ = 0;   // next read position

public:
    bool push(T val) {
        uint16_t next = (head_ + 1u) & (SIZE - 1u);
        if (next == tail_) return false;   // full
        buf_[head_] = val;
        head_ = next;
        return true;
    }

    // ISR-safe alias — semantically identical; exists for readability at call sites.
    bool push_isr(T val) { return push(val); }

    bool pop(T &val) {
        if (head_ == tail_) return false;  // empty
        val = buf_[tail_];
        tail_ = (tail_ + 1u) & (SIZE - 1u);
        return true;
    }

    bool empty() const { return head_ == tail_; }

    uint16_t available() const {
        return (head_ - tail_) & (SIZE - 1u);
    }

    void clear() { head_ = tail_ = 0; }
};
