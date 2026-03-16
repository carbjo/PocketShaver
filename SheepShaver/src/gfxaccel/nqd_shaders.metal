/*
 *  nqd_shaders.metal - Metal compute kernels for NQD 2D acceleration
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Compute kernels for NQD bitblt (srcCopy), fillrect, and invrect.
 *  The buffer parameter is the Mac RAM shared buffer — src and dest are
 *  addressed by byte offsets within it.
 */

#include <metal_stdlib>
using namespace metal;

// Uniform struct — must match NQDBitbltUniforms in nqd_metal_renderer.mm
struct NQDBitbltUniforms {
    uint src_offset;
    uint dst_offset;
    int  src_row_bytes;
    int  dst_row_bytes;
    uint width_bytes;
    uint height;
    uint transfer_mode;
    uint pixel_size;     // bytes per pixel (1, 2, or 4)
    uint width_pixels;   // width in pixels (used for arithmetic/hilite modes)
    uint fore_pen;       // foreground pen color (big-endian packed, from accl_params)
    uint back_pen;       // background pen color (big-endian packed, from accl_params)
    uint hilite_color;   // HiliteRGB packed to pixel depth (from Mac low-memory 0x0DA0)
    uint mask_enabled;   // 1 = mask gating active, 0 = no mask
    uint mask_offset;    // byte offset into mask_buffer where mask data starts
    uint mask_stride;    // mask row stride (width_bytes for Boolean, width_pixels for arithmetic)
    uint bits_per_pixel; // raw pixel depth in bits (1, 2, 4, 8, 16, or 32) — for packed pixel support
};

// Uniform struct — must match NQDFillRectUniforms in nqd_metal_renderer.mm
struct NQDFillRectUniforms {
    uint dst_offset;
    int  row_bytes;
    uint width_bytes;
    uint height;
    uint fill_color;     // 32-bit fill pattern (fore or back pen, htonl'd)
    uint bpp;            // bytes per pixel (1, 2, or 4)
    uint transfer_mode;  // pen mode: 8-15 (Boolean), 32-39 (arithmetic), 50 (hilite)
    uint pixel_size;     // bytes per pixel (same as bpp; kept for naming consistency with bitblt)
    uint width_pixels;   // width in pixels (used for arithmetic/hilite per-pixel dispatch)
    uint fore_pen;       // foreground pen color (big-endian packed)
    uint back_pen;       // background pen color (big-endian packed)
    uint hilite_color;   // HiliteRGB packed to pixel depth
    uint mask_enabled;   // 1 = mask gating active, 0 = no mask
    uint mask_offset;    // byte offset into mask_buffer where mask data starts
    uint mask_stride;    // mask row stride (width_bytes for Boolean, width_pixels for arithmetic)
    uint bits_per_pixel; // raw pixel depth in bits (1, 2, 4, 8, 16, or 32) — for packed pixel support
};

// ---------------------------------------------------------------------------
// Big-endian pixel read/write and component extraction helpers
//
// Mac framebuffer stores pixels in big-endian byte order:
// - 8bpp:  single byte (index value)
// - 16bpp: [HI][LO] bytes → 1-5-5-5 ARGB big-endian
// - 32bpp: [A][R][G][B] bytes
//
// We must NOT use pointer casts (e.g. *(uint16_t*)) because Metal on ARM
// reads in little-endian, which would silently reverse byte order.
// Instead, manually assemble multi-byte values from individual bytes.
// ---------------------------------------------------------------------------

// Read a pixel from the buffer at byte address addr, returning it as a uint32.
// The returned value preserves big-endian byte layout in its bits so that
// whole-pixel comparisons (transparent, hilite) match the pen colors passed
// from the host (which are also in big-endian byte order via htonl).
static inline uint nqd_read_pixel(device uint8_t *buffer, uint addr, uint bpp)
{
    if (bpp == 1) {
        return uint(buffer[addr]);
    } else if (bpp == 2) {
        // Big-endian 16-bit: HI byte at addr, LO byte at addr+1
        return (uint(buffer[addr]) << 8) | uint(buffer[addr + 1]);
    } else {
        // Big-endian 32-bit: [A][R][G][B]
        return (uint(buffer[addr]) << 24) | (uint(buffer[addr + 1]) << 16) |
               (uint(buffer[addr + 2]) << 8) | uint(buffer[addr + 3]);
    }
}

