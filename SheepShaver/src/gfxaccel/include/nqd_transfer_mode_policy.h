/*
 *  nqd_transfer_mode_policy.h - QuickDraw operations supported by Metal.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef NQD_TRANSFER_MODE_POLICY_H
#define NQD_TRANSFER_MODE_POLICY_H

#include <stdint.h>

static inline bool NQDMetalSupportsTransferMode(uint32_t depth, uint32_t mode)
{
	// At 1 bit the arithmetic modes have defined Boolean equivalents, which
	// the kernels implement. Transparent mode compares pixel values directly.
	if (depth == 1 || mode < 32 || mode > 39 || mode == 36) return true;
	// Indexed arithmetic requires CLUT -> RGB -> inverse-table conversion.
	// Direct-color addPin/subPin require the port's per-channel OpColor limits.
	// Leave these cases with software QuickDraw until the kernels support them.
	return depth > 8 && mode != 33 && mode != 35;
}

#endif /* NQD_TRANSFER_MODE_POLICY_H */
