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

// accl_params field offsets, duplicated from video_defs.h because including it
// from .mm files clashes with MacTypes.h via <Metal/Metal.h>. Must stay in sync
// with video_defs.h.
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

    // Mask fields
    NQD_acclMaskBits       = 0x018,   // flags/indicator
    NQD_acclMaskAddr       = 0x128,   // mask region pointer
    NQD_acclMaskExtra      = 0x130,
};

extern bool nqd_metal_available;    // true after successful NQDMetalInit()
#include "accel_logging.h"
#if ACCEL_LOGGING_ENABLED
extern bool nqd_logging_enabled;    // gates NQD_LOG
#else
static constexpr bool nqd_logging_enabled = false;
#endif

// Sets up pipelines and the shared RAM buffer; sets nqd_metal_available.
extern void NQDMetalInit(void);

extern void NQDMetalCleanup(void);

// Flushes batched compute dispatches. Called from NQD_sync_hook and each
// Present; no-op when nothing is pending.
extern void NQDMetalFlush(void);

// Each reads accl_params at guest address p.
extern void NQDMetalBitblt(uint32 p);
extern void NQDMetalFillRect(uint32 p);
extern void NQDMetalInvertRect(uint32 p);
extern void NQDMetalBltMask(uint32 p);
extern void NQDMetalFillMask(uint32 p);

// True if mac_addr lies in the Metal-mapped RAM region.
extern bool NQDMetalAddrInBuffer(uint32 mac_addr);

// True when the bitblt src and dest rects overlap in memory, including via
// distinct PixMap aliases; negative strides mean backward traversal.
// NQD_bitblt_hook sends overlaps the GPU cannot order (packed-depth Boolean,
// arithmetic, hilite) to software QuickDraw. Standard-depth Boolean overlaps
// stay accelerated via an ordered CPU scratch path in NQDMetalBitblt.
extern bool NQDMetalBitbltSameSurfaceOverlap(uint32 p);

// DSpBlit_Fastest (sub-op 711): unscaled copy via the nqd_bitblt kernel.
// Bases are guest addresses of the rect origins. transfer_mode is 0 (srcCopy)
// or 36 (transparent, src_key is the key). Returns true if encoded into the
// NQD batch; false (including out-of-buffer bases) maps to kDSpInternalErr.
extern bool NQDMetalBitblt1to1(uint32 src_base, int32 src_row_bytes,
                               uint32 dst_base, int32 dst_row_bytes,
                               uint32 pixel_size_bytes, uint32 bits_per_pixel,
                               uint32 width_pixels, uint32 height,
                               uint32 transfer_mode, uint32 src_key);

// DSpBlit_Faster (sub-op 710): scaled blit, nearest-neighbor or bilinear when
// interpolate != 0, color key per key_enable. Bases are guest addresses of the
// rect origins. Returns true if encoded into the NQD batch; false (no Metal,
// degenerate geometry, unsupported pixel size, out-of-buffer base) maps to
// kDSpInternalErr.
extern bool NQDMetalBitbltScaled(uint32 src_base, int32 src_row_bytes,
                                 uint32 dst_base, int32 dst_row_bytes,
                                 uint32 pixel_size_bytes, uint32 bits_per_pixel,
                                 uint32 src_w, uint32 src_h,
                                 uint32 dst_w, uint32 dst_h,
                                 uint32 interpolate,
                                 uint32 src_key, uint32 dst_key,
                                 uint32 key_enable);

#endif /* NQD_ACCEL_H */