// Write a pixel value back to the buffer in big-endian byte order.
static inline void nqd_write_pixel(device uint8_t *buffer, uint addr, uint bpp, uint value)
{
    if (bpp == 1) {
        buffer[addr] = uint8_t(value & 0xFF);
    } else if (bpp == 2) {
        buffer[addr]     = uint8_t((value >> 8) & 0xFF);
        buffer[addr + 1] = uint8_t(value & 0xFF);
    } else {
        buffer[addr]     = uint8_t((value >> 24) & 0xFF);
        buffer[addr + 1] = uint8_t((value >> 16) & 0xFF);
        buffer[addr + 2] = uint8_t((value >> 8) & 0xFF);
        buffer[addr + 3] = uint8_t(value & 0xFF);
    }
}

// ---------------------------------------------------------------------------
// Packed (sub-byte) pixel read/write helpers for 1/2/4-bit depths
//
// Mac QuickDraw uses MSB-first bit order within each byte:
// - 1bpp: bit 7 = pixel 0 (leftmost), bit 0 = pixel 7
// - 2bpp: bits 7-6 = pixel 0, bits 5-4 = pixel 1, bits 3-2 = pixel 2, bits 1-0 = pixel 3
// - 4bpp: bits 7-4 = pixel 0 (high nibble), bits 3-0 = pixel 1 (low nibble)
//
// pixel_index_in_byte ranges from 0 to (8/bits_per_pixel - 1).
// ---------------------------------------------------------------------------

// Read a single sub-byte pixel value from a packed byte.
static inline uint nqd_read_packed_pixel(device uint8_t *buffer, uint byte_addr,
                                          uint pixel_index_in_byte, uint bits_per_pixel)
{
    uint8_t byte_val = buffer[byte_addr];
    if (bits_per_pixel == 1) {
        uint shift = 7 - pixel_index_in_byte;
        return (uint(byte_val) >> shift) & 0x1;
    } else if (bits_per_pixel == 2) {
        uint shift = (3 - pixel_index_in_byte) * 2;
        return (uint(byte_val) >> shift) & 0x3;
    } else { // 4bpp
        uint shift = (1 - pixel_index_in_byte) * 4;
        return (uint(byte_val) >> shift) & 0xF;
    }
}

// Write a single sub-byte pixel value into a packed byte (read-modify-write).
static inline void nqd_write_packed_pixel(device uint8_t *buffer, uint byte_addr,
                                           uint pixel_index_in_byte, uint bits_per_pixel,
                                           uint value)
{
    uint8_t byte_val = buffer[byte_addr];
    if (bits_per_pixel == 1) {
        uint shift = 7 - pixel_index_in_byte;
        uint mask = 0x1 << shift;
        byte_val = (byte_val & ~uint8_t(mask)) | uint8_t((value & 0x1) << shift);
    } else if (bits_per_pixel == 2) {
        uint shift = (3 - pixel_index_in_byte) * 2;
        uint mask = 0x3 << shift;
        byte_val = (byte_val & ~uint8_t(mask)) | uint8_t((value & 0x3) << shift);
    } else { // 4bpp
        uint shift = (1 - pixel_index_in_byte) * 4;
        uint mask = 0xF << shift;
        byte_val = (byte_val & ~uint8_t(mask)) | uint8_t((value & 0xF) << shift);
    }
    buffer[byte_addr] = byte_val;
}

