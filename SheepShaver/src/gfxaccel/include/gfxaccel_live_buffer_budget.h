/*
 *  gfxaccel_live_buffer_budget.h - Live memory accounting for DrawSprocket buffers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

/* Live resource accounting shared by the DSp allocator and its lifetime tokens.
 * Reservations stay charged while Metal command buffers or texture views retain
 * a buffer, even after its CPU owner has disposed it. */
#ifndef GFXACCEL_LIVE_BUFFER_BUDGET_H
#define GFXACCEL_LIVE_BUFFER_BUDGET_H

#include <atomic>
#include <cstdint>

class GfxAccelLiveBufferBudget {
public:
    bool reserve(uint64_t bytes, uint64_t ceiling) {
        if (bytes == 0 || bytes > ceiling) return false;
        uint64_t used = used_.load(std::memory_order_relaxed);
        do {
            if (used > ceiling - bytes) return false;
        } while (!used_.compare_exchange_weak(used, used + bytes,
                                              std::memory_order_acq_rel,
                                              std::memory_order_relaxed));
        return true;
    }

    void release(uint64_t bytes) {
        used_.fetch_sub(bytes, std::memory_order_release);
    }

private:
    std::atomic<uint64_t> used_{0};
};
#endif
