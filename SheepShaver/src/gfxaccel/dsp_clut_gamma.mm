/*
 *  dsp_clut_gamma.mm - DrawSprocket CLUT get/set handlers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Entry points are extern "C" (declared in dsp_draw_context.h); the shared
 *  cores are declared in dsp_clut_gamma.h.
 */
#import <Metal/Metal.h>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "dsp_engine.h"
#include "dsp_draw_context.h"
#include "dsp_mode_enumerate.h"
#include "dsp_context_private.h"
#include "dsp_guest_address.h"
#include "dsp_display_mode_policy.h"
#include "metal_compositor.h"
#include "display_mode_controller.h"
#include "dsp_engine_internal.h"
#include "dsp_clut_gamma.h"

/* CLUT handlers (sub-opcodes 300/301) */

/*
 *  Shared by SetCLUTEntries and the Reserve colorTable path.
 *  entries_host_range holds (last - first + 1) * 3 RGB bytes starting at
 *  offset 0, not a full 768-byte table. Bounds are re-checked defensively.
 */
int32_t DSpSetCLUTCore(DSpContextPrivate *ctx,
                       uint32_t first, uint32_t last,
                       const uint8_t *entries_host_range)
{
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (entries_host_range == nullptr) return kDSpInvalidAttributesErr;
	if (first > 255 || last > 255) return kDSpInvalidAttributesErr;
	if (first > last) return kDSpInvalidAttributesErr;

	/* clut_bytes_latched is left alone: DSpVBLClutLatchCallback copies
	 * clut_bytes into it at the next VBL, so GetCLUTEntries sees the
	 * last-VBL state. */
	const uint32_t count = last - first + 1;
	memcpy(ctx->clut_bytes + first * 3, entries_host_range, count * 3);
	// Indexed front pixels are expanded through this CLUT into a 32-bit
	// compositor surface. Their indices can stay unchanged across a palette
	// animation, so the byte hash alone cannot validate the converted pixels.
	const uint32_t front_depth =
	    DSpDisplayModeDepth(ctx->attr.backBufferBestDepth, ctx->attr.displayBestDepth);
	if (front_depth <= 8)
		ctx->front_staging_present_state.encoded = false;

	/* Push the full 256-entry table so entries set by earlier calls survive.
	 * This fills the back palette; MetalCompositorPaletteLatch promotes it at
	 * the next VBL. */
	if (ctx->state == (uint32_t)kDSpContextState_Active) {
		MetalCompositorUpdatePalette(ctx->clut_bytes, 256);
		dmc_record_palette_change();
	}
	return kDSpNoErr;
}

/*
 *  DSpContext_SetCLUTEntries (sub-opcode 300), DSp 1.7 p.56.
 *  ColorSpecs are 8 bytes: value@+0 (ignored), r@+2, g@+4, b@+6, 16-bit
 *  big-endian. Matches the shipped DrawSprocketLib (and the header's
 *  inLastEntry name) rather than the preliminary PDF: the fourth argument is
 *  a zero-based count like VDSetEntryRecord.csCount, so CLUT entries
 *  [start .. start + inLastEntry] are set, and entry k is read from
 *  inEntries[k]: the table is indexed absolutely, not from the start entry.
 *
 *  Channels are narrowed to 8 bits here; everything internal stays 8-bit.
 *  When the context is not Active the write lands only in clut_bytes, and
 *  DSpContext_SetStateHandler replays it on the next transition to Active.
 */
