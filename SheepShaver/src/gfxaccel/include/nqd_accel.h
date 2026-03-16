/*
 *  nqd_accel.h - Metal compute acceleration for Native QuickDraw operations
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef NQD_ACCEL_H
#define NQD_ACCEL_H

#include "sysdeps.h"

// ---------------------------------------------------------------------------
// accl_params field offsets — duplicated from video_defs.h to avoid
// including video_defs.h → macos_util.h from .mm files, which would
// conflict with MacTypes.h pulled in by <Metal/Metal.h> (Point, Rect,
// noErr, ProcPtr redefinitions).
// These MUST stay in sync with video_defs.h.
// ---------------------------------------------------------------------------
enum {
    NQD_acclTransferMode   = 0x00c,
    NQD_acclPenMode        = 0x010,
    NQD_acclForePen        = 0x01c,
    NQD_acclBackPen        = 0x020,
    NQD_acclSrcBaseAddr    = 0x030,
    NQD_acclSrcRowBytes    = 0x034,
    NQD_acclSrcBoundsRect  = 0x038,
    NQD_acclSrcPixelSize   = 0x048,
    NQD_acclDestBaseAddr   = 0x064,
    NQD_acclDestRowBytes   = 0x068,
    NQD_acclDestBoundsRect = 0x06c,
    NQD_acclDestPixelSize  = 0x07c,
    NQD_acclSrcRect        = 0x0cc,
    NQD_acclDestRect       = 0x0d4,
    NQD_acclDrawProc       = 0x174,

    // Mask-related offsets
    NQD_acclMaskBits       = 0x018,   // mask-related field (flags/indicator)
    NQD_acclMaskAddr       = 0x128,   // mask region pointer
    NQD_acclMaskExtra      = 0x130,   // additional mask field
};

// Metal compute acceleration state
extern bool nqd_metal_available;    // true after successful NQDMetalInit()
#include "accel_logging.h"
#if ACCEL_LOGGING_ENABLED
extern bool nqd_logging_enabled;    // toggle for NQD_LOG diagnostic output (default false)
#else
static constexpr bool nqd_logging_enabled = false;
#endif

// Initialize Metal compute infrastructure: device, command queue, shader pipelines,
// shared RAM buffer. Sets nqd_metal_available = true on success.
extern void NQDMetalInit(void);

// Release Metal resources and set nqd_metal_available = false.
extern void NQDMetalCleanup(void);

// Metal-accelerated NQD operations. Each reads accl_params from Mac memory at address p.
extern void NQDMetalBitblt(uint32 p);
extern void NQDMetalFillRect(uint32 p);
extern void NQDMetalInvertRect(uint32 p);
extern void NQDMetalBltMask(uint32 p);
extern void NQDMetalFillMask(uint32 p);

// Check if a Mac address is within the Metal-mapped RAM region.
// Used by callers to decide whether Metal acceleration is safe.
extern bool NQDMetalAddrInBuffer(uint32 mac_addr);

#endif /* NQD_ACCEL_H */
