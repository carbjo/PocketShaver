/*
 *  nqd_metal_renderer.mm - Metal compute acceleration for NQD 2D operations
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Implements Metal compute shaders for NQD bitblt (srcCopy), fillrect,
 *  and invrect operations. Mac RAM is wrapped as a shared MTLBuffer so the
 *  GPU reads/writes the same memory the CPU emulator uses.
 */

#import <Metal/Metal.h>

#include <vector>
#include "sysdeps.h"
#include "cpu_emulation.h"
#include "nqd_accel.h"
#include "accel_logging.h"
#include "metal_device_shared.h"

// ---------------------------------------------------------------------------
// Diagnostic logging
// ---------------------------------------------------------------------------

#if ACCEL_LOGGING_ENABLED
bool nqd_logging_enabled = false;

#define NQD_LOG(fmt, ...) \
    do { if (nqd_logging_enabled) printf("[NQD Metal] " fmt "\n", ##__VA_ARGS__); } while (0)
#else
#define NQD_LOG(fmt, ...) do {} while (0)
#endif

// Always-on error logging (not gated by ACCEL_LOGGING_ENABLED)
#define NQD_ERR(fmt, ...) \
    do { printf("[NQD Metal ERROR] " fmt "\n", ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------------------
// Metal state (file-static)
// ---------------------------------------------------------------------------

bool nqd_metal_available = false;

static id<MTLDevice>              nqd_device       = nil;
static id<MTLCommandQueue>        nqd_queue        = nil;
static id<MTLComputePipelineState> nqd_bitblt_pipeline = nil;
static id<MTLComputePipelineState> nqd_fillrect_pipeline = nil;
static id<MTLBuffer>              nqd_ram_buffer   = nil;
static uint8                     *nqd_ram_base     = nullptr; // host pointer that corresponds to Metal buffer start
static uint32                     nqd_ram_size     = 0;       // size of the Metal buffer (== RAMSize)

// ---------------------------------------------------------------------------
// Batched command encoding state
//
// Instead of creating/committing a command buffer per NQD call, we accumulate
// multiple compute dispatches into a single command buffer + encoder. The batch
// is flushed (committed + waited) when:
//   1. NQDMetalFlush() is called (from NQD_sync_hook or MetalCompositorPresent)
//   2. A backward blit needs ordering guarantees
//   3. A mask operation needs the mask buffer (which may be reused across calls)
//
// This amortizes command buffer creation and GPU submission overhead across
// all NQD operations within a frame, which is the dominant perf bottleneck.
// ---------------------------------------------------------------------------

static id<MTLCommandBuffer>         nqd_batch_cmdbuf  = nil;
static id<MTLComputeCommandEncoder> nqd_batch_encoder = nil;
static int                          nqd_batch_count   = 0;

// Maximum dispatches before an automatic flush. Prevents unbounded accumulation
// (e.g. if sync_hook is never called). 128 dispatches ≈ one busy frame.
static const int NQD_BATCH_MAX = 128;

// ---------------------------------------------------------------------------
// CPU fast-path threshold (in total pixels)
//
// For small rects, the Metal submission overhead (command buffer alloc,
// encoder setup, GPU scheduling, waitUntilCompleted stall) far exceeds
// the actual compute time. The CPU path (memset/memmove/XOR loop) is
// faster for operations below this threshold.
//
// Even with batching, each dispatch adds encoder overhead. For tiny ops
// (icons, cursors, text glyphs), CPU is still faster.
// ---------------------------------------------------------------------------

static const int NQD_CPU_THRESHOLD_PIXELS = 4096;  // ~64x64 or equivalent

// Check if a Mac address is within the Metal-mapped RAM region.
static inline bool nqd_addr_in_buffer(uint32 mac_addr)
{
    return mac_addr >= RAMBase && mac_addr < RAMBase + nqd_ram_size;
}

bool NQDMetalAddrInBuffer(uint32 mac_addr)
{
    return nqd_addr_in_buffer(mac_addr);
}

// ---------------------------------------------------------------------------
// Batch command buffer helpers
// ---------------------------------------------------------------------------

// Ensure we have an active batch command buffer + encoder.
// Returns the encoder, creating a new batch if needed.
static id<MTLComputeCommandEncoder> nqd_get_batch_encoder(void)
{
    if (!nqd_batch_encoder) {
        nqd_batch_cmdbuf = [nqd_queue commandBuffer];
        if (!nqd_batch_cmdbuf) {
            NQD_ERR("nqd_get_batch_encoder: commandBuffer creation failed");
            return nil;
        }
        nqd_batch_encoder = [nqd_batch_cmdbuf computeCommandEncoder];
        if (!nqd_batch_encoder) {
            NQD_ERR("nqd_get_batch_encoder: computeCommandEncoder creation failed");
            nqd_batch_cmdbuf = nil;
            return nil;
        }
        nqd_batch_count = 0;
    }
    return nqd_batch_encoder;
}

// Increment batch count and auto-flush if we've hit the max.
static void nqd_batch_did_dispatch(void)
{
    nqd_batch_count++;
    if (nqd_batch_count >= NQD_BATCH_MAX) {
        NQDMetalFlush();
    }
}

// ---------------------------------------------------------------------------
// NQDMetalFlush — commit the batched command buffer and wait for completion
//
// Called from NQD_sync_hook (Mac OS sync point) and before
// MetalCompositorPresent (frame boundary). Also called internally when
// ordering guarantees are needed (backward blits, mask buffer reuse).
// ---------------------------------------------------------------------------

void NQDMetalFlush(void)
{
    if (!nqd_batch_encoder) return;

    @autoreleasepool {
    [nqd_batch_encoder endEncoding];
    [nqd_batch_cmdbuf commit];
    [nqd_batch_cmdbuf waitUntilCompleted];

    if (nqd_batch_cmdbuf.error) {
        NQD_ERR("NQDMetalFlush: GPU error after %d dispatches: %s",
                nqd_batch_count,
                [[nqd_batch_cmdbuf.error localizedDescription] UTF8String]);
    }

    NQD_LOG("NQDMetalFlush: committed %d dispatches", nqd_batch_count);

    nqd_batch_encoder = nil;
    nqd_batch_cmdbuf = nil;
    nqd_batch_count = 0;
    } // @autoreleasepool
}

// ---------------------------------------------------------------------------
// Uniform struct — must match NQDBitbltUniforms in nqd_shaders.metal
// ---------------------------------------------------------------------------

struct NQDBitbltUniforms {
    uint32_t src_offset;
    uint32_t dst_offset;
    int32_t  src_row_bytes;
    int32_t  dst_row_bytes;
    uint32_t width_bytes;
    uint32_t height;
    uint32_t transfer_mode;
    uint32_t pixel_size;     // bytes per pixel (1, 2, or 4)
    uint32_t width_pixels;   // width in pixels (for arithmetic/hilite modes)
    uint32_t fore_pen;       // foreground pen color (big-endian packed)
    uint32_t back_pen;       // background pen color (big-endian packed)
    uint32_t hilite_color;   // HiliteRGB packed to pixel depth
    uint32_t mask_enabled;   // 1 = mask gating active, 0 = no mask
    uint32_t mask_offset;    // byte offset into mask_buffer where mask data starts
    uint32_t mask_stride;    // mask row stride (width_bytes for Boolean, width_pixels for arithmetic)
    uint32_t bits_per_pixel; // raw pixel depth in bits (1, 2, 4, 8, 16, or 32) — for packed pixel support
};

// Uniforms for fillrect — must match NQDFillRectUniforms in nqd_shaders.metal
struct NQDFillRectUniforms {
    uint32_t dst_offset;
    int32_t  row_bytes;
    uint32_t width_bytes;
    uint32_t height;
    uint32_t fill_color;     // 32-bit fill pattern (fore or back pen, htonl'd)
    uint32_t bpp;            // bytes per pixel (1, 2, or 4)
    uint32_t transfer_mode;  // pen mode: 8-15 (Boolean), 32-39 (arithmetic), 50 (hilite)
    uint32_t pixel_size;     // bytes per pixel (same as bpp)
    uint32_t width_pixels;   // width in pixels (for arithmetic/hilite per-pixel dispatch)
    uint32_t fore_pen;       // foreground pen color (big-endian packed)
    uint32_t back_pen;       // background pen color (big-endian packed)
    uint32_t hilite_color;   // HiliteRGB packed to pixel depth
    uint32_t mask_enabled;   // 1 = mask gating active, 0 = no mask
    uint32_t mask_offset;    // byte offset into mask_buffer where mask data starts
    uint32_t mask_stride;    // mask row stride (width_bytes for Boolean, width_pixels for arithmetic)
    uint32_t bits_per_pixel; // raw pixel depth in bits (1, 2, 4, 8, 16, or 32) — for packed pixel support
};

// ---------------------------------------------------------------------------
// Helper: bytes per pixel
// ---------------------------------------------------------------------------

static inline int nqd_bytes_per_pixel(uint32 pixel_size)
{
    switch (pixel_size) {
        case 8:        return 1;
        case 15:
        case 16:       return 2;
        case 24:
        case 32:       return 4;
        default:       return 1;
    }
}

// ---------------------------------------------------------------------------
// Helper: packed pixel width in bytes (handles sub-byte depths)
// Matches TrivialBytesPerRow from video.h for all 6 Apple depths.
// ---------------------------------------------------------------------------

static inline uint32_t nqd_packed_width_bytes(int width, uint32_t pixel_size_bits)
{
    switch (pixel_size_bits) {
        case 1:  return (uint32_t)((width + 7) / 8);
        case 2:  return (uint32_t)((width + 3) / 4);
        case 4:  return (uint32_t)((width + 1) / 2);
        case 8:  return (uint32_t)width;
        case 15:
        case 16: return (uint32_t)(width * 2);
        case 24:
        case 32: return (uint32_t)(width * 4);
        default: return (uint32_t)width;
    }
}

// ---------------------------------------------------------------------------
// Helper: byte offset for pixel X coordinate (handles sub-byte depths)
// For packed depths (1/2/4), returns the byte containing pixel X.
// ---------------------------------------------------------------------------

static inline uint32_t nqd_packed_byte_offset(int x, uint32_t pixel_size_bits)
{
    switch (pixel_size_bits) {
        case 1:  return (uint32_t)(x / 8);
        case 2:  return (uint32_t)(x / 4);
        case 4:  return (uint32_t)(x / 2);
        case 8:  return (uint32_t)x;
        case 15:
        case 16: return (uint32_t)(x * 2);
        case 24:
        case 32: return (uint32_t)(x * 4);
        default: return (uint32_t)x;
    }
}

// ---------------------------------------------------------------------------
// NQDMetalInit — create device, queue, pipeline, wrap Mac RAM
// ---------------------------------------------------------------------------

void NQDMetalInit(void)
{
    NQD_LOG("NQDMetalInit: starting");

    // Create Metal device
    nqd_device = (__bridge id<MTLDevice>)SharedMetalDevice();
    if (!nqd_device) {
        NQD_ERR("NQDMetalInit: SharedMetalDevice failed — no Metal GPU");
        return;
    }
    NQD_LOG("NQDMetalInit: device=%p (%s)", nqd_device, [[nqd_device name] UTF8String]);

    // Create command queue
    nqd_queue = (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
    if (!nqd_queue) {
        NQD_ERR("NQDMetalInit: SharedMetalCommandQueue failed");
        nqd_device = nil;
        return;
    }

    // Load shader library (compiled into app bundle as default metallib)
    id<MTLLibrary> library = [nqd_device newDefaultLibrary];
    if (!library) {
        NQD_ERR("NQDMetalInit: newDefaultLibrary failed — no .metallib in bundle");
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    // Create compute pipeline for nqd_bitblt kernel
    id<MTLFunction> bitblt_func = [library newFunctionWithName:@"nqd_bitblt"];
    if (!bitblt_func) {
        NQD_ERR("NQDMetalInit: kernel function 'nqd_bitblt' not found in library");
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    NSError *error = nil;
    nqd_bitblt_pipeline = [nqd_device newComputePipelineStateWithFunction:bitblt_func error:&error];
    if (!nqd_bitblt_pipeline) {
        NQD_ERR("NQDMetalInit: bitblt pipeline creation failed: %s",
                [[error localizedDescription] UTF8String]);
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    // Create compute pipeline for nqd_fillrect kernel
    id<MTLFunction> fillrect_func = [library newFunctionWithName:@"nqd_fillrect"];
    if (!fillrect_func) {
        NQD_ERR("NQDMetalInit: kernel function 'nqd_fillrect' not found in library");
        nqd_bitblt_pipeline = nil;
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    error = nil;
    nqd_fillrect_pipeline = [nqd_device newComputePipelineStateWithFunction:fillrect_func error:&error];
    if (!nqd_fillrect_pipeline) {
        NQD_ERR("NQDMetalInit: fillrect pipeline creation failed: %s",
                [[error localizedDescription] UTF8String]);
        nqd_bitblt_pipeline = nil;
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    // Wrap Mac RAM as a shared Metal buffer (zero-copy — GPU reads/writes CPU memory)
    // Use RAMBaseHost (the mmap'd allocation) instead of Mac2HostAddr(0), which
    // may hit the gZeroPage intercept and return a non-page-aligned global array.
    // Metal's newBufferWithBytesNoCopy requires both pointer and length to be page-aligned.
    uint8 *ram_host = RAMBaseHost;
    nqd_ram_buffer = [nqd_device newBufferWithBytesNoCopy:ram_host
                                                   length:RAMSize
                                                  options:MTLResourceStorageModeShared
                                              deallocator:nil];
    if (!nqd_ram_buffer) {
        NQD_ERR("NQDMetalInit: newBufferWithBytesNoCopy failed (RAMSize=%u, host=%p)", RAMSize, ram_host);
        nqd_bitblt_pipeline = nil;
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    nqd_ram_base = ram_host;
    nqd_ram_size = RAMSize;
    nqd_metal_available = true;
    NQD_LOG("NQDMetalInit: success — device=%s, RAMSize=%u, ram_buffer=%p",
            [[nqd_device name] UTF8String], RAMSize, nqd_ram_buffer);
}

// ---------------------------------------------------------------------------
// Helper: check if transfer mode is arithmetic/hilite (per-pixel dispatch)
// ---------------------------------------------------------------------------

static inline bool nqd_is_pixel_mode(uint32_t mode)
{
    return (mode >= 32 && mode <= 39) || mode == 50;
}

// ---------------------------------------------------------------------------
// Helper: pack HiliteRGB from Mac low-memory global into pixel-depth value
//
// HiliteRGB at Mac address 0x0DA0: 6 bytes = uint16 red, uint16 green, uint16 blue
// (big-endian, each 0-65535). Pack to pixel-depth representation matching
// framebuffer byte order (big-endian packed via htonl pattern).
// ---------------------------------------------------------------------------

static uint32_t nqd_pack_hilite_color(int bpp)
{
    uint16 r16 = ReadMacInt16(0x0DA0);
    uint16 g16 = ReadMacInt16(0x0DA2);
    uint16 b16 = ReadMacInt16(0x0DA4);

    if (bpp == 1) {
        // 8bpp indexed: use red channel high byte as index approximation
        return (r16 >> 8) & 0xFF;
    } else if (bpp == 2) {
        // 16bpp 1-5-5-5 ARGB: truncate 16-bit channels to 5-bit, set alpha=1
        uint16 r5 = (r16 >> 11) & 0x1F;
        uint16 g5 = (g16 >> 11) & 0x1F;
        uint16 b5 = (b16 >> 11) & 0x1F;
        return (uint32_t)((1 << 15) | (r5 << 10) | (g5 << 5) | b5);
    } else {
        // 32bpp ARGB: truncate 16-bit channels to 8-bit, alpha=0xFF
        uint8_t r8 = (r16 >> 8) & 0xFF;
        uint8_t g8 = (g16 >> 8) & 0xFF;
        uint8_t b8 = (b16 >> 8) & 0xFF;
        return (uint32_t)((0xFF << 24) | (r8 << 16) | (g8 << 8) | b8);
    }
}

// ---------------------------------------------------------------------------
// Mask buffer management (file-static)
// ---------------------------------------------------------------------------

static id<MTLBuffer>  nqd_mask_buffer      = nil;
static NSUInteger     nqd_mask_buffer_size  = 0;

static void nqd_ensure_mask_buffer(NSUInteger needed)
{
    if (nqd_mask_buffer && nqd_mask_buffer_size >= needed) return;
    // Round up to 4 KB granularity for reuse
    NSUInteger alloc_size = (needed + 4095) & ~(NSUInteger)4095;
    nqd_mask_buffer = [nqd_device newBufferWithLength:alloc_size
                                              options:MTLResourceStorageModeShared];
    nqd_mask_buffer_size = alloc_size;
    NQD_LOG("nqd_ensure_mask_buffer: allocated %lu bytes", (unsigned long)alloc_size);
}

// ---------------------------------------------------------------------------
// nqd_decode_region — QuickDraw Region to 1-byte-per-cell bitmap
//
// Takes a Mac address pointing to a QuickDraw Region, the destination rect
// dimensions (for coordinate mapping), and an output buffer pointer + size.
// Returns true on success. The output bitmap is 1 byte per cell where 1 means
// "inside region" and 0 means "outside".
//
// For mask_width: this is either width_bytes (Boolean modes) or width_pixels
// (arithmetic modes). The caller provides the correct stride.
// ---------------------------------------------------------------------------

static bool nqd_decode_region(uint32 rgn_addr, int dest_width, int dest_height,
                               uint8_t *out_mask, NSUInteger mask_size)
{
    if (rgn_addr == 0) {
        NQD_ERR("nqd_decode_region: null region address");
        return false;
    }

    // Bounds-check the region header (10 bytes minimum)
    uint16 rgnSize = ReadMacInt16(rgn_addr);
    if (rgnSize < 10) {
        NQD_ERR("nqd_decode_region: invalid rgnSize %u (< 10)", rgnSize);
        return false;
    }

    int16 bbox_top    = (int16)ReadMacInt16(rgn_addr + 2);
    int16 bbox_left   = (int16)ReadMacInt16(rgn_addr + 4);
    int16 bbox_bottom = (int16)ReadMacInt16(rgn_addr + 6);
    int16 bbox_right  = (int16)ReadMacInt16(rgn_addr + 8);

    if (bbox_top >= bbox_bottom || bbox_left >= bbox_right) {
        NQD_ERR("nqd_decode_region: invalid bbox (%d,%d)-(%d,%d)",
                bbox_top, bbox_left, bbox_bottom, bbox_right);
        return false;
    }

    int rgn_width  = bbox_right - bbox_left;
    int rgn_height = bbox_bottom - bbox_top;

    NQD_LOG("nqd_decode_region: rgnSize=%u bbox=(%d,%d,%d,%d) dest=%dx%d",
            rgnSize, bbox_top, bbox_left, bbox_bottom, bbox_right,
            dest_width, dest_height);

    // Ensure output buffer is large enough
    NSUInteger needed = (NSUInteger)(dest_width * dest_height);
    if (needed > mask_size) {
        NQD_ERR("nqd_decode_region: mask_size %lu < needed %lu",
                (unsigned long)mask_size, (unsigned long)needed);
        return false;
    }

    // Rectangular region (rgnSize == 10): fill all 1s (region = bbox = dest rect)
    if (rgnSize == 10) {
        NQD_LOG("nqd_decode_region: rectangular region — filling all 1s");
        memset(out_mask, 1, needed);
        return true;
    }

    // Complex region: decode RLE scanline data
    // Initialize mask to all 0s; we'll set 1s for inside pixels
    memset(out_mask, 0, needed);

    // Scanline state: tracks which columns are "inside" the region.
    // The region scanline data works by inversion: each h-point toggles inside/outside.
    // State persists across scanlines (running state).
    int max_cols = rgn_width;
    if (max_cols <= 0 || max_cols > 16384) {
        NQD_ERR("nqd_decode_region: unreasonable rgn_width %d", max_cols);
        return false;
    }

    // Running state: one bool per column of the region bbox
    std::vector<uint8_t> col_state(max_cols, 0);

    uint32 offset = rgn_addr + 10;  // Start of scanline data
    uint32 rgn_end = rgn_addr + rgnSize;
    int prev_v = bbox_top;
    int inversion_count = 0;

    while (offset + 2 <= rgn_end) {
        int16 v_coord = (int16)ReadMacInt16(offset);
        offset += 2;

        // End sentinel
        if (v_coord == 0x7FFF) break;

        // Fill mask rows from prev_v to v_coord using current col_state
        for (int row = prev_v; row < v_coord; row++) {
            int mask_row = row - bbox_top;
            if (mask_row < 0 || mask_row >= dest_height) continue;
            for (int c = 0; c < max_cols && c < dest_width; c++) {
                if (col_state[c]) {
                    out_mask[mask_row * dest_width + c] = 1;
                }
            }
        }

        // Read horizontal inversion points for this scanline
        while (offset + 2 <= rgn_end) {
            int16 h_point = (int16)ReadMacInt16(offset);
            offset += 2;

            if (h_point == 0x7FFF) break;  // End of h-points for this scanline

            // Toggle all columns from h_point to the next h_point
            int h_col = h_point - bbox_left;
            if (h_col >= 0 && h_col < max_cols) {
                // Toggle from h_col onward (next h_point will stop the toggle)
                // Actually, inversion points work in pairs: toggle from h_col to next h_point
                // But the way QuickDraw encodes it, each point just toggles the running state
                // for that column onward. Let's apply it correctly:
                // Read the next h_point to know the range end
                // Actually, QD region points toggle the inside/outside state at each x coordinate.
                // They come in pairs and toggle entire ranges.
                for (int c = h_col; c < max_cols; c++) {
                    col_state[c] = !col_state[c];
                }
                inversion_count++;
            }
        }

        prev_v = v_coord;
    }

    // Fill remaining rows from prev_v to bbox_bottom
    for (int row = prev_v; row < bbox_bottom; row++) {
        int mask_row = row - bbox_top;
        if (mask_row < 0 || mask_row >= dest_height) continue;
        for (int c = 0; c < max_cols && c < dest_width; c++) {
            if (col_state[c]) {
                out_mask[mask_row * dest_width + c] = 1;
            }
        }
    }

    NQD_LOG("nqd_decode_region: complex region decoded, %d inversions", inversion_count);
    return true;
}

// ---------------------------------------------------------------------------
// NQDMetalBltMask — bitblt with mask via Metal compute
//
// Reads accl_params + mask region from Mac memory. Decodes region to bitmap,
// dispatches through existing nqd_bitblt pipeline with mask buffer at index 2.
// ---------------------------------------------------------------------------

void NQDMetalBltMask(uint32 p)
{
    if (!nqd_metal_available) return;

    // Flush any pending batch — mask ops use the shared mask buffer which
    // may be overwritten between calls, so we need serial execution.
    NQDMetalFlush();

    // Extract bitblt parameters (same as NQDMetalBitblt)
    int16 src_X  = (int16)ReadMacInt16(p + NQD_acclSrcRect + 2) - (int16)ReadMacInt16(p + NQD_acclSrcBoundsRect + 2);
    int16 src_Y  = (int16)ReadMacInt16(p + NQD_acclSrcRect + 0) - (int16)ReadMacInt16(p + NQD_acclSrcBoundsRect + 0);
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 src_pixel_size = ReadMacInt32(p + NQD_acclSrcPixelSize);
    int bpp = nqd_bytes_per_pixel(src_pixel_size);
    if (src_pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    uint32 width_bytes = nqd_packed_width_bytes(width, src_pixel_size);
    uint32 width_pixels = (uint32)width;

    uint32 src_base = ReadMacInt32(p + NQD_acclSrcBaseAddr);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);
    int32 src_row_bytes = (int32)ReadMacInt32(p + NQD_acclSrcRowBytes);
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);

    uint32_t transfer_mode = ReadMacInt32(p + NQD_acclTransferMode);
    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t hilite_color = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;

    bool pixel_mode = nqd_is_pixel_mode(transfer_mode);

    // Read mask region address from accl_params
    uint32 mask_rgn_addr = ReadMacInt32(p + NQD_acclMaskAddr);
    NQD_LOG("NQDMetalBltMask: mask_rgn_addr=0x%08x mode=%d %dx%d bpp=%d bits_per_pixel=%u",
            mask_rgn_addr, transfer_mode, width, height, bpp, src_pixel_size);

    // Determine mask stride based on mode
    uint32_t mask_stride = pixel_mode ? width_pixels : width_bytes;
    NSUInteger mask_size = (NSUInteger)(mask_stride * (uint32)height);

    // Allocate mask bitmap on CPU, decode region
    std::vector<uint8_t> cpu_mask(mask_size, 0);
    if (!nqd_decode_region(mask_rgn_addr, (int)mask_stride, (int)height,
                            cpu_mask.data(), mask_size)) {
        NQD_ERR("NQDMetalBltMask: region decode failed, skipping");
        return;
    }

    // Copy mask into GPU buffer
    nqd_ensure_mask_buffer(mask_size);
    memcpy([nqd_mask_buffer contents], cpu_mask.data(), mask_size);

    // Compute offsets
    uint8 *ram_base = nqd_ram_base;
    uint8 *src_ptr = Mac2HostAddr(src_base) + (src_Y * abs(src_row_bytes)) + nqd_packed_byte_offset(src_X, src_pixel_size);
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * abs(dest_row_bytes)) + nqd_packed_byte_offset(dest_X, src_pixel_size);
    uint32_t src_offset = (uint32_t)(src_ptr - ram_base);
    uint32_t dst_offset = (uint32_t)(dst_ptr - ram_base);

    NQDBitbltUniforms uniforms;
    uniforms.src_offset    = src_offset;
    uniforms.dst_offset    = dst_offset;
    uniforms.src_row_bytes = abs(src_row_bytes);
    uniforms.dst_row_bytes = abs(dest_row_bytes);
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = hilite_color;
    uniforms.mask_enabled  = 1;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = mask_stride;
    uniforms.bits_per_pixel = src_pixel_size;

    NSUInteger total_threads = (pixel_mode && src_pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    // Mask ops dispatch into a fresh batch (we flushed above) and immediately
    // flush again, since the next mask call may overwrite nqd_mask_buffer.
    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_bitblt_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_mask_buffer offset:0 atIndex:2];

    NSUInteger threadgroup_size = nqd_bitblt_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    NQDMetalFlush();  // must complete before mask buffer is reused
}

// ---------------------------------------------------------------------------
// NQDMetalFillMask — fill rect with mask via Metal compute
//
// Reads accl_params + mask region from Mac memory. Decodes region to bitmap,
// dispatches through existing nqd_fillrect pipeline with mask buffer at index 2.
// ---------------------------------------------------------------------------

void NQDMetalFillMask(uint32 p)
{
    if (!nqd_metal_available) return;

    // Flush any pending batch — mask ops use the shared mask buffer
    NQDMetalFlush();

    // Extract fillrect parameters (same as NQDMetalFillRect)
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 pixel_size = ReadMacInt32(p + NQD_acclDestPixelSize);
    int bpp = nqd_bytes_per_pixel(pixel_size);
    if (pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);

    uint32_t transfer_mode = ReadMacInt32(p + NQD_acclTransferMode);
    uint32_t pen_mode = ReadMacInt32(p + NQD_acclPenMode);
    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t fore_pen_native = ReadMacInt32(p + NQD_acclForePen);
    uint32_t back_pen_native = ReadMacInt32(p + NQD_acclBackPen);
    uint32_t fill_color = (pen_mode == 8) ? fore_pen_native : back_pen_native;

    uint32 width_bytes = nqd_packed_width_bytes(width, pixel_size);
    uint32 width_pixels = (uint32)width;

    uint32_t hilite_color = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;
    bool pixel_mode = nqd_is_pixel_mode(transfer_mode);

    // Read mask region address from accl_params
    uint32 mask_rgn_addr = ReadMacInt32(p + NQD_acclMaskAddr);
    NQD_LOG("NQDMetalFillMask: mask_rgn_addr=0x%08x mode=%d %dx%d bpp=%d bits_per_pixel=%u",
            mask_rgn_addr, transfer_mode, width, height, bpp, pixel_size);

    // Determine mask stride based on mode
    uint32_t mask_stride = pixel_mode ? width_pixels : width_bytes;
    NSUInteger mask_size = (NSUInteger)(mask_stride * (uint32)height);

    // Allocate mask bitmap on CPU, decode region
    std::vector<uint8_t> cpu_mask(mask_size, 0);
    if (!nqd_decode_region(mask_rgn_addr, (int)mask_stride, (int)height,
                            cpu_mask.data(), mask_size)) {
        NQD_ERR("NQDMetalFillMask: region decode failed, skipping");
        return;
    }

    // Copy mask into GPU buffer
    nqd_ensure_mask_buffer(mask_size);
    memcpy([nqd_mask_buffer contents], cpu_mask.data(), mask_size);

    // Compute offset
    uint8 *ram_base = nqd_ram_base;
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + nqd_packed_byte_offset(dest_X, pixel_size);
    uint32_t dst_offset = (uint32_t)(dst_ptr - ram_base);

    NQDFillRectUniforms uniforms;
    uniforms.dst_offset    = dst_offset;
    uniforms.row_bytes     = dest_row_bytes;
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.fill_color    = fill_color;
    uniforms.bpp           = (uint32_t)bpp;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = hilite_color;
    uniforms.mask_enabled  = 1;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = mask_stride;
    uniforms.bits_per_pixel = pixel_size;

    NSUInteger total_threads = (pixel_mode && pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_fillrect_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_mask_buffer offset:0 atIndex:2];

    NSUInteger threadgroup_size = nqd_fillrect_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    NQDMetalFlush();  // must complete before mask buffer is reused
}

// ---------------------------------------------------------------------------
// NQDMetalCleanup — release all Metal resources
// ---------------------------------------------------------------------------

void NQDMetalCleanup(void)
{
    NQD_LOG("NQDMetalCleanup: releasing Metal resources");

    // Flush any pending batch before releasing resources
    NQDMetalFlush();

    nqd_metal_available = false;
    nqd_ram_base = nullptr;
    nqd_ram_size = 0;
    nqd_mask_buffer = nil;
    nqd_mask_buffer_size = 0;
    nqd_ram_buffer = nil;
    nqd_fillrect_pipeline = nil;
    nqd_bitblt_pipeline = nil;
    nqd_queue = nil;
    nqd_device = nil;

    NQD_LOG("NQDMetalCleanup: done");
}

// ---------------------------------------------------------------------------
// NQDMetalBitblt — bitblt via Metal compute for all transfer modes
//
// Reads accl_params from Mac memory at address p. Dispatches the nqd_bitblt
// compute kernel. For overlapping blits (negative row_bytes), rows are
// dispatched one at a time in reverse order to ensure correctness.
//
// Boolean modes (0-7): per-byte dispatch (width_bytes * height threads)
// Arithmetic modes (32-39) + hilite (50): per-pixel dispatch (width_pixels * height)
// ---------------------------------------------------------------------------

void NQDMetalBitblt(uint32 p)
{
    if (!nqd_metal_available) return;

    // Extract parameters from accl_params in Mac memory
    int16 src_X  = (int16)ReadMacInt16(p + NQD_acclSrcRect + 2) - (int16)ReadMacInt16(p + NQD_acclSrcBoundsRect + 2);
    int16 src_Y  = (int16)ReadMacInt16(p + NQD_acclSrcRect + 0) - (int16)ReadMacInt16(p + NQD_acclSrcBoundsRect + 0);
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    // Edge case: nothing to blit
    if (width <= 0 || height <= 0) return;

    uint32 src_pixel_size  = ReadMacInt32(p + NQD_acclSrcPixelSize);
    int bpp = nqd_bytes_per_pixel(src_pixel_size);
    if (src_pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    uint32 width_bytes = nqd_packed_width_bytes(width, src_pixel_size);
    uint32 width_pixels = (uint32)width;

    uint32 src_base  = ReadMacInt32(p + NQD_acclSrcBaseAddr);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);
    int32 src_row_bytes  = (int32)ReadMacInt32(p + NQD_acclSrcRowBytes);
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);

    // Read transfer mode and pen colors from accl_params
    uint32_t transfer_mode = ReadMacInt32(p + NQD_acclTransferMode);

    NQD_LOG("NQDMetalBitblt: src=(%d,%d) dst=(%d,%d) %dx%d bpp=%d bits_per_pixel=%u mode=%d src_rb=%d dst_rb=%d",
            src_X, src_Y, dest_X, dest_Y, width, height, bpp, src_pixel_size, transfer_mode, src_row_bytes, dest_row_bytes);

    // -----------------------------------------------------------------------
    // CPU fast path for small operations and simple modes
    //
    // For srcCopy (mode 0) on standard depths (>= 8bpp), memmove is faster
    // than any Metal path for small rects. For backward blits (negative
    // row_bytes), CPU is always preferred since Metal would need per-row
    // serialization or a temp buffer.
    //
    // All Boolean modes (0-7) get CPU fast paths for small rects — the
    // per-byte logic is trivial and doesn't benefit from GPU parallelism
    // at these sizes.
    // -----------------------------------------------------------------------

    int total_pixels = (int)width * (int)height;

    if (src_row_bytes < 0) {
        // Backward blit — always use CPU. Metal per-row dispatch was the
        // worst case: N command buffers for N rows. CPU memmove is trivial.
        NQDMetalFlush();  // ensure any pending GPU writes are visible to CPU
        int32 abs_src_rb = -src_row_bytes;
        int32 abs_dst_rb = -dest_row_bytes;
        uint8 *src_start = Mac2HostAddr(src_base) + ((src_Y + height - 1) * abs_src_rb) + nqd_packed_byte_offset(src_X, src_pixel_size);
        uint8 *dst_start = Mac2HostAddr(dest_base) + ((dest_Y + height - 1) * abs_dst_rb) + nqd_packed_byte_offset(dest_X, src_pixel_size);
        for (int row = height - 1; row >= 0; row--) {
            memmove(dst_start, src_start, width_bytes);
            src_start -= abs_src_rb;
            dst_start -= abs_dst_rb;
        }
        return;
    }

    if (transfer_mode <= 7 && src_pixel_size >= 8 && total_pixels < NQD_CPU_THRESHOLD_PIXELS) {
        // Boolean bitblt modes, small rect, standard depth — CPU is faster.
        NQDMetalFlush();  // ensure any pending GPU writes are visible to CPU
        uint8 *src_ptr = Mac2HostAddr(src_base) + (src_Y * src_row_bytes) + (src_X * bpp);
        uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + (dest_X * bpp);
        int op_bytes = width * bpp;
        if (transfer_mode == 0) {
            // srcCopy — plain memmove
            for (int row = 0; row < height; row++) {
                memmove(dst_ptr, src_ptr, op_bytes);
                src_ptr += src_row_bytes;
                dst_ptr += dest_row_bytes;
            }
        } else {
            // Modes 1-7: per-byte Boolean ops
            for (int row = 0; row < height; row++) {
                for (int b = 0; b < op_bytes; b++) {
                    uint8_t s = src_ptr[b];
                    uint8_t d = dst_ptr[b];
                    switch (transfer_mode) {
                        case 1: dst_ptr[b] = s | d;      break; // srcOr
                        case 2: dst_ptr[b] = s ^ d;      break; // srcXor
                        case 3: dst_ptr[b] = (~s) & d;   break; // srcBic
                        case 4: dst_ptr[b] = ~s;          break; // notSrcCopy
                        case 5: dst_ptr[b] = (~s) | d;   break; // notSrcOr
                        case 6: dst_ptr[b] = (~s) ^ d;   break; // notSrcXor
                        case 7: dst_ptr[b] = s & d;       break; // notSrcBic
                    }
                }
                src_ptr += src_row_bytes;
                dst_ptr += dest_row_bytes;
            }
        }
        return;
    }

    // -----------------------------------------------------------------------
    // Metal batched path — forward blit, single dispatch covering all rows
    // -----------------------------------------------------------------------

    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t hilite_color = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;
    bool pixel_mode = nqd_is_pixel_mode(transfer_mode);

    uint8 *ram_base = nqd_ram_base;
    uint8 *src_ptr = Mac2HostAddr(src_base) + (src_Y * src_row_bytes) + nqd_packed_byte_offset(src_X, src_pixel_size);
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + nqd_packed_byte_offset(dest_X, src_pixel_size);

    NQDBitbltUniforms uniforms;
    uniforms.src_offset    = (uint32_t)(src_ptr - ram_base);
    uniforms.dst_offset    = (uint32_t)(dst_ptr - ram_base);
    uniforms.src_row_bytes = src_row_bytes;
    uniforms.dst_row_bytes = dest_row_bytes;
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = hilite_color;
    uniforms.mask_enabled  = 0;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = 0;
    uniforms.bits_per_pixel = src_pixel_size;

    NSUInteger total_threads = (pixel_mode && src_pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_bitblt_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:2];  // dummy mask buffer (mask_enabled=0)

    NSUInteger threadgroup_size = nqd_bitblt_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
}

// ---------------------------------------------------------------------------
// NQDMetalFillRect — fill rect via Metal compute (all pen modes)
//
// Reads accl_params from Mac memory at address p. Dispatches the nqd_fillrect
// compute kernel. For Boolean modes (8-15), dispatches per-byte threads.
// For arithmetic modes (32-39) and hilite (50), dispatches per-pixel threads.
// ---------------------------------------------------------------------------

void NQDMetalFillRect(uint32 p)
{
    if (!nqd_metal_available) return;

    // Extract parameters from accl_params
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 pixel_size = ReadMacInt32(p + NQD_acclDestPixelSize);
    int bpp = nqd_bytes_per_pixel(pixel_size);
    if (pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);

    // Read transfer mode and pen colors
    uint32_t transfer_mode = ReadMacInt32(p + NQD_acclTransferMode);
    uint32_t pen_mode = ReadMacInt32(p + NQD_acclPenMode);

    NQD_LOG("NQDMetalFillRect: dst=(%d,%d) %dx%d bpp=%d bits_per_pixel=%u transfer_mode=%d mode=%d rb=%d",
            dest_X, dest_Y, width, height, bpp, pixel_size, transfer_mode, pen_mode, dest_row_bytes);

    // -----------------------------------------------------------------------
    // CPU fast path for small Boolean fills on standard depths
    //
    // Boolean fill modes (8-15) do per-byte operations on a repeating fill
    // pattern. For small rects, a tight CPU loop is much faster than Metal.
    // -----------------------------------------------------------------------

    int total_pixels = (int)width * (int)height;

    if (transfer_mode >= 8 && transfer_mode <= 15 && pixel_size >= 8 && total_pixels < NQD_CPU_THRESHOLD_PIXELS) {
        NQDMetalFlush();  // ensure any pending GPU writes are visible to CPU
        uint32_t color = htonl((pen_mode == 8) ? ReadMacInt32(p + NQD_acclForePen) : ReadMacInt32(p + NQD_acclBackPen));
        uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + (dest_X * bpp);
        int fill_bytes = width * bpp;

        if (transfer_mode == 8) {
            // patCopy — just fill
            if (bpp == 1) {
                for (int row = 0; row < height; row++) {
                    memset(dst_ptr, (uint8_t)(color & 0xFF), fill_bytes);
                    dst_ptr += dest_row_bytes;
                }
            } else if (bpp == 2) {
                uint16_t c16 = (uint16_t)(color & 0xFFFF);
                for (int row = 0; row < height; row++) {
                    uint16_t *p16 = (uint16_t *)dst_ptr;
                    for (int col = 0; col < width; col++) p16[col] = c16;
                    dst_ptr += dest_row_bytes;
                }
            } else {
                for (int row = 0; row < height; row++) {
                    uint32_t *p32 = (uint32_t *)dst_ptr;
                    for (int col = 0; col < width; col++) p32[col] = color;
                    dst_ptr += dest_row_bytes;
                }
            }
        } else {
            // Modes 9-15: per-byte Boolean ops with fill pattern
            for (int row = 0; row < height; row++) {
                for (int b = 0; b < fill_bytes; b++) {
                    uint8_t byte_in_pixel = b % bpp;
                    uint8_t shift = (3 - ((4 - bpp) + byte_in_pixel)) * 8;
                    uint8_t fill = (uint8_t)((color >> shift) & 0xFF);
                    uint8_t d = dst_ptr[b];
                    switch (transfer_mode) {
                        case 9:  dst_ptr[b] = fill | d;      break; // patOr
                        case 10: dst_ptr[b] = fill ^ d;      break; // patXor
                        case 11: dst_ptr[b] = (~fill) & d;   break; // patBic
                        case 12: dst_ptr[b] = ~fill;          break; // notPatCopy
                        case 13: dst_ptr[b] = (~fill) | d;   break; // notPatOr
                        case 14: dst_ptr[b] = (~fill) ^ d;   break; // notPatXor
                        case 15: dst_ptr[b] = fill & d;       break; // notPatBic
                    }
                }
                dst_ptr += dest_row_bytes;
            }
        }
        return;
    }

    // -----------------------------------------------------------------------
    // Metal batched path
    // -----------------------------------------------------------------------

    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t fore_pen_native = ReadMacInt32(p + NQD_acclForePen);
    uint32_t back_pen_native = ReadMacInt32(p + NQD_acclBackPen);
    uint32_t fill_color = (pen_mode == 8) ? fore_pen_native : back_pen_native;

    uint32 width_bytes = nqd_packed_width_bytes(width, pixel_size);
    uint32 width_pixels = (uint32)width;

    uint32_t hilite_color = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;
    bool pixel_mode = nqd_is_pixel_mode(transfer_mode);

    uint8 *ram_base = nqd_ram_base;
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + nqd_packed_byte_offset(dest_X, pixel_size);
    uint32_t dst_offset = (uint32_t)(dst_ptr - ram_base);

    NQDFillRectUniforms uniforms;
    uniforms.dst_offset    = dst_offset;
    uniforms.row_bytes     = dest_row_bytes;
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.fill_color    = fill_color;
    uniforms.bpp           = (uint32_t)bpp;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = hilite_color;
    uniforms.mask_enabled  = 0;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = 0;
    uniforms.bits_per_pixel = pixel_size;

    NSUInteger total_threads = (pixel_mode && pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_fillrect_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:2];  // dummy mask buffer (mask_enabled=0)

    NSUInteger threadgroup_size = nqd_fillrect_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
}

// ---------------------------------------------------------------------------
// NQDMetalInvertRect — invert rect via Metal compute
//
// Delegates to the fillrect kernel with transfer_mode=10 (patXor). The XOR
// of fill_color with each dest byte inverts all bits (equivalent to the old
// dedicated nqd_invert kernel which XOR'd with 0xFF).
//
// Mac OS dispatches invert through a separate thunk entry, so we keep this
// function as a thin wrapper that sets up the right fill parameters.
// ---------------------------------------------------------------------------

void NQDMetalInvertRect(uint32 p)
{
    if (!nqd_metal_available) return;

    // Extract parameters from accl_params
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 pixel_size = ReadMacInt32(p + NQD_acclDestPixelSize);
    int bpp = nqd_bytes_per_pixel(pixel_size);
    if (pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);

    uint32 width_bytes = nqd_packed_width_bytes(width, pixel_size);
    uint32 width_pixels = (uint32)width;

    NQD_LOG("NQDMetalInvertRect: dst=(%d,%d) %dx%d bpp=%d bits_per_pixel=%u rb=%d",
            dest_X, dest_Y, width, height, bpp, pixel_size, dest_row_bytes);

    // -----------------------------------------------------------------------
    // CPU fast path for small inverts on standard depths
    //
    // Invert is just XOR with 0xFF per byte. A tight CPU loop is much faster
    // than Metal for small rects, and competitive even for medium ones since
    // the operation is purely sequential memory access.
    // -----------------------------------------------------------------------

    int total_pixels = (int)width * (int)height;

    if (pixel_size >= 8 && total_pixels < NQD_CPU_THRESHOLD_PIXELS) {
        NQDMetalFlush();  // ensure any pending GPU writes are visible to CPU
        uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + (dest_X * bpp);
        int invert_bytes = width * bpp;
        for (int row = 0; row < height; row++) {
            // XOR 8 bytes at a time for throughput
            uint8 *p8 = dst_ptr;
            int remaining = invert_bytes;
            while (remaining >= 8) {
                *(uint64_t *)p8 ^= 0xFFFFFFFFFFFFFFFFULL;
                p8 += 8;
                remaining -= 8;
            }
            while (remaining > 0) {
                *p8 ^= 0xFF;
                p8++;
                remaining--;
            }
            dst_ptr += dest_row_bytes;
        }
        return;
    }

    // -----------------------------------------------------------------------
    // Metal batched path — patXor with fill_color=0xFFFFFFFF
    // -----------------------------------------------------------------------

    uint32_t transfer_mode = 10;  // patXor
    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t fill_color = 0xFFFFFFFF;

    uint8 *ram_base = nqd_ram_base;
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + nqd_packed_byte_offset(dest_X, pixel_size);
    uint32_t dst_offset = (uint32_t)(dst_ptr - ram_base);

    NQDFillRectUniforms uniforms;
    uniforms.dst_offset    = dst_offset;
    uniforms.row_bytes     = dest_row_bytes;
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.fill_color    = fill_color;
    uniforms.bpp           = (uint32_t)bpp;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = 0;
    uniforms.mask_enabled  = 0;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = 0;
    uniforms.bits_per_pixel = pixel_size;

    // patXor is a Boolean mode → per-byte dispatch
    NSUInteger total_threads = (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_fillrect_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:2];  // dummy mask buffer (mask_enabled=0)

    NSUInteger threadgroup_size = nqd_fillrect_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
}
