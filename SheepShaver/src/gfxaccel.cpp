/*
 *  gfxaccel.cpp - Generic Native QuickDraw acceleration
 *
 *  SheepShaver (C) 1997-2008 Marc Hellwig and Christian Bauer
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include "sysdeps.h"

#include "prefs.h"
#include "video.h"
#include "video_defs.h"
#include "rave_engine.h"
#include "gl_engine.h"
#include "dsp_engine.h"
#include "nqd_accel.h"
#include "nqd_region_range.h"
#include "nqd_transfer_mode_policy.h"

#define DEBUG 0
#include "debug.h"


/*
 *	Utility functions
 */

// Return bytes per pixel for requested depth
static inline int bytes_per_pixel(int depth)
{
	int bpp;
	switch (depth) {
	case 8:
		bpp = 1;
		break;
	case 15: case 16:
		bpp = 2;
		break;
	case 24: case 32:
		bpp = 4;
		break;
	default:
		abort();
	}
	return bpp;
}

static inline bool NQD_packed_depth_supported(uint32 pixel_size)
{
	return pixel_size == 1 || pixel_size == 2 || pixel_size == 4;
}

static inline bool NQD_packed_x_byte_aligned(int32 x, uint32 pixel_size)
{
	if (pixel_size >= 8)
		return true;
	if (!NQD_packed_depth_supported(pixel_size))
		return false;
	return ((x * (int32)pixel_size) & 7) == 0;
}

static inline bool NQD_packed_rect_edges_byte_aligned(int32 x, int32 width, uint32 pixel_size)
{
	return NQD_packed_x_byte_aligned(x, pixel_size) &&
	       NQD_packed_x_byte_aligned(x + width, pixel_size);
}

static inline bool NQD_dest_rect_byte_aligned_for_depth(uint32 p, uint32 pixel_size)
{
	if (pixel_size >= 8)
		return true;
	int32 dest_X = (int16)ReadMacInt16(p + acclDestRect + 2) - (int16)ReadMacInt16(p + acclDestBoundsRect + 2);
	int32 width  = (int16)ReadMacInt16(p + acclDestRect + 6) - (int16)ReadMacInt16(p + acclDestRect + 2);
	return NQD_packed_rect_edges_byte_aligned(dest_X, width, pixel_size);
}

static inline bool NQD_bitblt_rects_byte_aligned_for_depth(uint32 p, uint32 pixel_size)
{
	if (pixel_size >= 8)
		return true;
	int32 src_X  = (int16)ReadMacInt16(p + acclSrcRect + 2) - (int16)ReadMacInt16(p + acclSrcBoundsRect + 2);
	int32 dest_X = (int16)ReadMacInt16(p + acclDestRect + 2) - (int16)ReadMacInt16(p + acclDestBoundsRect + 2);
	int32 width  = (int16)ReadMacInt16(p + acclDestRect + 6) - (int16)ReadMacInt16(p + acclDestRect + 2);
	return NQD_packed_rect_edges_byte_aligned(src_X, width, pixel_size) &&
	       NQD_packed_rect_edges_byte_aligned(dest_X, width, pixel_size);
}

// Native CPU acceleration needs a known contiguous mapping: guest RAM or the
// video driver's frame buffer. A rect must lie wholly inside one of them.
// Other memory domains (such as ROM sources) stay with software QuickDraw:
// hooks must decline them before publishing a proc. Only RAM is visible to
// the Metal path (NQDMetalAddrInBuffer), so screen packets take the CPU paths.
extern bool video_get_frame_buffer_range(uint32 *mac_base, uint32 *size);

static bool NQD_resolve_mapped_rect(uint32 p, bool source, bool backward_rows,
                                    uint32 *out_origin)
{
	const int rect = source ? acclSrcRect : acclDestRect;
	const int bounds = source ? acclSrcBoundsRect : acclDestBoundsRect;
	const int x = (int16)ReadMacInt16(p + rect + 2) - (int16)ReadMacInt16(p + bounds + 2);
	const int y = (int16)ReadMacInt16(p + rect) - (int16)ReadMacInt16(p + bounds);
	const int width = (int16)ReadMacInt16(p + acclDestRect + 6) - (int16)ReadMacInt16(p + acclDestRect + 2);
	const int height = (int16)ReadMacInt16(p + acclDestRect + 4) - (int16)ReadMacInt16(p + acclDestRect);
	if (x < 0 || y < 0 || width <= 0 || height <= 0) return false;
	const uint32 bits = ReadMacInt32(p + (source ? acclSrcPixelSize : acclDestPixelSize));
	if (!(bits == 1 || bits == 2 || bits == 4 || bits == 8 ||
	      bits == 15 || bits == 16 || bits == 24 || bits == 32)) return false;
	const uint32 storage_bits = bits == 15 ? 16 : bits == 24 ? 32 : bits;
	const uint32 base = ReadMacInt32(p + (source ? acclSrcBaseAddr : acclDestBaseAddr));
	uint64_t domain_base = RAMBase, domain_size = RAMSize;
	if (uint64_t(base) - domain_base >= domain_size) {
		uint32 fb_base, fb_size;
		if (!video_get_frame_buffer_range(&fb_base, &fb_size) ||
		    uint64_t(base) - fb_base >= fb_size) return false;
		domain_base = fb_base;
		domain_size = fb_size;
	}
	int64_t stride = (int32)ReadMacInt32(p + (source ? acclSrcRowBytes : acclDestRowBytes));
	if (!stride || stride == INT32_MIN) return false;
	if (backward_rows && stride < 0) stride = -stride;
	const uint64_t x_byte = uint64_t(x) * storage_bits / 8u;
	const uint64_t end_byte = (uint64_t(x + width) * storage_bits + 7u) / 8u;
	const int64_t origin = int64_t(base) + int64_t(y) * stride + int64_t(x_byte);
	const int64_t last = origin + int64_t(height - 1) * stride;
	const int64_t lo = origin < last ? origin : last;
	const int64_t hi = (origin > last ? origin : last) + int64_t(end_byte - x_byte);
	const uint64_t domain_end = domain_base + domain_size;
	if (lo < int64_t(domain_base) || hi < lo || uint64_t(hi) > domain_end ||
	    uint64_t(hi) > (uint64_t(1) << 32)) return false;
	if (out_origin) *out_origin = uint32(origin);
	return true;
}

