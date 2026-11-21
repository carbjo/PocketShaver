/*
 *  gfx_guest_range.h - Checked guest-memory extents for graphics geometry.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef GFX_GUEST_RANGE_H
#define GFX_GUEST_RANGE_H
#include <cstdint>

static inline bool GfxGuestMappedRange(uint32_t address, uint64_t bytes,
    uint32_t ramBase, uint32_t ramSize, uint32_t romBase, uint32_t romSize)
{
    if (bytes > 0x100000000ull - address) return false;
    auto contains = [&](uint32_t base, uint32_t size) {
        return address >= base && uint64_t(address - base) + bytes <= size;
    };
    return contains(ramBase, ramSize) || contains(romBase, romSize);
}

static inline bool GfxGuestStridedRange(uint32_t address, uint32_t first,
    uint32_t last, uint32_t stride, uint32_t elementBytes,
    uint32_t ramBase, uint32_t ramSize, uint32_t romBase, uint32_t romSize)
{
    if (!address || !elementBytes || last < first) return false;
    const uint64_t begin = uint64_t(address) + uint64_t(first) * stride;
    const uint64_t end = uint64_t(address) + uint64_t(last) * stride + elementBytes;
    if (begin > UINT32_MAX || end > 0x100000000ull) return false;
    return GfxGuestMappedRange(uint32_t(begin), end - begin,
        ramBase, ramSize, romBase, romSize);
}
#endif