// Extract pixel components into a uint4 (r, g, b, a) for arithmetic operations.
// Components are normalized to their per-depth max range:
// - 1bpp:  single value in r (0-1), g=b=a=0
// - 2bpp:  single value in r (0-3), g=b=a=0
// - 4bpp:  single value in r (0-15), g=b=a=0
// - 8bpp:  single value in r (0-255), g=b=a=0
// - 16bpp: 5-5-5 → r,g,b each 0-31; a = top bit (0 or 1)
// - 32bpp: A,R,G,B each 0-255
// bits_per_pixel_val: raw bits (1,2,4,8,16,32). bpp: bytes per pixel (1,2,4).
static inline uint4 nqd_extract_components(uint pixel, uint bpp, uint bits_per_pixel_val)
{
    if (bits_per_pixel_val < 8) {
        // Packed sub-byte: pixel is already the raw index value
        return uint4(pixel, 0, 0, 0);
    }
    if (bpp == 1) {
        return uint4(pixel & 0xFF, 0, 0, 0);
    } else if (bpp == 2) {
        // 16-bit big-endian 1-5-5-5 ARGB: bit layout in our uint16 value:
        // bit 15 = alpha, bits 14-10 = R, bits 9-5 = G, bits 4-0 = B
        uint a = (pixel >> 15) & 0x1;
        uint r = (pixel >> 10) & 0x1F;
        uint g = (pixel >> 5)  & 0x1F;
        uint b = pixel & 0x1F;
        return uint4(r, g, b, a);
    } else {
        // 32-bit ARGB: [A][R][G][B] in big-endian → bits 31-24=A, 23-16=R, 15-8=G, 7-0=B
        uint a = (pixel >> 24) & 0xFF;
        uint r = (pixel >> 16) & 0xFF;
        uint g = (pixel >> 8)  & 0xFF;
        uint b = pixel & 0xFF;
        return uint4(r, g, b, a);
    }
}

// Pack components back into a pixel value (inverse of nqd_extract_components).
static inline uint nqd_pack_components(uint4 c, uint bpp, uint bits_per_pixel_val)
{
    if (bits_per_pixel_val < 8) {
        // Packed sub-byte: just the raw index value
        return c.x;
    }
    if (bpp == 1) {
        return c.x & 0xFF;
    } else if (bpp == 2) {
        return ((c.w & 0x1) << 15) | ((c.x & 0x1F) << 10) | ((c.y & 0x1F) << 5) | (c.z & 0x1F);
    } else {
        return ((c.w & 0xFF) << 24) | ((c.x & 0xFF) << 16) | ((c.y & 0xFF) << 8) | (c.z & 0xFF);
    }
}

// Component max value for the given depth (for saturation arithmetic).
static inline uint nqd_comp_max(uint bpp, uint bits_per_pixel_val)
{
    if (bits_per_pixel_val == 1) return 1;
    if (bits_per_pixel_val == 2) return 3;
    if (bits_per_pixel_val == 4) return 15;
    if (bpp == 2) return 31;   // 5-bit components
    return 255;                 // 8-bit components (8bpp and 32bpp)
}

// ---------------------------------------------------------------------------
// nqd_bitblt — bitblt compute kernel with all 17 transfer modes
//
// Boolean modes (0-7): per-byte operations. Thread gid ranges over
// width_bytes * height. Each thread processes one byte.
//
// Arithmetic modes (32-39) and hilite (50): per-pixel operations. Thread gid
// ranges over width_pixels * height. Each thread processes one complete pixel
// (1, 2, or 4 bytes) with component decomposition.
//
// The host dispatches the correct total thread count based on mode family:
// - Modes 0-7: total = width_bytes * height
// - Modes 32-39, 50: total = width_pixels * height
// ---------------------------------------------------------------------------