static bool NQD_validate_packet_mapping(uint32 p, bool blit)
{
	if (blit && (ReadMacInt32(p + acclSrcPixelSize) != ReadMacInt32(p + acclDestPixelSize) ||
	    (int32)(ReadMacInt32(p + acclSrcRowBytes) ^ ReadMacInt32(p + acclDestRowBytes)) < 0))
		return false;
	const bool backward_rows = blit && (int32)ReadMacInt32(p + acclSrcRowBytes) < 0;
	return NQD_resolve_mapped_rect(p, false, backward_rows, nullptr) &&
	       (!blit || NQD_resolve_mapped_rect(p, true, backward_rows, nullptr));
}

// Pass-through dirty areas to redraw functions
static inline void NQD_set_dirty_area(uint32 p)
{
	if (ReadMacInt32(p + acclDestBaseAddr) == screen_base) {
		int x = (int16)ReadMacInt16(p + acclDestRect + 2) - (int16)ReadMacInt16(p + acclDestBoundsRect + 2);
		int y = (int16)ReadMacInt16(p + acclDestRect + 0) - (int16)ReadMacInt16(p + acclDestBoundsRect + 0);
		int w  = (int16)ReadMacInt16(p + acclDestRect + 6) - (int16)ReadMacInt16(p + acclDestRect + 2);
		int h = (int16)ReadMacInt16(p + acclDestRect + 4) - (int16)ReadMacInt16(p + acclDestRect + 0);
		video_set_dirty_area(x, y, w, h);
	}
}


/*
 *	Rectangle inversion
 */

template< int bpp >
static inline void do_invrect(uint8 *dest, uint32 length)
{
#define INVERT_1(PTR, OFS) ((uint8  *)(PTR))[OFS] = ~((uint8  *)(PTR))[OFS]
#define INVERT_2(PTR, OFS) ((uint16 *)(PTR))[OFS] = ~((uint16 *)(PTR))[OFS]
#define INVERT_4(PTR, OFS) ((uint32 *)(PTR))[OFS] = ~((uint32 *)(PTR))[OFS]
#define INVERT_8(PTR, OFS) ((uint64 *)(PTR))[OFS] = ~((uint64 *)(PTR))[OFS]

#ifndef UNALIGNED_PROFITABLE
	// Align on 16-bit boundaries
	if (bpp < 16 && (((uintptr)dest) & 1)) {
		INVERT_1(dest, 0);
		dest += 1; length -= 1;
	}

	// Align on 32-bit boundaries
	if (bpp < 32 && (((uintptr)dest) & 2) && length >= 2) {
		INVERT_2(dest, 0);
		dest += 2; length -= 2;
	}
#endif

	// Invert 8-byte words
	if (length >= 8) {
		const int r = (length / 8) % 8;
		dest += r * 8;

		int n = ((length / 8) + 7) / 8;
		switch (r) {
		case 0: do {
				dest += 64;
				INVERT_8(dest, -8);
		case 7: INVERT_8(dest, -7);
		case 6: INVERT_8(dest, -6);
		case 5: INVERT_8(dest, -5);
		case 4: INVERT_8(dest, -4);
		case 3: INVERT_8(dest, -3);
		case 2: INVERT_8(dest, -2);
		case 1: INVERT_8(dest, -1);
				} while (--n > 0);
		}
	}

	// 32-bit cell to invert?
	if (length & 4) {
		INVERT_4(dest, 0);
		if (bpp <= 16)
			dest += 4;
	}

	// 16-bit cell to invert?
	if (bpp <= 16 && (length & 2)) {
		INVERT_2(dest, 0);
		if (bpp <= 8)
			dest += 2;
	}

	// 8-bit cell to invert?
	if (bpp <= 8 && (length & 1))
		INVERT_1(dest, 0);

#undef INVERT_1
#undef INVERT_2
#undef INVERT_4
#undef INVERT_8
}

