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
 *  NQD bitblt, fillrect and scaled-bitblt kernels. `buffer` is the shared Mac
 *  RAM buffer; src and dst are byte offsets into it.
 */

#include <metal_stdlib>
using namespace metal;

// Must match NQDBitbltUniforms in nqd_metal_renderer.mm.
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
    uint fore_pen;       // 8/16/32bpp logical pixel; 1/2/4bpp htonl-packed pen
    uint back_pen;       // 8/16/32bpp logical pixel; 1/2/4bpp htonl-packed pen
    uint hilite_color;   // HiliteRGB (low-mem 0x0DA0) packed to pixel depth
    uint mask_enabled;   // 1 = mask gating active, 0 = no mask
    uint mask_offset;    // byte offset into mask_buffer where mask data starts
    uint mask_stride;    // mask row stride (width_bytes for Boolean, width_pixels for arithmetic)
    uint bits_per_pixel; // 1, 2, 4, 8, 16 or 32
    // rgbOpColor weights for blend (32): 0 = all dst, 65535 = all src.
    uint blend_weight_r;
    uint blend_weight_g;
    uint blend_weight_b;
};

// Must match NQDFillRectUniforms in nqd_metal_renderer.mm.
struct NQDFillRectUniforms {
    uint dst_offset;
    int  row_bytes;
    uint width_bytes;
    uint height;
    uint fill_color;     // fill pixel/index pattern, logical at standard depths
    uint bpp;            // bytes per pixel (1, 2, or 4)
    uint transfer_mode;  // pen mode: 8-15 (Boolean), 32-39 (arithmetic), 50 (hilite)
    uint pixel_size;     // same as bpp
    uint width_pixels;   // width in pixels (used for arithmetic/hilite per-pixel dispatch)
    uint fore_pen;       // 8/16/32bpp logical pixel; 1/2/4bpp htonl-packed pen
    uint back_pen;       // 8/16/32bpp logical pixel; 1/2/4bpp htonl-packed pen
    uint hilite_color;   // HiliteRGB packed to pixel depth
    uint mask_enabled;   // 1 = mask gating active, 0 = no mask
    uint mask_offset;    // byte offset into mask_buffer where mask data starts
    uint mask_stride;    // mask row stride (width_bytes for Boolean, width_pixels for arithmetic)
    uint bits_per_pixel; // 1, 2, 4, 8, 16 or 32
    // rgbOpColor weights for blend (32): 0 = all dst, 65535 = all src.
    uint blend_weight_r;
    uint blend_weight_g;
    uint blend_weight_b;
};

// Guest pixels are big-endian: 16bpp is [HI][LO] 1-5-5-5 ARGB, 32bpp is
// [A][R][G][B]. Assemble them byte by byte; a pointer cast would read
// little-endian.

// Returns the logical 8/16/32bpp value. 16bpp keeps the 1555 high bit, so
// whole-pixel comparisons need pens in the same form.
static inline uint nqd_read_pixel(device uint8_t *buffer, uint addr, uint bpp)
{
    if (bpp == 1) {
        return uint(buffer[addr]);
    } else if (bpp == 2) {
        return (uint(buffer[addr]) << 8) | uint(buffer[addr + 1]);
    } else {
        return (uint(buffer[addr]) << 24) | (uint(buffer[addr + 1]) << 16) |
               (uint(buffer[addr + 2]) << 8) | uint(buffer[addr + 3]);
    }
}

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

// 1/2/4bpp pixels are packed MSB-first: pixel 0 is the high bits of the byte.
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

// Split a pixel into (r, g, b, a). Indexed depths put the index in r;
// 16bpp gives 5-bit r/g/b and a 1-bit a; 32bpp gives 8-bit channels.
static inline uint4 nqd_extract_components(uint pixel, uint bpp, uint bits_per_pixel_val)
{
    if (bits_per_pixel_val < 8) {
        return uint4(pixel, 0, 0, 0);
    }
    if (bpp == 1) {
        return uint4(pixel & 0xFF, 0, 0, 0);
    } else if (bpp == 2) {
        uint a = (pixel >> 15) & 0x1;
        uint r = (pixel >> 10) & 0x1F;
        uint g = (pixel >> 5)  & 0x1F;
        uint b = pixel & 0x1F;
        return uint4(r, g, b, a);
    } else {
        uint a = (pixel >> 24) & 0xFF;
        uint r = (pixel >> 16) & 0xFF;
        uint g = (pixel >> 8)  & 0xFF;
        uint b = pixel & 0xFF;
        return uint4(r, g, b, a);
    }
}