kernel void nqd_bitblt(device uint8_t *buffer        [[buffer(0)]],
                       constant NQDBitbltUniforms &u  [[buffer(1)]],
                       device uint8_t *mask_buffer    [[buffer(2)]],
                       uint gid                       [[thread_position_in_grid]])
{
    // --- Boolean modes (0-7): per-byte operations ---
    if (u.transfer_mode <= 7) {
        uint total = u.width_bytes * u.height;
        if (gid >= total) return;

        uint row = gid / u.width_bytes;
        uint col = gid % u.width_bytes;

        // Mask check for byte-mode: col is byte column, mask_stride is width_bytes
        if (u.mask_enabled) {
            uint mask_addr = u.mask_offset + row * u.mask_stride + col;
            if (mask_buffer[mask_addr] == 0) return;
        }

        uint src_addr = u.src_offset + row * uint(u.src_row_bytes) + col;
        uint dst_addr = u.dst_offset + row * uint(u.dst_row_bytes) + col;

        uint8_t src = buffer[src_addr];
        uint8_t dst = buffer[dst_addr];

        switch (u.transfer_mode) {
            case 0:  buffer[dst_addr] = src;              break;  // srcCopy
            case 1:  buffer[dst_addr] = src | dst;        break;  // srcOr
            case 2:  buffer[dst_addr] = src ^ dst;        break;  // srcXor
            case 3:  buffer[dst_addr] = (~src) & dst;     break;  // srcBic
            case 4:  buffer[dst_addr] = ~src;             break;  // notSrcCopy
            case 5:  buffer[dst_addr] = (~src) | dst;     break;  // notSrcOr
            case 6:  buffer[dst_addr] = (~src) ^ dst;     break;  // notSrcXor
            case 7:  buffer[dst_addr] = src & dst;        break;  // notSrcBic
            default: buffer[dst_addr] = src;              break;
        }
        return;
    }

    // --- Arithmetic modes (32-39) and hilite (50) ---
    // For packed depths (bits_per_pixel < 8), dispatch is per-byte with inner pixel loop.
    // For standard depths (>= 8), dispatch is per-pixel (one thread per pixel).

    if (u.bits_per_pixel < 8) {
        // --- Packed pixel arithmetic/hilite: per-byte dispatch with inner pixel loop ---
        uint packed_total = u.width_bytes * u.height;
        if (gid >= packed_total) return;

        uint p_row = gid / u.width_bytes;
        uint p_col = gid % u.width_bytes;  // byte column

        uint src_byte_addr = u.src_offset + p_row * uint(u.src_row_bytes) + p_col;
        uint dst_byte_addr = u.dst_offset + p_row * uint(u.dst_row_bytes) + p_col;

        uint pixels_per_byte = 8 / u.bits_per_pixel;
        uint bpp_local = u.bits_per_pixel;

        for (uint pi = 0; pi < pixels_per_byte; pi++) {
            // Mask check: compute pixel column for this sub-pixel
            if (u.mask_enabled) {
                uint pixel_col = p_col * pixels_per_byte + pi;
                uint mask_addr = u.mask_offset + p_row * u.mask_stride + pixel_col;
                if (mask_buffer[mask_addr] == 0) continue;
            }

            uint src_val = nqd_read_packed_pixel(buffer, src_byte_addr, pi, bpp_local);
            uint dst_val = nqd_read_packed_pixel(buffer, dst_byte_addr, pi, bpp_local);

            // Mode 36 (transparent): skip if src matches background
            if (u.transfer_mode == 36) {
                if (src_val != (u.back_pen & ((1u << bpp_local) - 1))) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, src_val);
                }
                continue;
            }

            // Mode 50 (hilite): swap back_pen ↔ hilite_color
            if (u.transfer_mode == 50) {
                uint bp = u.back_pen & ((1u << bpp_local) - 1);
                uint hc = u.hilite_color & ((1u << bpp_local) - 1);
                if (dst_val == bp) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, hc);
                } else if (dst_val == hc) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, bp);
                }
                continue;
            }

            // Arithmetic modes: per-component (single index value for packed)
            uint4 sc = nqd_extract_components(src_val, 1, bpp_local);
            uint4 dc = nqd_extract_components(dst_val, 1, bpp_local);
            uint cmax_p = nqd_comp_max(1, bpp_local);
            uint4 p_result;

            switch (u.transfer_mode) {
                case 32: p_result = (sc + dc) / 2; break;
                case 33: p_result = min(sc + dc, uint4(cmax_p, cmax_p, cmax_p, cmax_p)); break;
                case 34: p_result = min(sc + dc, uint4(cmax_p, cmax_p, cmax_p, cmax_p)); break;
                case 35:
                    p_result.x = (dc.x > sc.x) ? (dc.x - sc.x) : 0;
                    p_result.y = p_result.z = p_result.w = 0;
                    break;
                case 37: p_result = max(sc, dc); break;
                case 38:
                    p_result.x = (dc.x > sc.x) ? (dc.x - sc.x) : 0;
                    p_result.y = p_result.z = p_result.w = 0;
                    break;
                case 39: p_result = min(sc, dc); break;
                default: p_result = sc; break;
            }

            nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local,
                                   nqd_pack_components(p_result, 1, bpp_local));
        }
        return;
    }

    // --- Standard depths (>= 8 bpp): per-pixel operations ---
    uint total = u.width_pixels * u.height;
    if (gid >= total) return;

    uint bpp = u.pixel_size;
    uint row = gid / u.width_pixels;
    uint col = gid % u.width_pixels;

    // Mask check for pixel-mode: col is pixel column, mask_stride is width_pixels
    if (u.mask_enabled) {
        uint mask_addr = u.mask_offset + row * u.mask_stride + col;
        if (mask_buffer[mask_addr] == 0) return;
    }

    uint src_addr = u.src_offset + row * uint(u.src_row_bytes) + col * bpp;
    uint dst_addr = u.dst_offset + row * uint(u.dst_row_bytes) + col * bpp;

    uint src_pixel = nqd_read_pixel(buffer, src_addr, bpp);
    uint dst_pixel = nqd_read_pixel(buffer, dst_addr, bpp);

    // Mode 36 (transparent): skip write if src matches background
    if (u.transfer_mode == 36) {
        if (src_pixel != u.back_pen) {
            nqd_write_pixel(buffer, dst_addr, bpp, src_pixel);
        }
        return;
    }

    // Mode 50 (hilite): swap back_pen ↔ hilite_color in destination
    if (u.transfer_mode == 50) {
        if (dst_pixel == u.back_pen) {
            nqd_write_pixel(buffer, dst_addr, bpp, u.hilite_color);
        } else if (dst_pixel == u.hilite_color) {
            nqd_write_pixel(buffer, dst_addr, bpp, u.back_pen);
        }
        // else: leave dst unchanged
        return;
    }

    // Arithmetic modes (32-35, 37-39): per-component operations
    uint4 sc = nqd_extract_components(src_pixel, bpp, u.bits_per_pixel);
    uint4 dc = nqd_extract_components(dst_pixel, bpp, u.bits_per_pixel);
    uint cmax = nqd_comp_max(bpp, u.bits_per_pixel);
    uint4 result;

    switch (u.transfer_mode) {
        case 32: {  // blend — 50% weight default
            result = (sc + dc) / 2;
            break;
        }
        case 33: {  // addPin — add and clamp to max (white)
            result = min(sc + dc, uint4(cmax, cmax, cmax, cmax));
            break;
        }
        case 34: {  // addOver — add with saturation
            result = min(sc + dc, uint4(cmax, cmax, cmax, cmax));
            break;
        }
        case 35: {  // subPin — subtract and clamp to 0 (black)
            // Use int math to avoid underflow: max(dst - src, 0)
            result.x = (dc.x > sc.x) ? (dc.x - sc.x) : 0;
            result.y = (dc.y > sc.y) ? (dc.y - sc.y) : 0;
            result.z = (dc.z > sc.z) ? (dc.z - sc.z) : 0;
            result.w = (dc.w > sc.w) ? (dc.w - sc.w) : 0;
            break;
        }
        case 37: {  // adMax — component-wise maximum
            result = max(sc, dc);
            break;
        }
        case 38: {  // subOver — subtract with clamp to 0
            result.x = (dc.x > sc.x) ? (dc.x - sc.x) : 0;
            result.y = (dc.y > sc.y) ? (dc.y - sc.y) : 0;
            result.z = (dc.z > sc.z) ? (dc.z - sc.z) : 0;
            result.w = (dc.w > sc.w) ? (dc.w - sc.w) : 0;
            break;
        }
        case 39: {  // adMin — component-wise minimum
            result = min(sc, dc);
            break;
        }
        default: {
            // Unknown mode — fall back to srcCopy for safety
            result = sc;
            break;
        }
    }

    nqd_write_pixel(buffer, dst_addr, bpp, nqd_pack_components(result, bpp, u.bits_per_pixel));
}