void NQD_invrect(uint32 p)
{
	D(bug("accl_invrect %08x\n", p));

	if (!NQD_validate_packet_mapping(p, false)) return;

	// Metal-accelerated path (only if dest is within Metal-mapped RAM)
	if (nqd_metal_available && NQDMetalAddrInBuffer(ReadMacInt32(p + acclDestBaseAddr))) {
		NQDMetalInvertRect(p);
		return;
	}

	if (ReadMacInt32(p + acclDestPixelSize) < 8) return;

	// Get inversion parameters
	int dest_X = (int16)ReadMacInt16(p + acclDestRect + 2) - (int16)ReadMacInt16(p + acclDestBoundsRect + 2);
	int dest_Y = (int16)ReadMacInt16(p + acclDestRect + 0) - (int16)ReadMacInt16(p + acclDestBoundsRect + 0);
	int width  = (int16)ReadMacInt16(p + acclDestRect + 6) - (int16)ReadMacInt16(p + acclDestRect + 2);
	int height = (int16)ReadMacInt16(p + acclDestRect + 4) - (int16)ReadMacInt16(p + acclDestRect + 0);
	D(bug(" dest X %d, dest Y %d\n", dest_X, dest_Y));
	D(bug(" width %d, height %d, bytes_per_row %d\n", width, height, (int32)ReadMacInt32(p + acclDestRowBytes)));

	//!!?? pen_mode == 14

	// And perform the inversion
	const int bpp = bytes_per_pixel(ReadMacInt32(p + acclDestPixelSize));
	const int dest_row_bytes = (int32)ReadMacInt32(p + acclDestRowBytes);
	uint32 dest_origin;
	if (!NQD_resolve_mapped_rect(p, false, false, &dest_origin)) return;
	uint8 *dest = Mac2HostAddr(dest_origin);
	width *= bpp;
	switch (bpp) {
	case 1:
		for (int i = 0; i < height; i++) {
			do_invrect<8>(dest, width);
			if (i + 1 < height) dest += dest_row_bytes;
		}
		break;
	case 2:
		for (int i = 0; i < height; i++) {
			do_invrect<16>(dest, width);
			if (i + 1 < height) dest += dest_row_bytes;
		}
		break;
	case 4:
		for (int i = 0; i < height; i++) {
			do_invrect<32>(dest, width);
			if (i + 1 < height) dest += dest_row_bytes;
		}
		break;
	}
}


/*
 *	Rectangle filling
 */

template< int bpp >
static inline void do_fillrect(uint8 *dest, uint32 color, uint32 length)
{
#define FILL_1(PTR, OFS, VAL) ((uint8  *)(PTR))[OFS] = (VAL)
#define FILL_2(PTR, OFS, VAL) ((uint16 *)(PTR))[OFS] = (VAL)
#define FILL_4(PTR, OFS, VAL) ((uint32 *)(PTR))[OFS] = (VAL)
#define FILL_8(PTR, OFS, VAL) ((uint64 *)(PTR))[OFS] = (VAL)

#ifndef UNALIGNED_PROFITABLE
	// Align on 16-bit boundaries
	if (bpp < 16 && (((uintptr)dest) & 1)) {
		FILL_1(dest, 0, color);
		dest += 1; length -= 1;
	}

	// Align on 32-bit boundaries
	if (bpp < 32 && (((uintptr)dest) & 2) && length >= 2) {
		FILL_2(dest, 0, color);
		dest += 2; length -= 2;
	}
#endif

	// Fill 8-byte words
	if (length >= 8) {
		const uint64 c = (((uint64)color) << 32) | color;
		const int r = (length / 8) % 8;
		dest += r * 8;

		int n = ((length / 8) + 7) / 8;
		switch (r) {
		case 0: do {
				dest += 64;
				FILL_8(dest, -8, c);
		case 7: FILL_8(dest, -7, c);
		case 6: FILL_8(dest, -6, c);
		case 5: FILL_8(dest, -5, c);
		case 4: FILL_8(dest, -4, c);
		case 3: FILL_8(dest, -3, c);
		case 2: FILL_8(dest, -2, c);
		case 1: FILL_8(dest, -1, c);
				} while (--n > 0);
		}
	}

	// 32-bit cell to fill?
	if (length & 4) {
		FILL_4(dest, 0, color);
		if (bpp <= 16)
			dest += 4;
	}

	// 16-bit cell to fill?
	if (bpp <= 16 && (length & 2)) {
		FILL_2(dest, 0, color);
		if (bpp <= 8)
			dest += 2;
	}

	// 8-bit cell to fill?
	if (bpp <= 8 && (length & 1))
		FILL_1(dest, 0, color);

#undef FILL_1
#undef FILL_2
#undef FILL_4
#undef FILL_8
}