// Inverse of nqd_extract_components.
static inline uint nqd_pack_components(uint4 c, uint bpp, uint bits_per_pixel_val)
{
    if (bits_per_pixel_val < 8) {
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

// Per-component max, for saturating arithmetic.
static inline uint nqd_comp_max(uint bpp, uint bits_per_pixel_val)
{
    if (bits_per_pixel_val == 1) return 1;
    if (bits_per_pixel_val == 2) return 3;
    if (bits_per_pixel_val == 4) return 15;
    if (bpp == 2) return 31;   // 5-bit components
    return 255;                 // 8-bit components (8bpp and 32bpp)
}

// Pen index for 1/2/4bpp. The guest stores the index in the big-endian low
// byte of the pen field; after ReadMacInt32 + htonl it sits in bits 31-24.
// So take the low bits of the top byte, not `pen & 1u`. (Lane-replicated pens
// like 0xC8C8C8C8 hide the difference.) Standard depths pass pens unswapped.
static inline uint nqd_pen_index_packed(uint pen_htonl, uint bits_per_pixel_val)
{
    uint mask = (1u << bits_per_pixel_val) - 1u;
    return (pen_htonl >> 24) & mask;   // big-endian LSByte of the pen
}

// bitblt, all 17 transfer modes. One thread per byte for Boolean modes (0-7)
// and for packed depths; one thread per pixel for arithmetic (32-39) and
// hilite (50) at 8bpp and up. The host sizes the grid to match.

kernel void nqd_bitblt(device uint8_t *buffer        [[buffer(0)]],
                       constant NQDBitbltUniforms &u  [[buffer(1)]],
                       device uint8_t *mask_buffer    [[buffer(2)]],
                       uint gid                       [[thread_position_in_grid]])
{
    if (u.transfer_mode <= 7) {
        uint total = u.width_bytes * u.height;
        if (gid >= total) return;

        uint row = gid / u.width_bytes;
        uint col = gid % u.width_bytes;

        // Standard depths use a pixel-column mask, packed depths a byte-column mask.
        if (u.mask_enabled) {
            uint mask_col = (u.bits_per_pixel >= 8) ? (col / u.pixel_size) : col;
            uint mask_addr = u.mask_offset + row * u.mask_stride + mask_col;
            if (mask_buffer[mask_addr] == 0) return;
        }

        uint src_addr = u.src_offset + row * uint(u.src_row_bytes) + col;
        uint dst_addr = u.dst_offset + row * uint(u.dst_row_bytes) + col;

        uint8_t src = buffer[src_addr];
        uint8_t dst = buffer[dst_addr];

        // Color QuickDraw colorizes a 1-bit source before the Boolean op: source 1
        // becomes the fore pen, 0 the back pen. Multi-bit colour sources under a
        // Boolean op are sent to software by NQD_bitblt_hook and never reach here.
        if (u.bits_per_pixel == 1) {
            uint fore_bit = nqd_pen_index_packed(u.fore_pen, 1u);
            uint back_bit = nqd_pen_index_packed(u.back_pen, 1u);
            uint8_t colorized = 0;
            for (uint bit = 0; bit < 8; bit++) {
                uint s = (uint(src) >> bit) & 1u;
                uint c = (s == 1u) ? fore_bit : back_bit;
                colorized |= uint8_t(c << bit);
            }
            src = colorized;
        }

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

    // Arithmetic (32-39) and hilite (50).

    if (u.bits_per_pixel < 8) {
        // Packed: one thread per byte, loop over its pixels.
        uint packed_total = u.width_bytes * u.height;
        if (gid >= packed_total) return;

        uint p_row = gid / u.width_bytes;
        uint p_col = gid % u.width_bytes;  // byte column

        uint src_byte_addr = u.src_offset + p_row * uint(u.src_row_bytes) + p_col;
        uint dst_byte_addr = u.dst_offset + p_row * uint(u.dst_row_bytes) + p_col;

        uint pixels_per_byte = 8 / u.bits_per_pixel;
        uint bpp_local = u.bits_per_pixel;

        for (uint pi = 0; pi < pixels_per_byte; pi++) {
            if (u.mask_enabled) {
                uint pixel_col = p_col * pixels_per_byte + pi;
                uint mask_addr = u.mask_offset + p_row * u.mask_stride + pixel_col;
                if (mask_buffer[mask_addr] == 0) continue;
            }

            uint src_val = nqd_read_packed_pixel(buffer, src_byte_addr, pi, bpp_local);
            uint dst_val = nqd_read_packed_pixel(buffer, dst_byte_addr, pi, bpp_local);

            // On a 1-bit device each arithmetic/hilite mode acts as a Boolean mode
            // (IWQD 4-40, Table 4-2):
            //   blend(32)                              -> srcCopy
            //   addOver(34), subOver(38), hilite(50)   -> srcXor
            //   addPin(33), addMax(37)                 -> srcBic
            //   subPin(35), adMin(39), transparent(36) -> srcOr
            if (bpp_local == 1) {
                uint b1_src = src_val & 1u;
                uint b1_dst = dst_val & 1u;
                uint b1_out;
                switch (u.transfer_mode) {
                    case 32: b1_out = b1_src;              break;  // srcCopy
                    case 34:                                       // addOver
                    case 38:                                       // subOver
                    case 50: b1_out = b1_src ^ b1_dst;     break;  // hilite -> srcXor
                    case 33:                                       // addPin
                    case 37: b1_out = (~b1_src) & b1_dst & 1u; break;  // adMax -> srcBic
                    case 35:                                       // subPin
                    case 36:                                       // transparent
                    case 39: b1_out = b1_src | b1_dst;     break;  // adMin -> srcOr
                    default: b1_out = b1_src;              break;  // srcCopy fallback
                }
                nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, b1_out);
                continue;
            }

            // transparent (36): skip pixels equal to the back pen.
            if (u.transfer_mode == 36) {
                if (src_val != nqd_pen_index_packed(u.back_pen, bpp_local)) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, src_val);
                }
                continue;
            }

            // hilite (50): background -> highlight only, never the reverse (IWQD
            // 4-41/4-43); dst pixels already equal to the highlight stay put. back_pen
            // is htonl-packed, so use nqd_pen_index_packed. hilite_color is built as a
            // raw low-byte index (not htonl'd), so its index is the low bits.
            if (u.transfer_mode == 50) {
                uint bp = nqd_pen_index_packed(u.back_pen, bpp_local);
                uint hc = u.hilite_color & ((1u << bpp_local) - 1);
                if (dst_val == bp) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, hc);
                }
                continue;
            }

            uint4 sc = nqd_extract_components(src_val, 1, bpp_local);
            uint4 dc = nqd_extract_components(dst_val, 1, bpp_local);
            uint cmax_p = nqd_comp_max(1, bpp_local);
            uint4 p_result;

            switch (u.transfer_mode) {
                case 32: { // blend — weighted by OpColor (packed index-approx)
                    // Packed pixels are a palette index, so only the red weight applies.
                    uint w = u.blend_weight_r;
                    p_result = (sc * w + dc * (65535u - w)) / 65535u;
                    break;
                }
                case 33: p_result = min(sc + dc, uint4(cmax_p, cmax_p, cmax_p, cmax_p)); break;
                case 34: p_result = (sc + dc) & uint4(cmax_p, cmax_p, cmax_p, cmax_p); break;  // addOver: modular wrap
                case 35:
                    p_result.x = (dc.x > sc.x) ? (dc.x - sc.x) : 0;
                    p_result.y = p_result.z = p_result.w = 0;
                    break;
                case 37: p_result = max(sc, dc); break;
                case 38: p_result = (dc - sc) & uint4(cmax_p, cmax_p, cmax_p, cmax_p); break;  // subOver: modular wrap
                case 39: p_result = min(sc, dc); break;
                default: p_result = sc; break;
            }

            nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local,
                                   nqd_pack_components(p_result, 1, bpp_local));
        }
        return;
    }

    // 8bpp and up: one thread per pixel.
    uint total = u.width_pixels * u.height;
    if (gid >= total) return;

    uint bpp = u.pixel_size;
    uint row = gid / u.width_pixels;
    uint col = gid % u.width_pixels;

    if (u.mask_enabled) {
        uint mask_addr = u.mask_offset + row * u.mask_stride + col;
        if (mask_buffer[mask_addr] == 0) return;
    }

    uint src_addr = u.src_offset + row * uint(u.src_row_bytes) + col * bpp;
    uint dst_addr = u.dst_offset + row * uint(u.dst_row_bytes) + col * bpp;

    uint src_pixel = nqd_read_pixel(buffer, src_addr, bpp);
    uint dst_pixel = nqd_read_pixel(buffer, dst_addr, bpp);

    // transparent (36): back_pen is the logical pixel; 16bpp compares the raw
    // 1555 word including bit 15.
    if (u.transfer_mode == 36) {
        if (src_pixel != u.back_pen) {
            nqd_write_pixel(buffer, dst_addr, bpp, src_pixel);
        }
        return;
    }

    // hilite (50): background -> highlight only, never the reverse (IWQD
    // 4-41/4-43). back_pen is the logical pixel at standard depths.
    if (u.transfer_mode == 50) {
        if (dst_pixel == u.back_pen) {
            nqd_write_pixel(buffer, dst_addr, bpp, u.hilite_color);
        }
        return;
    }

    uint4 sc = nqd_extract_components(src_pixel, bpp, u.bits_per_pixel);
    uint4 dc = nqd_extract_components(dst_pixel, bpp, u.bits_per_pixel);
    uint cmax = nqd_comp_max(bpp, u.bits_per_pixel);
    uint4 result;

    switch (u.transfer_mode) {
        case 32: {  // blend — weighted by per-channel rgbOpColor
            // uint4 lanes: x=R y=G z=B; w mirrors R (alpha follows red weight).
            uint4 w = uint4(u.blend_weight_r, u.blend_weight_g,
                            u.blend_weight_b, u.blend_weight_r);
            result = (sc * w + dc * (65535u - w)) / 65535u;
            break;
        }
        case 33: {  // addPin — add and clamp to max (white)
            result = min(sc + dc, uint4(cmax, cmax, cmax, cmax));
            break;
        }
        case 34: {  // addOver — add with modular wrap
            result = (sc + dc) & uint4(cmax, cmax, cmax, cmax);
            break;
        }
        case 35: {  // subPin — subtract and clamp to 0 (black)
            // Avoid unsigned underflow.
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
        case 38: {  // subOver — subtract with modular wrap
            result = (dc - sc) & uint4(cmax, cmax, cmax, cmax);
            break;
        }
        case 39: {  // adMin — component-wise minimum
            result = min(sc, dc);
            break;
        }
        default: {
            // Unknown mode: srcCopy.
            result = sc;
            break;
        }
    }

    nqd_write_pixel(buffer, dst_addr, bpp, nqd_pack_components(result, bpp, u.bits_per_pixel));
}

