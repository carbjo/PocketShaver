/*
 *  nqd_region_range.h - QuickDraw region header and payload range validation.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef NQD_REGION_RANGE_H
#define NQD_REGION_RANGE_H

#include <stdint.h>

static inline bool NQDRegionBytesReadable(uint32_t address, uint32_t length,
                                          uint32_t ram_base, uint32_t ram_size,
                                          uint32_t rom_base, uint32_t rom_size)
{
	const uint64_t end = uint64_t(address) + length;
	if (!length || end > (uint64_t(1) << 32)) return false;
	return (address >= ram_base && end <= uint64_t(ram_base) + ram_size) ||
	       (address >= rom_base && end <= uint64_t(rom_base) + rom_size);
}

// Two-phase validation: do not read even rgnSize until the entire header is
// mapped, then validate every declared payload byte before reading the bbox.
// A region must fit one contiguous RAM/ROM mapping; it cannot span domains.
template<class Read16>
static inline bool NQDReadMappedRegionSize(uint32_t address,
                                           uint32_t ram_base, uint32_t ram_size,
                                           uint32_t rom_base, uint32_t rom_size,
                                           Read16 read16, uint16_t *out_size)
{
	if (!address || !NQDRegionBytesReadable(address, 10, ram_base, ram_size,
	                                       rom_base, rom_size)) return false;
	const uint32_t size = read16(address);
	if (size < 10 || size > UINT16_MAX ||
	    !NQDRegionBytesReadable(address, size, ram_base, ram_size,
	                           rom_base, rom_size)) return false;
	if (out_size) *out_size = uint16_t(size);
	return true;
}

#endif