void NQD_fillrect(uint32 p)
{
	D(bug("accl_fillrect %08x\n", p));

	if (!NQD_validate_packet_mapping(p, false)) return;

	// Metal-accelerated path (only if dest is within Metal-mapped RAM)
	if (nqd_metal_available && NQDMetalAddrInBuffer(ReadMacInt32(p + acclDestBaseAddr))) {
		NQDMetalFillRect(p);
		return;
	}

	if (ReadMacInt32(p + acclDestPixelSize) < 8) return;

	// Get filling parameters
	int dest_X = (int16)ReadMacInt16(p + acclDestRect + 2) - (int16)ReadMacInt16(p + acclDestBoundsRect + 2);
	int dest_Y = (int16)ReadMacInt16(p + acclDestRect + 0) - (int16)ReadMacInt16(p + acclDestBoundsRect + 0);
	int width  = (int16)ReadMacInt16(p + acclDestRect + 6) - (int16)ReadMacInt16(p + acclDestRect + 2);
	int height = (int16)ReadMacInt16(p + acclDestRect + 4) - (int16)ReadMacInt16(p + acclDestRect + 0);
	uint32 color = htonl(ReadMacInt32(p + acclPenMode) == 8 ? ReadMacInt32(p + acclForePen) : ReadMacInt32(p + acclBackPen));
	D(bug(" dest X %d, dest Y %d\n", dest_X, dest_Y));
	D(bug(" width %d, height %d\n", width, height));
	D(bug(" bytes_per_row %d color %08x\n", (int32)ReadMacInt32(p + acclDestRowBytes), color));

	// And perform the fill
	const int bpp = bytes_per_pixel(ReadMacInt32(p + acclDestPixelSize));
	const int dest_row_bytes = (int32)ReadMacInt32(p + acclDestRowBytes);
	uint32 dest_origin;
	if (!NQD_resolve_mapped_rect(p, false, false, &dest_origin)) return;
	uint8 *dest = Mac2HostAddr(dest_origin);

	width *= bpp;
	switch (bpp) {
	case 1:
		for (int i = 0; i < height; i++) {
			memset(dest, color, width);
			if (i + 1 < height) dest += dest_row_bytes;
		}
		break;
	case 2:
		for (int i = 0; i < height; i++) {
			do_fillrect<16>(dest, color, width);
			if (i + 1 < height) dest += dest_row_bytes;
		}
		break;
	case 4:
		for (int i = 0; i < height; i++) {
			do_fillrect<32>(dest, color, width);
			if (i + 1 < height) dest += dest_row_bytes;
		}
		break;
	}
}

/*
 *  Decline to software QuickDraw, flushing queued GPU work first if the op
 *  touches Metal-mapped RAM. Otherwise software QD could read stale pixels,
 *  or have its output overwritten by the late batch.
 */
static inline bool NQD_decline_with_flush(uint32 p)
{
	if (nqd_metal_available &&
		(NQDMetalAddrInBuffer(ReadMacInt32(p + acclSrcBaseAddr)) ||
		 NQDMetalAddrInBuffer(ReadMacInt32(p + acclDestBaseAddr))))
		NQDMetalFlush();
	return false;
}

bool NQD_fillrect_hook(uint32 p)
{
	D(bug("accl_fillrect_hook %08x\n", p));
	NQD_set_dirty_area(p);

	if (!NQD_validate_packet_mapping(p, false))
		return NQD_decline_with_flush(p);
	if (!NQDMetalSupportsTransferMode(ReadMacInt32(p + acclDestPixelSize),
	                                  ReadMacInt32(p + acclTransferMode)))
		return NQD_decline_with_flush(p);

	// Metal path: only patCopy (8) and arithmetic/hilite (32-39, 50) are solid
	// fills. Other pattern modes may carry 8x8 patterns the kernel can't render.
	if (nqd_metal_available && ReadMacInt32(p + 0x284) != 0 &&
		NQDMetalAddrInBuffer(ReadMacInt32(p + acclDestBaseAddr)) &&
		NQD_dest_rect_byte_aligned_for_depth(p, ReadMacInt32(p + acclDestPixelSize))) {
		const int transfer_mode = ReadMacInt32(p + acclTransferMode);
		if (transfer_mode == 8 ||
			(transfer_mode >= 32 && transfer_mode <= 39) ||
			transfer_mode == 50) {
			// Solid fill via Metal (patCopy, arithmetic blend, hilite)
			WriteMacInt32(p + acclDrawProc, NativeTVECT(NATIVE_NQD_FILLRECT));
			return true;
		}
		else if (transfer_mode == 10) {
			// Invert: Mac OS dispatches invert through a separate thunk entry
			WriteMacInt32(p + acclDrawProc, NativeTVECT(NATIVE_NQD_INVRECT));
			return true;
		}
	}

	// CPU fallback: original checks with pixel size >= 8 restriction
	if (ReadMacInt32(p + 0x284) != 0 && ReadMacInt32(p + acclDestPixelSize) >= 8) {
		const int transfer_mode = ReadMacInt32(p + acclTransferMode);
		if (transfer_mode == 8) {
			// Fill
			WriteMacInt32(p + acclDrawProc, NativeTVECT(NATIVE_NQD_FILLRECT));
			return true;
		}
		else if (transfer_mode == 10) {
			// Invert
			WriteMacInt32(p + acclDrawProc, NativeTVECT(NATIVE_NQD_INVRECT));
			return true;
		}
	}
	return NQD_decline_with_flush(p);
}


/*
 *	Isomorphic rectangle blitting
 */