extern "C" int32_t DSpContext_SetCLUTEntriesHandler(uint32_t ctxRef,
                                                     uint32_t entriesAddr,
                                                     uint32_t inStartingEntry,
                                                     uint32_t inLastEntry)
{
	/* Check ctxRef first so a bad handle wins over a NULL buffer. */
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("SetCLUTEntries: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	if (entriesAddr == 0) {
		DSP_LOG("SetCLUTEntries: NULL entriesAddr (ctxRef=%u start=%u count=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef, inStartingEntry, inLastEntry);
		return kDSpInvalidAttributesErr;
	}
	/* The real library takes both as UInt16. Compare headroom by
	 * subtraction so start + extra can't wrap. */
	inStartingEntry &= 0xFFFFu;
	inLastEntry &= 0xFFFFu;
	if (inStartingEntry > 255 || inLastEntry > 255 - inStartingEntry) {
		DSP_LOG("SetCLUTEntries: out-of-range (ctxRef=%u start=%u count=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef, inStartingEntry, inLastEntry);
		return kDSpInvalidAttributesErr;
	}

	const uint32_t start = inStartingEntry;
	const uint32_t count = inLastEntry + 1;
	const uint32_t last  = start + count - 1;  /* inclusive, for the core */

	/* Stage as host 8-bit RGB so DSpSetCLUTCore never reads guest RAM. */
	uint8_t staged[256 * 3];
	for (uint32_t i = 0; i < count; i++) {
		uint32_t e = entriesAddr + (start + i) * 8;  /* absolute index */
		staged[i * 3 + 0] = (uint8_t)(ReadMacInt16(e + 2) >> 8);  /* r */
		staged[i * 3 + 1] = (uint8_t)(ReadMacInt16(e + 4) >> 8);  /* g */
		staged[i * 3 + 2] = (uint8_t)(ReadMacInt16(e + 6) >> 8);  /* b */
	}

	int32_t rv = DSpSetCLUTCore(ctx, start, last, staged);
	if (rv == kDSpNoErr) {
		DSP_LOG("SetCLUTEntries: ctx=%u start=%u count=%u range=[%u..%u] "
		        "state=%u -> OK",
		        ctxRef, start, count, start, last, ctx->state);
	}
	return rv;
}


/*
 *  Shared by GetCLUTEntries and the fade handlers. Reads clut_bytes_latched,
 *  so callers see the CLUT as of the last VBL, not in-flight Set writes.
 *  The output holds (last - first + 1) * 3 bytes starting at offset 0.
 */
int32_t DSpGetCLUTCore(DSpContextPrivate *ctx,
                               uint32_t first, uint32_t last,
                               uint8_t *entries_out_host_range)
{
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (entries_out_host_range == nullptr) return kDSpInvalidAttributesErr;
	if (first > 255 || last > 255) return kDSpInvalidAttributesErr;
	if (first > last) return kDSpInvalidAttributesErr;

	const uint32_t count = last - first + 1;
	memcpy(entries_out_host_range,
	       ctx->clut_bytes_latched + first * 3,
	       count * 3);
	return kDSpNoErr;
}

/*
 *  DSpContext_GetCLUTEntries (sub-opcode 301), DSp 1.7 p.57.
 *  Same range as SetCLUTEntries, but the entries are written from
 *  outEntries[0]; value@+0 is written as 0.
 *  Reads the VBL-latched CLUT, so a Set followed by a Get in the same VBL
 *  returns the previous palette (DSp palette-animation semantics). Before
 *  any Set the table is all zeros.
 */
extern "C" int32_t DSpContext_GetCLUTEntriesHandler(uint32_t ctxRef,
                                                     uint32_t entriesOutAddr,
                                                     uint32_t inStartingEntry,
                                                     uint32_t inLastEntry)
{
	/* Check ctxRef first so a bad handle wins over a NULL buffer. */
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("GetCLUTEntries: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	if (entriesOutAddr == 0) {
		DSP_LOG("GetCLUTEntries: NULL entriesOutAddr (ctxRef=%u start=%u count=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef, inStartingEntry, inLastEntry);
		return kDSpInvalidAttributesErr;
	}
	inStartingEntry &= 0xFFFFu;
	inLastEntry &= 0xFFFFu;
	if (inStartingEntry > 255 || inLastEntry > 255 - inStartingEntry) {
		DSP_LOG("GetCLUTEntries: out-of-range (ctxRef=%u start=%u count=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef, inStartingEntry, inLastEntry);
		return kDSpInvalidAttributesErr;
	}

	const uint32_t start = inStartingEntry;
	const uint32_t count = inLastEntry + 1;
	const uint32_t last  = start + count - 1;  /* inclusive, for the core */

	uint8_t staged[256 * 3];
	int32_t rv = DSpGetCLUTCore(ctx, start, last, staged);
	if (rv != kDSpNoErr) {
		return rv;
	}

	/* Widen to 16 bits as (v << 8) | v so a Set/Get round trip is stable
	 * at 8-bit precision. */
	for (uint32_t i = 0; i < count; i++) {
		uint32_t e = entriesOutAddr + i * 8;  /* 8-byte ColorSpec stride */
		uint16_t r = (uint16_t)((staged[i * 3 + 0] << 8) | staged[i * 3 + 0]);
		uint16_t g = (uint16_t)((staged[i * 3 + 1] << 8) | staged[i * 3 + 1]);
		uint16_t b = (uint16_t)((staged[i * 3 + 2] << 8) | staged[i * 3 + 2]);
		WriteMacInt16(e + 0, 0);  /* ColorSpec.value (SInt16) */
		WriteMacInt16(e + 2, r);
		WriteMacInt16(e + 4, g);
		WriteMacInt16(e + 6, b);
	}

	DSP_LOG("GetCLUTEntries: ctx=%u start=%u count=%u range=[%u..%u] "
	        "state=%u -> OK",
	        ctxRef, start, count, start, last, ctx->state);
	return kDSpNoErr;
}

/*
 *  Reads the FadeGamma zero-intensity RGBColor (6 bytes, 16-bit big-endian
 *  r@+0, g@+2, b@+4; DSp 1.7 pp.32-35) and keeps the high byte of each
 *  channel. The caller handles colorAddr == 0 (black).
 */
void DSpReadParametricColorFromGuest(uint32_t colorAddr,
                                              uint8_t *out_r,
                                              uint8_t *out_g,
                                              uint8_t *out_b)
{
	*out_r = (uint8_t)(ReadMacInt16(colorAddr + 0) >> 8);
	*out_g = (uint8_t)(ReadMacInt16(colorAddr + 2) >> 8);
	*out_b = (uint8_t)(ReadMacInt16(colorAddr + 4) >> 8);
}