// ---------------------------------------------------------------------------
// nqd_fillrect — fill rect compute kernel (all 17 pen modes)
//
// Boolean modes (8-15): per-byte operations. Thread gid ranges over
// width_bytes * height. Each thread processes one byte. The fill byte is
// extracted from the repeating fill_color pattern (same as patCopy path).
//
// Arithmetic modes (32-39) and hilite (50): per-pixel operations. Thread gid
// ranges over width_pixels * height. Each thread processes one complete pixel
// using component helpers. "Source" is the fill_color.
//
// The host dispatches the correct total thread count based on mode family:
// - Modes 8-15: total = width_bytes * height
// - Modes 32-39, 50: total = width_pixels * height
// ---------------------------------------------------------------------------

kernel void nqd_fillrect(device uint8_t *buffer          [[buffer(0)]],
                          constant NQDFillRectUniforms &u [[buffer(1)]],
                          device uint8_t *mask_buffer     [[buffer(2)]],
                          uint gid                        [[thread_position_in_grid]])
{
    // --- Boolean modes (8-15): per-byte operations ---
    if (u.transfer_mode >= 8 && u.transfer_mode <= 15) {
        uint total = u.width_bytes * u.height;
        if (gid >= total) return;

        uint row = gid / u.width_bytes;
        uint col = gid % u.width_bytes;

        // Mask check for byte-mode: col is byte column, mask_stride is width_bytes
        if (u.mask_enabled) {
            uint mask_addr = u.mask_offset + row * u.mask_stride + col;
            if (mask_buffer[mask_addr] == 0) return;
        }

        uint dst_addr = u.dst_offset + row * uint(u.row_bytes) + col;

        // Extract the appropriate byte from the fill color pattern.
        // Big-endian byte order within the 32-bit word.
        uint byte_in_pixel = col % u.bpp;
        uint shift = (3 - ((4 - u.bpp) + byte_in_pixel)) * 8;
        uint8_t fill = uint8_t((u.fill_color >> shift) & 0xFF);

        uint8_t dst = buffer[dst_addr];

        switch (u.transfer_mode) {
            case 8:  buffer[dst_addr] = fill;              break;  // patCopy
            case 9:  buffer[dst_addr] = fill | dst;        break;  // patOr
            case 10: buffer[dst_addr] = fill ^ dst;        break;  // patXor
            case 11: buffer[dst_addr] = (~fill) & dst;     break;  // patBic
            case 12: buffer[dst_addr] = ~fill;             break;  // notPatCopy
            case 13: buffer[dst_addr] = (~fill) | dst;     break;  // notPatOr
            case 14: buffer[dst_addr] = (~fill) ^ dst;     break;  // notPatXor
            case 15: buffer[dst_addr] = fill & dst;        break;  // notPatBic
            default: buffer[dst_addr] = fill;              break;
        }
        return;
    }

    // --- Arithmetic modes (32-39) and hilite (50) ---
    // For packed depths (bits_per_pixel < 8), dispatch is per-byte with inner pixel loop.
    // For standard depths (>= 8), dispatch is per-pixel.

    if (u.bits_per_pixel < 8) {
        // --- Packed pixel fill arithmetic/hilite: per-byte with inner pixel loop ---
        uint packed_total = u.width_bytes * u.height;
        if (gid >= packed_total) return;

        uint p_row = gid / u.width_bytes;
        uint p_col = gid % u.width_bytes;  // byte column

        uint dst_byte_addr = u.dst_offset + p_row * uint(u.row_bytes) + p_col;

        uint pixels_per_byte = 8 / u.bits_per_pixel;
        uint bpp_local = u.bits_per_pixel;
        uint fill_mask_val = (1u << bpp_local) - 1;

        for (uint pi = 0; pi < pixels_per_byte; pi++) {
            if (u.mask_enabled) {
                uint pixel_col = p_col * pixels_per_byte + pi;
                uint mask_addr = u.mask_offset + p_row * u.mask_stride + pixel_col;
                if (mask_buffer[mask_addr] == 0) continue;
            }

            uint fill_val = u.fill_color & fill_mask_val;
            uint dst_val = nqd_read_packed_pixel(buffer, dst_byte_addr, pi, bpp_local);

            // Mode 36 (transparent): skip if fill matches background
            if (u.transfer_mode == 36) {
                if (fill_val != (u.back_pen & fill_mask_val)) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, fill_val);
                }
                continue;
            }

            // Mode 50 (hilite): swap back_pen ↔ hilite_color
            if (u.transfer_mode == 50) {
                uint bp = u.back_pen & fill_mask_val;
                uint hc = u.hilite_color & fill_mask_val;
                if (dst_val == bp) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, hc);
                } else if (dst_val == hc) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, bp);
                }
                continue;
            }

            // Arithmetic modes
            uint4 fc = nqd_extract_components(fill_val, 1, bpp_local);
            uint4 dc = nqd_extract_components(dst_val, 1, bpp_local);
            uint cmax_p = nqd_comp_max(1, bpp_local);
            uint4 p_result;

            switch (u.transfer_mode) {
                case 32: p_result = (fc + dc) / 2; break;
                case 33: p_result = min(fc + dc, uint4(cmax_p, cmax_p, cmax_p, cmax_p)); break;
                case 34: p_result = min(fc + dc, uint4(cmax_p, cmax_p, cmax_p, cmax_p)); break;
                case 35:
                    p_result.x = (dc.x > fc.x) ? (dc.x - fc.x) : 0;
                    p_result.y = p_result.z = p_result.w = 0;
                    break;
                case 37: p_result = max(fc, dc); break;
                case 38:
                    p_result.x = (dc.x > fc.x) ? (dc.x - fc.x) : 0;
                    p_result.y = p_result.z = p_result.w = 0;
                    break;
                case 39: p_result = min(fc, dc); break;
                default: p_result = fc; break;
            }

            nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local,
                                   nqd_pack_components(p_result, 1, bpp_local));
        }
        return;
    }

    // --- Standard depths (>= 8 bpp): per-pixel operations ---
    uint total = u.width_pixels * u.height;
    if (gid >= total) return;

    uint bpp = u.pixel_size;
    uint row = gid / u.width_pixels;
    uint col = gid % u.width_pixels;

    // Mask check for pixel-mode: col is pixel column, mask_stride is width_pixels
    if (u.mask_enabled) {
        uint mask_addr = u.mask_offset + row * u.mask_stride + col;
        if (mask_buffer[mask_addr] == 0) return;
    }

    uint dst_addr = u.dst_offset + row * uint(u.row_bytes) + col * bpp;

    // The "source" for fill is the fill_color (already packed as a pixel value)
    uint fill_pixel = u.fill_color;
    uint dst_pixel = nqd_read_pixel(buffer, dst_addr, bpp);

    // Mode 36 (transparent): skip write if fill matches background
    if (u.transfer_mode == 36) {
        if (fill_pixel != u.back_pen) {
            nqd_write_pixel(buffer, dst_addr, bpp, fill_pixel);
        }
        return;
    }

    // Mode 50 (hilite): swap back_pen ↔ hilite_color in destination
    if (u.transfer_mode == 50) {
        if (dst_pixel == u.back_pen) {
            nqd_write_pixel(buffer, dst_addr, bpp, u.hilite_color);
        } else if (dst_pixel == u.hilite_color) {
            nqd_write_pixel(buffer, dst_addr, bpp, u.back_pen);
        }
        return;
    }

    // Arithmetic modes (32-35, 37-39): per-component operations
    uint4 fc = nqd_extract_components(fill_pixel, bpp, u.bits_per_pixel);
    uint4 dc = nqd_extract_components(dst_pixel, bpp, u.bits_per_pixel);
    uint cmax = nqd_comp_max(bpp, u.bits_per_pixel);
    uint4 result;

    switch (u.transfer_mode) {
        case 32: {  // blend — 50% weight
            result = (fc + dc) / 2;
            break;
        }
        case 33: {  // addPin — add and clamp to max
            result = min(fc + dc, uint4(cmax, cmax, cmax, cmax));
            break;
        }
        case 34: {  // addOver — add with saturation
            result = min(fc + dc, uint4(cmax, cmax, cmax, cmax));
            break;
        }
        case 35: {  // subPin — subtract and clamp to 0
            result.x = (dc.x > fc.x) ? (dc.x - fc.x) : 0;
            result.y = (dc.y > fc.y) ? (dc.y - fc.y) : 0;
            result.z = (dc.z > fc.z) ? (dc.z - fc.z) : 0;
            result.w = (dc.w > fc.w) ? (dc.w - fc.w) : 0;
            break;
        }
        case 37: {  // adMax — component-wise maximum
            result = max(fc, dc);
            break;
        }
        case 38: {  // subOver — subtract with clamp to 0
            result.x = (dc.x > fc.x) ? (dc.x - fc.x) : 0;
            result.y = (dc.y > fc.y) ? (dc.y - fc.y) : 0;
            result.z = (dc.z > fc.z) ? (dc.z - fc.z) : 0;
            result.w = (dc.w > fc.w) ? (dc.w - fc.w) : 0;
            break;
        }
        case 39: {  // adMin — component-wise minimum
            result = min(fc, dc);
            break;
        }
        default: {
            // Unknown mode — fall back to fill copy for safety
            result = fc;
            break;
        }
    }

    nqd_write_pixel(buffer, dst_addr, bpp, nqd_pack_components(result, bpp, u.bits_per_pixel));
}