void NQD_bitblt(uint32 p)
{
	D(bug("accl_bitblt %08x\n", p));

	if (!NQD_validate_packet_mapping(p, true)) return;

	// Metal-accelerated path (only if src and dest are within Metal-mapped RAM)
	if (nqd_metal_available &&
		NQDMetalAddrInBuffer(ReadMacInt32(p + acclSrcBaseAddr)) &&
		NQDMetalAddrInBuffer(ReadMacInt32(p + acclDestBaseAddr))) {
		NQDMetalBitblt(p);
		return;
	}

	if (ReadMacInt32(p + acclSrcPixelSize) < 8) return;

	// Get blitting parameters
	int src_X  = (int16)ReadMacInt16(p + acclSrcRect + 2) - (int16)ReadMacInt16(p + acclSrcBoundsRect + 2);
	int src_Y  = (int16)ReadMacInt16(p + acclSrcRect + 0) - (int16)ReadMacInt16(p + acclSrcBoundsRect + 0);
	int dest_X = (int16)ReadMacInt16(p + acclDestRect + 2) - (int16)ReadMacInt16(p + acclDestBoundsRect + 2);
	int dest_Y = (int16)ReadMacInt16(p + acclDestRect + 0) - (int16)ReadMacInt16(p + acclDestBoundsRect + 0);
	int width  = (int16)ReadMacInt16(p + acclDestRect + 6) - (int16)ReadMacInt16(p + acclDestRect + 2);
	int height = (int16)ReadMacInt16(p + acclDestRect + 4) - (int16)ReadMacInt16(p + acclDestRect + 0);
	D(bug(" src addr %08x, dest addr %08x\n", ReadMacInt32(p + acclSrcBaseAddr), ReadMacInt32(p + acclDestBaseAddr)));
	D(bug(" src X %d, src Y %d, dest X %d, dest Y %d\n", src_X, src_Y, dest_X, dest_Y));
	D(bug(" width %d, height %d\n", width, height));

	// And perform the blit
	const int bpp = bytes_per_pixel(ReadMacInt32(p + acclSrcPixelSize));
	width *= bpp;
	const bool backward_rows = (int32)ReadMacInt32(p + acclSrcRowBytes) < 0;
	uint32 src_origin, dst_origin;
	if (!NQD_resolve_mapped_rect(p, true, backward_rows, &src_origin) ||
	    !NQD_resolve_mapped_rect(p, false, backward_rows, &dst_origin)) return;

	NQDMetalFlush();  // ensure pending NQD GPU writes are visible to CPU
	if ((int32)ReadMacInt32(p + acclSrcRowBytes) > 0) {
		const int src_row_bytes = (int32)ReadMacInt32(p + acclSrcRowBytes);
		const int dst_row_bytes = (int32)ReadMacInt32(p + acclDestRowBytes);
		uint8 *src = Mac2HostAddr(src_origin);
		uint8 *dst = Mac2HostAddr(dst_origin);
		for (int i = 0; i < height; i++) {
			memmove(dst, src, width);
			if (i + 1 < height) { src += src_row_bytes; dst += dst_row_bytes; }
		}
	}
	else {
		const int src_row_bytes = -(int32)ReadMacInt32(p + acclSrcRowBytes);
		const int dst_row_bytes = -(int32)ReadMacInt32(p + acclDestRowBytes);
		uint8 *src = Mac2HostAddr(uint32(uint64_t(src_origin) + uint64_t(height - 1) * src_row_bytes));
		uint8 *dst = Mac2HostAddr(uint32(uint64_t(dst_origin) + uint64_t(height - 1) * dst_row_bytes));
		for (int i = height - 1; i >= 0; i--) {
			memmove(dst, src, width);
			if (i > 0) { src -= src_row_bytes; dst -= dst_row_bytes; }
		}
	}
}

/*
  BitBlt transfer modes:
  0 : srcCopy
  1 : srcOr
  2 : srcXor
  3 : srcBic
  4 : notSrcCopy
  5 : notSrcOr
  6 : notSrcXor
  7 : notSrcBic
  32 : blend
  33 : addPin
  34 : addOver
  35 : subPin
  36 : transparent
  37 : adMax
  38 : subOver
  39 : adMin
  50 : hilite
*/

