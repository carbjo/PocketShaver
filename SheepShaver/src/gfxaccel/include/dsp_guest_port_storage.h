/*
 *  dsp_guest_port_storage.h - Bounded storage for guest-visible DrawSprocket ports.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef DSP_GUEST_PORT_STORAGE_H
#define DSP_GUEST_PORT_STORAGE_H
#include <cstdint>

// All records start on 4-byte boundaries. PixMap=50 bytes, CGrafPort=108,
// and each rectangular region=10, each followed by its 4-byte handle.
constexpr uint32_t DSpPortPixMapOffset = 0;
constexpr uint32_t DSpPortPixMapHandleOffset = 52;
constexpr uint32_t DSpPortCGrafOffset = 56;
constexpr uint32_t DSpPortVisRegionOffset = 164;
constexpr uint32_t DSpPortVisHandleOffset = 176;
constexpr uint32_t DSpPortClipRegionOffset = 180;
constexpr uint32_t DSpPortClipHandleOffset = 192;
constexpr uint32_t DSpGuestPortStorageBytes = 196;

static inline uint32_t DSpGuestPortStorageSlot(uint32_t base, uint32_t slot,
                                             uint32_t count)
{
    if (!base || slot >= count ||
        uint64_t(base) + uint64_t(count) * DSpGuestPortStorageBytes > 0x100000000ull)
        return 0;
    return base + slot * DSpGuestPortStorageBytes;
}
#endif