// fillrect, all 17 pen modes; fill_color plays the source. Same grid shape
// as nqd_bitblt, with Boolean modes 8-15.

kernel void nqd_fillrect(device uint8_t *buffer          [[buffer(0)]],
                          constant NQDFillRectUniforms &u [[buffer(1)]],
                          device uint8_t *mask_buffer     [[buffer(2)]],
                          uint gid                        [[thread_position_in_grid]])
{
    if (u.transfer_mode >= 8 && u.transfer_mode <= 15) {
        uint total = u.width_bytes * u.height;
        if (gid >= total) return;

        uint row = gid / u.width_bytes;
        uint col = gid % u.width_bytes;

        // Standard depths use a pixel-column mask, packed depths a byte-column mask.
        if (u.mask_enabled) {
            uint mask_col = (u.bits_per_pixel >= 8) ? (col / u.pixel_size) : col;
            uint mask_addr = u.mask_offset + row * u.mask_stride + mask_col;
            if (mask_buffer[mask_addr] == 0) return;
        }

        uint dst_addr = u.dst_offset + row * uint(u.row_bytes) + col;

        // This byte of the fill pixel, big-endian.
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

    // Arithmetic (32-39) and hilite (50).

    if (u.bits_per_pixel < 8) {
        // Packed: one thread per byte, loop over its pixels.
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

            // 1-bit device: same Boolean routing as nqd_bitblt, with the fill bit as source.
            if (bpp_local == 1) {
                uint b1_src = fill_val & 1u;
                uint b1_dst = dst_val & 1u;
                uint b1_out;
                switch (u.transfer_mode) {
                    case 32: b1_out = b1_src;              break;  // srcCopy
                    case 34:                                       // addOver
                    case 38:                                       // subOver
                    case 50: b1_out = b1_src ^ b1_dst;     break;  // hilite -> srcXor
                    case 33:                                       // addPin
                    case 37: b1_out = (~b1_src) & b1_dst & 1u; break;  // adMax -> srcBic
                    case 35:                                       // subPin
                    case 36:                                       // transparent
                    case 39: b1_out = b1_src | b1_dst;     break;  // adMin -> srcOr
                    default: b1_out = b1_src;              break;  // srcCopy fallback
                }
                nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, b1_out);
                continue;
            }

            // transparent (36): back_pen is htonl-packed, so use nqd_pen_index_packed.
            // fill_color is not htonl'd, so its index is the low bits.
            if (u.transfer_mode == 36) {
                if (fill_val != nqd_pen_index_packed(u.back_pen, bpp_local)) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, fill_val);
                }
                continue;
            }

            // hilite (50): same rules as the nqd_bitblt packed branch.
            if (u.transfer_mode == 50) {
                uint bp = nqd_pen_index_packed(u.back_pen, bpp_local);
                uint hc = u.hilite_color & fill_mask_val;
                if (dst_val == bp) {
                    nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local, hc);
                }
                continue;
            }

            uint4 fc = nqd_extract_components(fill_val, 1, bpp_local);
            uint4 dc = nqd_extract_components(dst_val, 1, bpp_local);
            uint cmax_p = nqd_comp_max(1, bpp_local);
            uint4 p_result;

            switch (u.transfer_mode) {
                case 32: { uint w = u.blend_weight_r; p_result = (fc * w + dc * (65535u - w)) / 65535u; break; }  // packed index-approx — red weight only
                case 33: p_result = min(fc + dc, uint4(cmax_p, cmax_p, cmax_p, cmax_p)); break;
                case 34: p_result = (fc + dc) & uint4(cmax_p, cmax_p, cmax_p, cmax_p); break;  // addOver: modular wrap
                case 35:
                    p_result.x = (dc.x > fc.x) ? (dc.x - fc.x) : 0;
                    p_result.y = p_result.z = p_result.w = 0;
                    break;
                case 37: p_result = max(fc, dc); break;
                case 38: p_result = (dc - fc) & uint4(cmax_p, cmax_p, cmax_p, cmax_p); break;  // subOver: modular wrap
                case 39: p_result = min(fc, dc); break;
                default: p_result = fc; break;
            }

            nqd_write_packed_pixel(buffer, dst_byte_addr, pi, bpp_local,
                                   nqd_pack_components(p_result, 1, bpp_local));
        }
        return;
    }

    // 8bpp and up: one thread per pixel.
    uint total = u.width_pixels * u.height;
    if (gid >= total) return;

    uint bpp = u.pixel_size;
    uint row = gid / u.width_pixels;
    uint col = gid % u.width_pixels;

    if (u.mask_enabled) {
        uint mask_addr = u.mask_offset + row * u.mask_stride + col;
        if (mask_buffer[mask_addr] == 0) return;
    }

    uint dst_addr = u.dst_offset + row * uint(u.row_bytes) + col * bpp;

    uint fill_pixel = u.fill_color;
    uint dst_pixel = nqd_read_pixel(buffer, dst_addr, bpp);

    // transparent (36): back_pen is the logical pixel; 16bpp compares the raw
    // 1555 word including bit 15.
    if (u.transfer_mode == 36) {
        if (fill_pixel != u.back_pen) {
            nqd_write_pixel(buffer, dst_addr, bpp, fill_pixel);
        }
        return;
    }

    // hilite (50): background -> highlight only, never the reverse (IWQD
    // 4-41/4-43). back_pen is the logical pixel at standard depths.
    if (u.transfer_mode == 50) {
        if (dst_pixel == u.back_pen) {
            nqd_write_pixel(buffer, dst_addr, bpp, u.hilite_color);
        }
        return;
    }

    uint4 fc = nqd_extract_components(fill_pixel, bpp, u.bits_per_pixel);
    uint4 dc = nqd_extract_components(dst_pixel, bpp, u.bits_per_pixel);
    uint cmax = nqd_comp_max(bpp, u.bits_per_pixel);
    uint4 result;

    switch (u.transfer_mode) {
        case 32: {  // blend — weighted by per-channel rgbOpColor
            // uint4 lanes: x=R y=G z=B; w mirrors R (alpha follows red weight).
            uint4 w = uint4(u.blend_weight_r, u.blend_weight_g,
                            u.blend_weight_b, u.blend_weight_r);
            result = (fc * w + dc * (65535u - w)) / 65535u;
            break;
        }
        case 33: {  // addPin — add and clamp to max
            result = min(fc + dc, uint4(cmax, cmax, cmax, cmax));
            break;
        }
        case 34: {  // addOver — add with modular wrap
            // addOver wraps (IWQD 4-40); saturating is addPin.
            result = (fc + dc) & uint4(cmax, cmax, cmax, cmax);
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
        case 38: {  // subOver — subtract with modular wrap
            result = (dc - fc) & uint4(cmax, cmax, cmax, cmax);
            break;
        }
        case 39: {  // adMin — component-wise minimum
            result = min(fc, dc);
            break;
        }
        default: {
            // Unknown mode: plain fill.
            result = fc;
            break;
        }
    }

    nqd_write_pixel(buffer, dst_addr, bpp, nqd_pack_components(result, bpp, u.bits_per_pixel));
}