bool NQD_bitblt_hook(uint32 p)
{
	D(bug("accl_draw_hook %08x\n", p));
	NQD_set_dirty_area(p);

	if (!NQD_validate_packet_mapping(p, true))
		return NQD_decline_with_flush(p);
	if (!NQDMetalSupportsTransferMode(ReadMacInt32(p + acclDestPixelSize),
	                                  ReadMacInt32(p + acclTransferMode)))
		return NQD_decline_with_flush(p);

	// This renderer copies rectangles, not arbitrary clipped regions. The
	// separate BLTMASK hook decodes masks; accepting these packets here would
	// erase pixels that QuickDraw's clip excludes (including foreground 3D).
	if (ReadMacInt32(p + 0x018) != 0 || ReadMacInt32(p + 0x128) != 0 ||
		ReadMacInt32(p + 0x130) != 0 || (int32)ReadMacInt32(p + 0x15c) <= 0)
		return NQD_decline_with_flush(p);

	// A negative stride is QuickDraw's backward-traversal hint. Our backward
	// CPU path implements srcCopy only; other transfer modes must run in
	// software QuickDraw instead of silently becoming a copy. INT_MIN cannot
	// be negated by that path even for srcCopy.
	const int32 src_row_bytes = (int32)ReadMacInt32(p + acclSrcRowBytes);
	const int32 dest_row_bytes = (int32)ReadMacInt32(p + acclDestRowBytes);
	if (src_row_bytes == INT32_MIN || dest_row_bytes == INT32_MIN ||
		((src_row_bytes < 0 || dest_row_bytes < 0) &&
		 ReadMacInt32(p + acclTransferMode) != 0))
		return NQD_decline_with_flush(p);

	// Metal path: accept all valid transfer modes when src and dest are in Metal-mapped RAM
	if (nqd_metal_available &&
		NQDMetalAddrInBuffer(ReadMacInt32(p + acclSrcBaseAddr)) &&
		NQDMetalAddrInBuffer(ReadMacInt32(p + acclDestBaseAddr)) &&
		ReadMacInt32(p + acclSrcPixelSize) == ReadMacInt32(p + acclDestPixelSize) &&
		(int32)(ReadMacInt32(p + acclSrcRowBytes) ^ ReadMacInt32(p + acclDestRowBytes)) >= 0 &&
		NQD_bitblt_rects_byte_aligned_for_depth(p, ReadMacInt32(p + acclSrcPixelSize))) {
		const uint32 mode = ReadMacInt32(p + acclTransferMode);
		// Colorizing Boolean source modes (1, 3-7) with a multi-bit source are
		// only well defined for 1-bit sources (IWQD), and the kernel's colorize
		// arm handles only bits_per_pixel == 1. Leave those to software.
		// srcCopy (0) and srcXor (2) are depth-agnostic.
		const uint32 src_px = ReadMacInt32(p + acclSrcPixelSize);
		const bool colorizing_bool = (mode == 1 || (mode >= 3 && mode <= 7));
		if (colorizing_bool && src_px >= 8) {
			// Fall through to the CPU fallback / software QuickDraw.
		} else if (mode <= 7 || (mode >= 32 && mode <= 39) || mode == 50) {
			// The bitblt kernel is unordered. NQDMetalBitblt routes overlapping
			// standard-depth Boolean blits through an ordered CPU path, but
			// packed-depth and arithmetic/hilite overlaps have none, so they
			// go to software.
			if ((src_px < 8 || mode >= 32) &&
				NQDMetalBitbltSameSurfaceOverlap(p)) {
				// Fall through to the CPU fallback / software QuickDraw.
			} else {
				// Unclipped accelerated transfer modes via Metal.
				WriteMacInt32(p + acclDrawProc, NativeTVECT(NATIVE_NQD_BITBLT));
				return true;
			}
		}
	}

	// CPU fallback: srcCopy (mode 0) with matching pixel sizes >= 8
	// Restore mask/clip guards — CPU memmove path can't handle masked or clipped blits.
	if (ReadMacInt32(p + 0x018) + ReadMacInt32(p + 0x128) == 0 &&
		ReadMacInt32(p + 0x130) == 0 &&
		ReadMacInt32(p + acclSrcPixelSize) >= 8 &&
		ReadMacInt32(p + acclSrcPixelSize) == ReadMacInt32(p + acclDestPixelSize) &&
		(int32)(ReadMacInt32(p + acclSrcRowBytes) ^ ReadMacInt32(p + acclDestRowBytes)) >= 0 &&
		ReadMacInt32(p + acclTransferMode) == 0 &&
		(int32)ReadMacInt32(p + 0x15c) > 0) {
		WriteMacInt32(p + acclDrawProc, NativeTVECT(NATIVE_NQD_BITBLT));
		return true;
	}

	return NQD_decline_with_flush(p);
}

// Unknown hook
bool NQD_unknown_hook(uint32 arg)
{
	D(bug("accl_unknown_hook %08x\n", arg));
	NQD_set_dirty_area(arg);

	return false;
}

// Mask operation hooks — validate mask data and set draw procs
// Only accept when dest (and src for bltmask) are in Metal-mapped RAM,
// since there is no CPU fallback for masked operations.
bool NQD_bltmask_hook(uint32 arg)
{
	D(bug("accl_bltmask_hook %08x\n", arg));
	NQD_set_dirty_area(arg);

	if (!NQD_validate_packet_mapping(arg, true))
		return NQD_decline_with_flush(arg);
	if (!NQDMetalSupportsTransferMode(ReadMacInt32(arg + acclDestPixelSize),
	                                  ReadMacInt32(arg + acclTransferMode)))
		return NQD_decline_with_flush(arg);

	if (!nqd_metal_available) return false;

	// Packed Boolean kernels use byte masks; QuickDraw regions can select a
	// single bit pair/nibble within a byte. Decline before publishing a proc.
	if (ReadMacInt32(arg + acclDestPixelSize) < 8)
		return NQD_decline_with_flush(arg);

	// Check src and dest are in Metal-mapped RAM
	if (!NQDMetalAddrInBuffer(ReadMacInt32(arg + acclSrcBaseAddr)) ||
		!NQDMetalAddrInBuffer(ReadMacInt32(arg + acclDestBaseAddr)))
		return NQD_decline_with_flush(arg);

	// Masked GPU threads read and write the same RAM buffer without an
	// ordering guarantee. QuickDraw handles backward traversal and overlapping
	// rectangles; flushing before declining makes prior GPU writes visible.
	if ((int32)ReadMacInt32(arg + acclSrcRowBytes) <= 0 ||
		(int32)ReadMacInt32(arg + acclDestRowBytes) <= 0 ||
		NQDMetalBitbltSameSurfaceOverlap(arg))
		return NQD_decline_with_flush(arg);

	// Validate mask data: check that mask region address is non-zero
	uint32 mask_rgn_addr = ReadMacInt32(arg + 0x128);
	if (mask_rgn_addr == 0) {
		D(bug("  bltmask_hook: null mask region at 0x128, declining\n"));
		return NQD_decline_with_flush(arg);
	}

	// Check the full mapped header before reading size, then the full body
	// before reading the bbox. ROM_AREA_SIZE is the mapped ROM allocation.
	uint16 rgnSize = 0;
	if (!NQDReadMappedRegionSize(mask_rgn_addr, RAMBase, RAMSize,
	                            ROMBase, ROM_AREA_SIZE,
	                            [](uint32_t addr) { return ReadMacInt16(addr); },
	                            &rgnSize)) {
		D(bug("  bltmask_hook: invalid rgnSize %u at 0x%08x, declining\n", rgnSize, mask_rgn_addr));
		return NQD_decline_with_flush(arg);
	}

	// Validate region bbox: top < bottom and left < right
	int16 bbox_top    = (int16)ReadMacInt16(mask_rgn_addr + 2);
	int16 bbox_left   = (int16)ReadMacInt16(mask_rgn_addr + 4);
	int16 bbox_bottom = (int16)ReadMacInt16(mask_rgn_addr + 6);
	int16 bbox_right  = (int16)ReadMacInt16(mask_rgn_addr + 8);
	if (bbox_top >= bbox_bottom || bbox_left >= bbox_right) {
		return NQD_decline_with_flush(arg);
	}

	// Validate pixel size matching (src == dest)
	if (ReadMacInt32(arg + acclSrcPixelSize) != ReadMacInt32(arg + acclDestPixelSize)) {
		return NQD_decline_with_flush(arg);
	}
	if (!NQD_bitblt_rects_byte_aligned_for_depth(arg, ReadMacInt32(arg + acclSrcPixelSize))) {
		return NQD_decline_with_flush(arg);
	}

	const uint32 mode = ReadMacInt32(arg + acclTransferMode);
	if (!(mode <= 7 || (mode >= 32 && mode <= 39) || mode == 50)) {
		return NQD_decline_with_flush(arg);
	}

	D(bug("  bltmask_hook: accepting mask=0x%08x rgnSize=%u mode=%d\n",
		mask_rgn_addr, rgnSize, mode));
	WriteMacInt32(arg + acclDrawProc, NativeTVECT(NATIVE_NQD_BLTMASK));
	return true;
}

bool NQD_fillmask_hook(uint32 arg)
{
	D(bug("accl_fillmask_hook %08x\n", arg));
	NQD_set_dirty_area(arg);

	if (!NQD_validate_packet_mapping(arg, false))
		return NQD_decline_with_flush(arg);
	if (!NQDMetalSupportsTransferMode(ReadMacInt32(arg + acclDestPixelSize),
	                                  ReadMacInt32(arg + acclTransferMode)))
		return NQD_decline_with_flush(arg);

	if (!nqd_metal_available) return false;

	// Packed Boolean kernels use byte masks; QuickDraw regions can select a
	// single bit pair/nibble within a byte. Decline before publishing a proc.
	if (ReadMacInt32(arg + acclDestPixelSize) < 8)
		return NQD_decline_with_flush(arg);

	// Check dest is in Metal-mapped RAM
	if (!NQDMetalAddrInBuffer(ReadMacInt32(arg + acclDestBaseAddr)))
		return NQD_decline_with_flush(arg);

	// Validate mask data: check that mask region address is non-zero
	uint32 mask_rgn_addr = ReadMacInt32(arg + 0x128);
	if (mask_rgn_addr == 0) {
		D(bug("  fillmask_hook: null mask region at 0x128, declining\n"));
		return NQD_decline_with_flush(arg);
	}

	// Check the full mapped header before reading size, then the full body
	// before reading the bbox. ROM_AREA_SIZE is the mapped ROM allocation.
	uint16 rgnSize = 0;
	if (!NQDReadMappedRegionSize(mask_rgn_addr, RAMBase, RAMSize,
	                            ROMBase, ROM_AREA_SIZE,
	                            [](uint32_t addr) { return ReadMacInt16(addr); },
	                            &rgnSize)) {
		D(bug("  fillmask_hook: invalid rgnSize %u at 0x%08x, declining\n", rgnSize, mask_rgn_addr));
		return NQD_decline_with_flush(arg);
	}

	// Validate region bbox: top < bottom and left < right
	int16 bbox_top    = (int16)ReadMacInt16(mask_rgn_addr + 2);
	int16 bbox_left   = (int16)ReadMacInt16(mask_rgn_addr + 4);
	int16 bbox_bottom = (int16)ReadMacInt16(mask_rgn_addr + 6);
	int16 bbox_right  = (int16)ReadMacInt16(mask_rgn_addr + 8);
	if (bbox_top >= bbox_bottom || bbox_left >= bbox_right) {
		return NQD_decline_with_flush(arg);
	}

	// Check 0x284 field (same as fillrect_hook)
	if (ReadMacInt32(arg + 0x284) == 0) {
		return NQD_decline_with_flush(arg);
	}
	if (!NQD_dest_rect_byte_aligned_for_depth(arg, ReadMacInt32(arg + acclDestPixelSize))) {
		return NQD_decline_with_flush(arg);
	}

	const uint32 mode = ReadMacInt32(arg + acclTransferMode);
	if (!((mode >= 8 && mode <= 15) || (mode >= 32 && mode <= 39) || mode == 50)) {
		return NQD_decline_with_flush(arg);
	}

	D(bug("  fillmask_hook: accepting mask=0x%08x rgnSize=%u mode=%d\n",
		mask_rgn_addr, rgnSize, mode));
	WriteMacInt32(arg + acclDrawProc, NativeTVECT(NATIVE_NQD_FILLMASK));
	return true;
}