// Scaling bitblt for DSpBlit_Faster (sub-op 710), 8bpp and up. One thread
// per dst pixel. Nearest-neighbor by default; bilinear only with
// kDSpBlitMode_Interpolation (DSp PDF p.87). SrcKey skips src pixels equal
// to src_key; DstKey leaves dst pixels equal to dst_key.

// Must match NQDBitbltScaledUniforms in nqd_metal_renderer.mm.
struct NQDBitbltScaledUniforms {
    uint src_offset;     // byte offset of src rect origin
    uint dst_offset;     // byte offset of dst rect origin
    int  src_row_bytes;
    int  dst_row_bytes;
    uint pixel_size;     // bytes per pixel (1, 2, or 4)
    uint bits_per_pixel; // 8, 16 or 32
    uint src_w;          // pixels
    uint src_h;
    uint dst_w;
    uint dst_h;
    uint interpolate;    // 1 = bilinear (kDSpBlitMode_Interpolation), 0 = nearest
    uint src_key;        // big-endian pixel value
    uint dst_key;
    uint key_enable;     // bit-or of kDSpBlitMode_SrcKey(1) / _DstKey(2); 0 = no key
    uint ram_size;       // bounds clamp; 0 = unchecked
};

kernel void nqd_bitblt_scaled(device uint8_t *buffer                  [[buffer(0)]],
                              constant NQDBitbltScaledUniforms &u     [[buffer(1)]],
                              uint gid                                [[thread_position_in_grid]])
{
    uint total = u.dst_w * u.dst_h;
    if (gid >= total) return;
    if (u.dst_w == 0 || u.dst_h == 0 || u.src_w == 0 || u.src_h == 0) return;

    uint bpp = u.pixel_size;
    uint dx  = gid % u.dst_w;
    uint dy  = gid / u.dst_w;

    bool src_key_on = (u.key_enable & 1u) != 0u;
    bool dst_key_on = (u.key_enable & 2u) != 0u;

    uint dst_addr = u.dst_offset + dy * uint(u.dst_row_bytes) + dx * bpp;

    // The host already validated the extent; clamp every access anyway so a
    // mismatch can't become an out-of-bounds GPU access.
    if (u.ram_size != 0u && (dst_addr + bpp) > u.ram_size) return;

    if (dst_key_on) {
        uint dst_existing = nqd_read_pixel(buffer, dst_addr, bpp);
        if (dst_existing == u.dst_key) return;
    }

    uint out_pixel;

    if (u.interpolate != 0u && bpp == 4) {
        // Bilinear only at 32bpp; blending palette indices is meaningless.
        float fx = (float(dx) + 0.5f) * float(u.src_w) / float(u.dst_w) - 0.5f;
        float fy = (float(dy) + 0.5f) * float(u.src_h) / float(u.dst_h) - 0.5f;
        if (fx < 0.0f) fx = 0.0f;
        if (fy < 0.0f) fy = 0.0f;
        uint sx0 = uint(fx);
        uint sy0 = uint(fy);
        uint sx1 = (sx0 + 1u < u.src_w) ? (sx0 + 1u) : sx0;
        uint sy1 = (sy0 + 1u < u.src_h) ? (sy0 + 1u) : sy0;
        float wx = fx - float(sx0);
        float wy = fy - float(sy0);

        uint a00 = u.src_offset + sy0 * uint(u.src_row_bytes) + sx0 * bpp;
        uint a10 = u.src_offset + sy0 * uint(u.src_row_bytes) + sx1 * bpp;
        uint a01 = u.src_offset + sy1 * uint(u.src_row_bytes) + sx0 * bpp;
        uint a11 = u.src_offset + sy1 * uint(u.src_row_bytes) + sx1 * bpp;

        if (u.ram_size != 0u &&
            ((a00 + bpp) > u.ram_size || (a10 + bpp) > u.ram_size ||
             (a01 + bpp) > u.ram_size || (a11 + bpp) > u.ram_size)) return;

        uint p00 = nqd_read_pixel(buffer, a00, bpp);

        // SrcKey tests the top-left sample.
        if (src_key_on && p00 == u.src_key) return;

        uint p10 = nqd_read_pixel(buffer, a10, bpp);
        uint p01 = nqd_read_pixel(buffer, a01, bpp);
        uint p11 = nqd_read_pixel(buffer, a11, bpp);

        uint4 c00 = nqd_extract_components(p00, bpp, u.bits_per_pixel);
        uint4 c10 = nqd_extract_components(p10, bpp, u.bits_per_pixel);
        uint4 c01 = nqd_extract_components(p01, bpp, u.bits_per_pixel);
        uint4 c11 = nqd_extract_components(p11, bpp, u.bits_per_pixel);

        float4 top    = mix(float4(c00), float4(c10), wx);
        float4 bottom = mix(float4(c01), float4(c11), wx);
        float4 blended = mix(top, bottom, wy);
        uint4 outc = uint4(blended + float4(0.5f, 0.5f, 0.5f, 0.5f));

        out_pixel = nqd_pack_components(outc, bpp, u.bits_per_pixel);
    } else {
        uint sx = (dx * u.src_w) / u.dst_w;
        uint sy = (dy * u.src_h) / u.dst_h;
        if (sx >= u.src_w) sx = u.src_w - 1u;
        if (sy >= u.src_h) sy = u.src_h - 1u;
        uint src_addr = u.src_offset + sy * uint(u.src_row_bytes) + sx * bpp;
        if (u.ram_size != 0u && (src_addr + bpp) > u.ram_size) return;
        out_pixel = nqd_read_pixel(buffer, src_addr, bpp);

        if (src_key_on && out_pixel == u.src_key) return;
    }

    nqd_write_pixel(buffer, dst_addr, bpp, out_pixel);
}