// Masked draw procs
void NQD_bltmask(uint32 p)
{
	D(bug("accl_bltmask %08x\n", p));

	// Metal-accelerated path (only if src and dest are within Metal-mapped RAM)
	if (nqd_metal_available &&
		NQDMetalAddrInBuffer(ReadMacInt32(p + acclSrcBaseAddr)) &&
		NQDMetalAddrInBuffer(ReadMacInt32(p + acclDestBaseAddr))) {
		NQDMetalBltMask(p);
		return;
	}

	// CPU fallback: decline (return without drawing, Mac OS will use software)
	D(bug("  bltmask: no Metal, falling back to software\n"));
}

void NQD_fillmask(uint32 p)
{
	D(bug("accl_fillmask %08x\n", p));

	// Metal-accelerated path (only if dest is within Metal-mapped RAM)
	if (nqd_metal_available && NQDMetalAddrInBuffer(ReadMacInt32(p + acclDestBaseAddr))) {
		NQDMetalFillMask(p);
		return;
	}

	// CPU fallback: decline (return without drawing, Mac OS will use software)
	D(bug("  fillmask: no Metal, falling back to software\n"));
}

// Wait for graphics operation to finish
bool NQD_sync_hook(uint32 arg)
{
	D(bug("accl_sync_hook %08x\n", arg));
	// Flush any pending batched NQD Metal dispatches so all drawing is
	// committed and visible before Mac OS continues.
	if (nqd_metal_available)
		NQDMetalFlush();
	return true;
}


/*
 *	Install Native QuickDraw acceleration hooks
 */

void VideoInstallAccel(void)
{
	// Install NQD acceleration hooks (one-time only)
	static bool nqd_hooks_installed = false;
	if (!nqd_hooks_installed && PrefsFindBool("nqdaccel")) {
		nqd_hooks_installed = true;
		D(bug("Video: Installing acceleration hooks\n"));

		// Initialize Metal compute infrastructure before registering hooks
		NQDMetalInit();

		uint32 base;

		SheepVar bitblt_hook_info(sizeof(accl_hook_info));
		base = bitblt_hook_info.addr();
		WriteMacInt32(base + 0, NativeTVECT(NATIVE_NQD_BITBLT_HOOK));
		WriteMacInt32(base + 4, NativeTVECT(NATIVE_NQD_SYNC_HOOK));
		WriteMacInt32(base + 8, ACCL_BITBLT);
		NQDMisc(6, bitblt_hook_info.addr());

		SheepVar fillrect_hook_info(sizeof(accl_hook_info));
		base = fillrect_hook_info.addr();
		WriteMacInt32(base + 0, NativeTVECT(NATIVE_NQD_FILLRECT_HOOK));
		WriteMacInt32(base + 4, NativeTVECT(NATIVE_NQD_SYNC_HOOK));
		WriteMacInt32(base + 8, ACCL_FILLRECT);
		NQDMisc(6, fillrect_hook_info.addr());

		// Register hooks for all 8 NQD operation codes.
		// Ops 0 (BITBLT) and 2 (FILLRECT) already registered above.
		// Ops 1 (BLTMASK) and 3 (FILLMASK) get separate mask hooks.
		// Ops 4-7 get the unknown_hook.
		for (int op = 0; op < 8; op++) {
			switch (op) {
			case ACCL_BITBLT:
			case ACCL_FILLRECT:
				continue;
			case ACCL_BLTMASK: {
				SheepVar bltmask_hook_info(sizeof(accl_hook_info));
				base = bltmask_hook_info.addr();
				WriteMacInt32(base + 0, NativeTVECT(NATIVE_NQD_BLTMASK_HOOK));
				WriteMacInt32(base + 4, NativeTVECT(NATIVE_NQD_SYNC_HOOK));
				WriteMacInt32(base + 8, op);
				NQDMisc(6, bltmask_hook_info.addr());
				break;
			}
			case ACCL_FILLMASK: {
				SheepVar fillmask_hook_info(sizeof(accl_hook_info));
				base = fillmask_hook_info.addr();
				WriteMacInt32(base + 0, NativeTVECT(NATIVE_NQD_FILLMASK_HOOK));
				WriteMacInt32(base + 4, NativeTVECT(NATIVE_NQD_SYNC_HOOK));
				WriteMacInt32(base + 8, op);
				NQDMisc(6, fillmask_hook_info.addr());
				break;
			}
			default: {
				SheepVar unknown_hook_info(sizeof(accl_hook_info));
				base = unknown_hook_info.addr();
				WriteMacInt32(base + 0, NativeTVECT(NATIVE_NQD_UNKNOWN_HOOK));
				WriteMacInt32(base + 4, NativeTVECT(NATIVE_NQD_SYNC_HOOK));
				WriteMacInt32(base + 8, op);
				NQDMisc(6, unknown_hook_info.addr());
				break;
			}
			}
		}
	}

	// Called on each accRun tick until the RAVE library is available.
	// Returns immediately once registered.
	if (PrefsFindBool("raveaccel"))
		RaveRegisterEngine();

	// GL/AGL/GLU/GLUT interception. Idempotent.
	if (PrefsFindBool("glaccel"))
		GLInstallHooks();

	// DrawSprocket. DSpInit is idempotent. DSpInstallHooks patches the
	// DrawSprocketLib CFM symbols to our thunks; apps load the library lazily,
	// so it retries on each accRun tick (capped by DSP_HOOKS_MAX_ATTEMPTS).
	if (PrefsFindBool("dspaccel")) {
		DSpInit();
		DSpInstallHooks();
	}
}
