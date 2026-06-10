/*
 *  dsp_clut_gamma.mm - DrawSprocket CLUT + gamma get/set handlers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Extracted verbatim from dsp_draw_context.mm (de-bloat, NO behaviour change):
 *  the CLUT Set/Get cores + handlers, the gamma Set/Get cores + handlers, the
 *  guest LUT/parametric-colour read/write helpers, and their DSpTesting_*
 *  wrappers. The gamma FADE subsystem stays in dsp_draw_context.mm. Entry points
 *  are extern "C" (declared in dsp_draw_context.h); the 2 cores the fade code
 *  reuses are declared in dsp_clut_gamma.h.
 */
#import <Metal/Metal.h>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"                /* SheepMem::Reserve (test hook) */
#include "dsp_engine.h"
#include "dsp_event_record.h"      /* DSpEventRecord struct */
#include "dsp_draw_context.h"
#include "dsp_mode_enumerate.h"    /* DSpFindBestContextHandler / DSpTesting_FindBestContextByStruct delegate target */
#include "dsp_user_select_policy.h"
#include "dsp_context_private.h"   /* DSpContextPrivate full struct; shared with dsp_metal_renderer.mm */
#include "dsp_cgraf_port_policy.h"
#include "dsp_default_clut.h"
#include "dsp_display_id_policy.h"
#include "dsp_display_mode_policy.h"
#include "dsp_front_buffer_policy.h"
#include "dsp_front_staging_seed_policy.h"
#include "dsp_get_attributes_policy.h"
#include "dsp_guest_address.h"
#include "dsp_main_device_redirect_policy.h"
#include "dsp_quickdraw_restore_policy.h"
#include "dsp_vbl_publish_policy.h"
#include "dsp_pixmap_offsets.h"    /* PixMap field offsets + LMADDR_MAIN_DEVICE / GDEVICE_OFF_PMAP */
#include "dsp_metal_renderer.h"    /* DSpAllocateBackBuffer / DSpEncodeBackBufferBlit / DSpGetBackBufferCGrafPtr */
#include "gfxaccel_resources.h"    /* per-buffer owner-tag API */
#include "gfxaccel_resources_heap.h" /* kHeapEngineDSp + heap_alloc_buffer for AltBuffer backing */
#include "dsp_alt_buffer.h"        /* AltBuffer subsystem: record table + handlers (extracted) */
#include "nqd_accel.h"               /* NQDMetalBitblt1to1 / NQDMetalBitbltScaled / NQDMetalFlush for DSpBlit */
#include "metal_compositor.h"      /* MetalCompositorSubmitFrame + MetalCompositorGetFramebufferTexture + CompositeLayer */
#include "metal_device_shared.h"   /* SharedMetalCommandQueue (SwapBuffers blit path) */
#include "display_mode_controller.h" /* dmc_current_snapshot (FrameDescriptor generation); DMCOwner enum + dmc_set_active_owner */
#include "dsp_engine_internal.h"   /* DSpMapStateToDMCOwnerTyped (internal-only, NOT in include/) */
#include "vbl_source.h"
#include "dsp_clut_gamma.h"

/* ============================================================== */
/*  CLUT handlers (sub-opcodes 300/301)                            */
/*                                                                  */
/*  DSpContext_SetCLUTEntriesHandler: validation + clut_bytes write */
/*  + MetalCompositorUpdatePalette + dmc_record_palette_change.     */
/*  DSpContext_GetCLUTEntriesHandler: validation + read from        */
/*  ctx->clut_bytes_latched.                                        */
/* ============================================================== */

/*
 *  Core write path
 *  shared by the production handler and the TESTING_BUILD host-struct
 *  wrapper. `entries_host_range` points to (last - first + 1) * 3 bytes
 *  of R/G/B data — NOT a 768-byte buffer; the caller's responsibility is
 *  to lay out the partial range starting at offset 0. This core helper
 *  only handles the post-validation write + compositor push + DMC bump.
 *
 *  Validation here re-checks ctx != null + bounds/ordering as a defensive
 *  second-layer because the testing wrapper also calls this path — but
 *  the production handler has already checked the same invariants, so
 *  the re-check is cheap.
 */
static int32_t DSpSetCLUTCore(DSpContextPrivate *ctx,
                               uint32_t first, uint32_t last,
                               const uint8_t *entries_host_range)
{
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (entries_host_range == nullptr) return kDSpInvalidAttributesErr;
	if (first > 255 || last > 255) return kDSpInvalidAttributesErr;
	if (first > last) return kDSpInvalidAttributesErr;

	/* Write into per-context storage at offset first*3. The
	 * reader-visible clut_bytes_latched is NOT touched here —
	 * DSpVBLClutLatchCallback drains clut_bytes -> clut_bytes_latched at
	 * the next VBL tick, giving GetCLUTEntries last-VBL-
	 * boundary semantics. */
	const uint32_t count = last - first + 1;
	memcpy(ctx->clut_bytes + first * 3, entries_host_range, count * 3);

	/* When Active, push the FULL 256-entry table so
	 * entries outside [first..last] set by earlier Set calls survive.
	 * MetalCompositorUpdatePalette writes into the back palette buffer;
	 * MetalCompositorPaletteLatch (VBL callback) promotes
	 * back -> front at the next frame boundary. */
	if (ctx->state == (uint32_t)kDSpContextState_Active) {
		MetalCompositorUpdatePalette(ctx->clut_bytes, 256);
		/* DMC bump: dmc_record_palette_change is the public DMC
		 * API — a function call, not a direct generation-counter
		 * assignment. The DMC write-site CI gate
		 * (testNoDirectDMCWritesInDSpFiles) scans for the bare-word
		 * DMC-owned identifier set followed by an assignment, which does
		 * NOT match this function-call syntax. */
		dmc_record_palette_change();
	}
	return kDSpNoErr;
}

/*
 *  DSpContext_SetCLUTEntries (sub-opcode 300).
 *
 *  Argument contract (DSp 1.7 p.56 — corrected wire-format;
 *  pointer-before-index arg order):
 *    ctxRef          = context handle from DSpContext_Reserve
 *    entriesAddr     = guest Mac address of inEntryCount x 8-byte ColorSpec
 *                      structs (ColorSpec = { SInt16 value; RGBColor rgb })
 *                      with 16-bit big-endian channels: value@+0 (ignored
 *                      for Set), r@+2, g@+4, b@+6 — read via ReadMacInt16
 *    inStartingEntry = first CLUT index to write; must be <= 255
 *    inEntryCount    = number of entries (a COUNT, NOT an inclusive last
 *                      index); must be > 0; inStartingEntry + inEntryCount
 *                      must be <= 256 (a full-CLUT replace is start=0,
 *                      count=256)
 *
 *  Wire-format boundary: the 16->8 down-convert (>> 8)
 *  happens HERE at the guest-RAM read loop ONLY. Internal clut_bytes
 *  storage + DSpSetCLUTCore + the VBL latch stay 3-byte/8-bit, so the
 *  composited pixels (which sample the latched 8-bit values) are
 *  byte-identical and DSpIndexedDepthCompositeTests is undisturbed. The
 *  compositor-side 16/32-bpp sampling is the CC-1 boundary.
 *
 *  Error map:
 *    kDSpInvalidContextErr    - ctxRef does not resolve to a context
 *    kDSpInvalidAttributesErr - entriesAddr == 0 OR inStartingEntry > 255
 *                                OR inEntryCount == 0 OR
 *                                inStartingEntry + inEntryCount > 256
 *    kDSpNoErr                - success; compositor push if
 *                                ctx is Active, deferred otherwise
 *
 *  Compositor contract:
 *    When ctx is Active, MetalCompositorUpdatePalette pushes the full
 *    256-entry ctx->clut_bytes into the compositor's back palette
 *    buffer; the compositor's VBL-callback MetalCompositorPaletteLatch
 *    promotes back -> front at
 *    the next frame boundary. The per-context clut_bytes_latched buffer
 *    is drained by DSpVBLClutLatchCallback (not touched
 *    here); GetCLUTEntries reads clut_bytes_latched.
 *
 *  DMC contract:
 *    dmc_record_palette_change() fires AFTER a successful compositor
 *    push (Active only) to bump persisted_palette_generation — ONLY
 *    through the public DMC API, never a direct generation-counter
 *    assignment.
 *
 *  Paused persistence:
 *    When ctx->state != Active, the write lands only in ctx->clut_bytes.
 *    The Paused -> Active transition inside DSpContext_SetStateHandler
 *    replays the stored clut_bytes via the same
 *    MetalCompositorUpdatePalette + dmc_record_palette_change pair.
 */
extern "C" int32_t DSpContext_SetCLUTEntriesHandler(uint32_t ctxRef,
                                                     uint32_t entriesAddr,
                                                     uint32_t inStartingEntry,
                                                     uint32_t inEntryCount)
{
	/* Validate ctxRef first so a bad handle + NULL entriesAddr reports
	 * the more specific kDSpInvalidContextErr. */
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("SetCLUTEntries: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	/* Validate entriesAddr next — a NULL buffer on a valid context is
	 * reported as kDSpInvalidAttributesErr so the app can distinguish
	 * it from a bad handle. */
	if (entriesAddr == 0) {
		DSP_LOG("SetCLUTEntries: NULL entriesAddr (ctxRef=%u start=%u count=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef, inStartingEntry, inEntryCount);
		return kDSpInvalidAttributesErr;
	}
	/* Range-check BEFORE any guest-RAM read (ASVS V5):
	 * inEntryCount is a COUNT (not an inclusive last index). Reading
	 * past entry 255 would write beyond the 768-byte clut_bytes buffer.
	 * inStartingEntry + inEntryCount must be <= 256 (a full-CLUT replace
	 * is start=0, count=256). Both operands are guest-controlled uint32
	 * (r5/r6), so the headroom MUST be compared by subtraction rather than
	 * by summing — `inStartingEntry + inEntryCount` would wrap in 32-bit
	 * unsigned arithmetic (CWE-190) and defeat the guard (e.g. start=1,
	 * count=0xFFFFFFFF -> sum=0). The first clause guarantees
	 * inStartingEntry <= 255, so `256 - inStartingEntry` is in [1..256] and
	 * never underflows. */
	if (inStartingEntry > 255 || inEntryCount == 0 ||
	    inEntryCount > 256 - inStartingEntry) {
		DSP_LOG("SetCLUTEntries: out-of-range (ctxRef=%u start=%u count=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef, inStartingEntry, inEntryCount);
		return kDSpInvalidAttributesErr;
	}

	const uint32_t start = inStartingEntry;
	const uint32_t count = inEntryCount;
	const uint32_t last  = start + count - 1;  /* inclusive, for the core */

	/* Read guest-RAM entries into a host-local 3-byte/8-bit staging
	 * range. The guest passes an array of 8-byte ColorSpec structs
	 * (DSp 1.7 p.56): value@+0 (SInt16, ignored for Set), r@+2, g@+4,
	 * b@+6 — 16-bit big-endian channels via ReadMacInt16. Down-convert
	 * 16->8 (>> 8) at this guest-RAM boundary ONLY so
	 * the internal clut_bytes storage + DSpSetCLUTCore stay 8-bit and
	 * the composited pixels (which sample the latched 8-bit values) are
	 * byte-identical. The staging buffer keeps DSpSetCLUTCore pure-host
	 * so the TESTING_BUILD wrapper shares the same validation + write
	 * path. */
	uint8_t staged[256 * 3];  /* 768 bytes — compile-time sized for worst case */
	for (uint32_t i = 0; i < count; i++) {
		uint32_t e = entriesAddr + i * 8;  /* 8-byte ColorSpec stride */
		staged[i * 3 + 0] = (uint8_t)(ReadMacInt16(e + 2) >> 8);  /* r */
		staged[i * 3 + 1] = (uint8_t)(ReadMacInt16(e + 4) >> 8);  /* g */
		staged[i * 3 + 2] = (uint8_t)(ReadMacInt16(e + 6) >> 8);  /* b */
	}

	/* Defer to core helper for the validated write + compositor push +
	 * DMC bump. ctx/start/last/staged are already validated, so
	 * DSpSetCLUTCore's defensive re-checks are no-ops on this path. The
	 * core is UNCHANGED — it still takes an inclusive (first, last) range
	 * + a 3-byte host buffer. */
	int32_t rv = DSpSetCLUTCore(ctx, start, last, staged);
	if (rv == kDSpNoErr) {
		DSP_LOG("SetCLUTEntries: ctx=%u start=%u count=%u range=[%u..%u] "
		        "state=%u -> OK",
		        ctxRef, start, count, start, last, ctx->state);
	}
	return rv;
}

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD wrapper — host-struct pattern (see
 *  DSpTesting_InvalBackBufferRectByValue / DSpTesting_GetStateByStruct).
 *  Accepts a host-memory (last-first+1)*3 byte array instead of a
 *  guest Mac address. Bypasses the ReadMacInt8 loop entirely.
 *
 *  This 3-byte/8-bit host-struct wrapper is UNCHANGED by the
 *  ColorSpec wire-path: DSpIndexedDepthCompositeTests (the known-flaky
 *  byte-exact composite baseline) drives it with a 3-byte knownCLUT and
 *  must not be destabilized. The 8-byte ColorSpec wire-path is exercised
 *  by the SEPARATE DSpTesting_SetCLUTEntriesByColorSpec wrapper below
 *  (used by DSpPaletteTests + DSpCLUTAnimationTests). Both ultimately
 *  land identical 8-bit values in clut_bytes via DSpSetCLUTCore.
 */
extern "C" int32_t DSpTesting_SetCLUTEntriesByStruct(uint32_t ctxRef,
                                                     uint32_t first,
                                                     uint32_t last,
                                                     const uint8_t *entries_host)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (entries_host == nullptr) return kDSpInvalidAttributesErr;
	if (first > 255 || last > 255) return kDSpInvalidAttributesErr;
	if (first > last) return kDSpInvalidAttributesErr;
	return DSpSetCLUTCore(ctx, first, last, entries_host);
}

/*
 *  TESTING_BUILD wrapper — 8-byte ColorSpec
 *  wire-path. Bypasses the guest-RAM ReadMacInt16 loop but exercises the
 *  REAL 16->8 down-convert the production handler does: `entries_host`
 *  points to a host-memory array of `inEntryCount` 8-byte ColorSpec
 *  structs (value@+0 SInt16 ignored, 16-bit big-endian r@+2/g@+4/b@+6).
 *  Arg order matches production: (ctxRef, entries_host, inStartingEntry,
 *  inEntryCount) — pointer-before-index. Used by DSpPaletteTests +
 *  DSpCLUTAnimationTests; the production path
 *  (DSpContext_SetCLUTEntriesHandler) remains authoritative for real apps.
 */
extern "C" int32_t DSpTesting_SetCLUTEntriesByColorSpec(uint32_t ctxRef,
                                                        const uint8_t *entries_host,
                                                        uint32_t inStartingEntry,
                                                        uint32_t inEntryCount)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (entries_host == nullptr) return kDSpInvalidAttributesErr;
	/* Overflow-safe headroom check (CWE-190) — mirror production
	 * DSpContext_SetCLUTEntriesHandler: never sum guest-controlled
	 * operands. The first clause bounds inStartingEntry <= 255, so
	 * 256 - inStartingEntry is in [1..256] and cannot underflow. */
	if (inStartingEntry > 255 || inEntryCount == 0 ||
	    inEntryCount > 256 - inStartingEntry) {
		return kDSpInvalidAttributesErr;
	}

	const uint32_t start = inStartingEntry;
	const uint32_t count = inEntryCount;
	const uint32_t last  = start + count - 1;

	/* Mirror the production 8-byte ColorSpec / 16-bit-big-endian read +
	 * 16->8 down-convert, but from a host buffer instead of guest RAM. */
	uint8_t staged[256 * 3];
	for (uint32_t i = 0; i < count; i++) {
		const uint8_t *e = entries_host + i * 8;  /* 8-byte ColorSpec stride */
		/* value@+0 (SInt16) ignored; channels are 16-bit big-endian. */
		staged[i * 3 + 0] = e[2];  /* r high byte */
		staged[i * 3 + 1] = e[4];  /* g high byte */
		staged[i * 3 + 2] = e[6];  /* b high byte */
	}
	return DSpSetCLUTCore(ctx, start, last, staged);
}
#endif

/*
 *  Core read path shared by the production
 *  handler and the TESTING_BUILD host-struct wrapper. Reads
 *  (last - first + 1) * 3 bytes from ctx->clut_bytes_latched into the
 *  caller's host buffer. Defensive validation re-checks ctx != null +
 *  bounds/ordering so the testing wrapper shares the same guarantees as
 *  the production handler.
 *
 *  Reads from clut_bytes_latched (NOT clut_bytes) per the VBL-barrier
 *  contract: GetCLUTEntries returns the last-VBL-boundary CLUT state, not
 *  the in-flight SetCLUTEntries write. DSpVBLClutLatchCallback drains
 *  clut_bytes -> clut_bytes_latched on every VBL tick.
 *
 *  `entries_out_host_range` points to (last - first + 1) * 3 bytes of
 *  output storage starting at offset 0 (NOT offset first*3) — the caller
 *  lays out the partial range compactly. Symmetric with DSpSetCLUTCore's
 *  input-range contract.
 */
int32_t DSpGetCLUTCore(DSpContextPrivate *ctx,
                               uint32_t first, uint32_t last,
                               uint8_t *entries_out_host_range)
{
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (entries_out_host_range == nullptr) return kDSpInvalidAttributesErr;
	if (first > 255 || last > 255) return kDSpInvalidAttributesErr;
	if (first > last) return kDSpInvalidAttributesErr;

	/* Read from the LATCHED snapshot, not the writer-visible
	 * clut_bytes. The caller's output buffer layout is (last-first+1)*3
	 * bytes starting at offset 0. */
	const uint32_t count = last - first + 1;
	memcpy(entries_out_host_range,
	       ctx->clut_bytes_latched + first * 3,
	       count * 3);
	return kDSpNoErr;
}

/*
 *  DSpContext_GetCLUTEntries (sub-opcode 301).
 *
 *  Argument contract (DSp 1.7 p.57 — corrected wire-format;
 *  symmetric with SetCLUTEntries, pointer-before-index arg order):
 *    ctxRef          = context handle from DSpContext_Reserve
 *    entriesOutAddr  = guest Mac address to receive inEntryCount x 8-byte
 *                      ColorSpec structs (value@+0 = 0, 16-bit big-endian
 *                      r@+2/g@+4/b@+6 via WriteMacInt16)
 *    inStartingEntry = first CLUT index to read; must be <= 255
 *    inEntryCount    = number of entries (a COUNT, NOT an inclusive last
 *                      index); must be > 0; inStartingEntry + inEntryCount
 *                      must be <= 256
 *
 *  Wire-format boundary: the internal clut_bytes_latched
 *  storage stays 3-byte/8-bit; the 8->16 up-convert (high byte preserved,
 *  (value << 8) | value) happens HERE at the guest-RAM write loop ONLY.
 *
 *  Error map:
 *    kDSpInvalidContextErr    - ctxRef does not resolve to a context
 *    kDSpInvalidAttributesErr - entriesOutAddr == 0 OR inStartingEntry > 255
 *                                OR inEntryCount == 0 OR
 *                                inStartingEntry + inEntryCount > 256
 *    kDSpNoErr                - success; inEntryCount x 8-byte ColorSpec
 *                                written to guest RAM at entriesOutAddr
 *
 *  VBL-latched read contract:
 *    Reads from ctx->clut_bytes_latched — the snapshot maintained by
 *    DSpVBLClutLatchCallback (memcpy clut_bytes ->
 *    clut_bytes_latched on every VBL tick). A SetCLUTEntries +
 *    GetCLUTEntries pair within the same VBL window sees the PREVIOUS
 *    VBL's palette via Get — DSp 1.7's palette-animation contract.
 *
 *  Initial-state contract:
 *    ctx->clut_bytes_latched is zero-initialized by `new
 *    DSpContextPrivate()` (POD default-init). A
 *    GetCLUTEntries before any SetCLUTEntries returns all-zero bytes.
 *
 *  Non-mutating: Get does not call MetalCompositorUpdatePalette and does
 *  not call dmc_record_palette_change — DMC write-site CI gate stays
 *  zero-match because this handler touches only ctx->clut_bytes_latched
 *  (long-suffix name not in the forbidden-identifier regex).
 */
extern "C" int32_t DSpContext_GetCLUTEntriesHandler(uint32_t ctxRef,
                                                     uint32_t entriesOutAddr,
                                                     uint32_t inStartingEntry,
                                                     uint32_t inEntryCount)
{
	/* Validate ctxRef first so a bad handle + NULL entriesOutAddr reports
	 * the more specific kDSpInvalidContextErr. */
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("GetCLUTEntries: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	/* Validate entriesOutAddr — NULL output buffer on a valid context is
	 * reported as kDSpInvalidAttributesErr so the app can distinguish it
	 * from a bad handle. */
	if (entriesOutAddr == 0) {
		DSP_LOG("GetCLUTEntries: NULL entriesOutAddr (ctxRef=%u start=%u count=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef, inStartingEntry, inEntryCount);
		return kDSpInvalidAttributesErr;
	}
	/* Range-check BEFORE the write loop (ASVS V5):
	 * inEntryCount is a COUNT (not an inclusive last index). Compare the
	 * headroom by subtraction, never by summing the two guest-controlled
	 * uint32 operands — `inStartingEntry + inEntryCount` would wrap in
	 * 32-bit unsigned arithmetic (CWE-190) and defeat the guard. The first
	 * clause bounds inStartingEntry <= 255, so 256 - inStartingEntry is in
	 * [1..256] and cannot underflow. */
	if (inStartingEntry > 255 || inEntryCount == 0 ||
	    inEntryCount > 256 - inStartingEntry) {
		DSP_LOG("GetCLUTEntries: out-of-range (ctxRef=%u start=%u count=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef, inStartingEntry, inEntryCount);
		return kDSpInvalidAttributesErr;
	}

	const uint32_t start = inStartingEntry;
	const uint32_t count = inEntryCount;
	const uint32_t last  = start + count - 1;  /* inclusive, for the core */

	/* Read from the latched snapshot into a host-local 3-byte
	 * staging buffer. DSpGetCLUTCore re-validates as a defensive second
	 * layer (cheap; no-op on this path because we just validated above)
	 * and is UNCHANGED (still takes an inclusive (first, last) range +
	 * a 3-byte output buffer). */
	uint8_t staged[256 * 3];  /* 768 bytes — compile-time sized for worst case */
	int32_t rv = DSpGetCLUTCore(ctx, start, last, staged);
	if (rv != kDSpNoErr) {
		/* Shouldn't happen — we validated above — but defensive return. */
		return rv;
	}

	/* Egress: write the staged bytes into guest RAM as 8-byte ColorSpec
	 * structs (DSp 1.7 p.57): value@+0 = 0 (the SInt16 ColorSpec value
	 * field), 16-bit big-endian r@+2/g@+4/b@+6 via WriteMacInt16. The
	 * 8->16 up-convert preserves the high byte ((value << 8) | value) so
	 * a Set->Get round-trip returns the same ColorSpec at 8-bit precision
	 * (wire-format boundary). */
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

/* ================================================================== */
/*                                                                    */
/*  DSp Gamma + Fade handlers (sub-opcodes 400..404).                 */
/*  SetGamma / GetGamma handlers; FadeGammaIn / FadeGammaOut          */
/*  handlers plus the DSpVBLGammaFadeCallback inner body; and the     */
/*  parametric FadeGamma handler.                                     */
/*                                                                    */
/* ================================================================== */

/*
 *  Classic Mac GammaTable convention:
 *  read 768 bytes (256 R + 256 G + 256 B planar) from guest Mac RAM at
 *  tableAddr + 24, staging into the caller's host buffer. The 24-byte
 *  offset is the classic Mac GammaTable header size (gVersion + gType +
 *  gFormulaSize + gChanCnt + gDataCnt + gDataWidth = 12 bytes; followed
 *  by 12 bytes of gFormulaData per the Inside Macintosh: Imaging With
 *  QuickDraw ch.4 layout). The 768-byte LUT block starts at offset 24.
 *
 *  If a future researcher confirms a different DSp 1.7 header offset
 *  (e.g., DSp passes the gLUTData pointer directly rather than the
 *  GammaTable* pointer), this helper is the single replacement point —
 *  the rest of the handler is offset-agnostic.
 *
 *  Defensive: caller has already validated tableAddr != 0; this helper
 *  trusts that invariant.
 */
static void DSpReadGammaLUTFromGuest(uint32_t tableAddr,
                                      uint8_t *out_lut_768)
{
	for (uint32_t i = 0; i < 768; i++) {
		out_lut_768[i] = (uint8_t)ReadMacInt8(tableAddr + 24 + i);
	}
}

/*
 *  FadeGamma ABI fidelity:
 *  read the classic Mac 16-bit RGBColor zero-intensity tint from guest
 *  Mac RAM at colorAddr.
 *
 *  RGBColor = { UInt16 red; UInt16 green; UInt16 blue; } = 6 bytes,
 *  big-endian (DSp 1.7 pp.32-35; standard Toolbox layout). The DSp 1.7
 *  FadeGamma trio passes a `RGBColor *inZeroIntensityColor`, NOT the
 *  iOS-simplified 3-byte/8-bit packed color the earlier prototype read.
 *  Channels are read via ReadMacInt16 at r@+0, g@+2, b@+4 (NOT
 *  ReadMacInt8 at +0/+1/+2) so guest addresses stay in the emulated
 *  address space and the VM layer bounds-checks them
 *  (arm64 >4GiB UB avoidance — never host-pointer casts).
 *
 *  The internal LUT machinery (DSpComputeFadeGammaTargetLUT) stays
 *  8-bit, so we down-convert each 16-bit channel to 8-bit by taking the
 *  high byte (>> 8) — the classic Mac convention where the 8-bit value
 *  lives in the high byte of each 16-bit channel. This is the SINGLE
 *  replacement point flagged by the original in-code comment.
 *
 *  Defensive: caller has already validated colorAddr != 0; this helper
 *  trusts that invariant. (NULL colorAddr -> black is handled by the
 *  caller BEFORE this helper is reached.)
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

/*
 *  Core SetGamma path
 *  shared by the production handler and the TESTING_BUILD host-LUT wrapper.
 *  `lut_host_768` points to a 768-byte planar R/G/B LUT in host memory.
 *
 *  Validation here re-checks ctx != null + lut_host_768 != null as a
 *  defensive second-layer because the testing wrapper also calls this
 *  path — the production handler has already checked the same invariants,
 *  so the re-check is cheap.
 *
 *  Sequence (cancellation BEFORE DMC push):
 *    1. Cancel any active fade: set fade_state.active = 0.
 *    2. Push LUT to DMC: dmc_record_gamma_change_with_lut(lut).
 *       This atomically publishes a fresh DMC snapshot with bumped
 *       generation counter; the compositor's existing VBL gamma block at
 *       metal_compositor.mm:272-278 picks up the change at the next
 *       VBL via the s_last_gamma_gen pattern.
 *    3. Update per-context persistence: memcpy lut into
 *       ctx->gamma_lut_persisted for Pause→Resume replay.
 */
static int32_t DSpSetGammaCore(DSpContextPrivate *ctx,
                                const uint8_t *lut_host_768)
{
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (lut_host_768 == nullptr) return kDSpInvalidAttributesErr;

	/* Cancel any in-flight fade. SetGamma overrides per spec p.74. */
	if (ctx->fade_state.active != 0) {
		DSP_LOG("SetGamma: cancelling active fade (ctx=%u, elapsed=%u/%u)",
		        ctx->handle,
		        (unsigned)ctx->fade_state.elapsed_vbls,
		        (unsigned)ctx->fade_state.duration_vbls);
		ctx->fade_state.active = 0;
	}

	/* DMC owns the live gamma. Push LUT through the public API;
	 * never bare-write the DMC-owned generation counter / LUT storage
	 * (CI gate enforces). */
	int32_t rv = dmc_record_gamma_change_with_lut(lut_host_768);
	if (rv != kDMCNoErr) {
		DSP_LOG("SetGamma: dmc_record_gamma_change_with_lut returned %d",
		        rv);
		return kDSpInternalErr;
	}

	/* Per-context persistence buffer for Pause→Resume replay. */
	memcpy(ctx->gamma_lut_persisted, lut_host_768, 768);

	return kDSpNoErr;
}

/*
 *  DSpContext_SetGamma (sub-opcode 400).
 *
 *  Argument contract:
 *    ctxRef    = context handle from DSpContext_Reserve
 *    tableAddr = guest Mac address of a GammaTable struct (24-byte
 *                header + 12 bytes formula data + 768 bytes LUT data
 *                in planar R/G/B layout). Header bytes are owned by
 *                the caller; this handler reads only the LUT block
 *                at tableAddr + 24.
 *
 *  Error map:
 *    kDSpInvalidContextErr    - ctxRef does not resolve to a context
 *    kDSpInvalidAttributesErr - tableAddr == 0
 *    kDSpInternalErr          - dmc_record_gamma_change_with_lut failed
 *                                (e.g., DMC in Quiescent state, OOM)
 *    kDSpNoErr                - success; LUT pushed to DMC; persistence
 *                                buffer updated; any active fade cancelled
 *
 *  DMC contract:
 *    dmc_record_gamma_change_with_lut() atomically publishes a fresh
 *    DMC snapshot with bumped generation counter + the new 768-byte LUT.
 *    The compositor's existing VBL gamma block at metal_compositor.mm:272-278
 *    picks up the change at the next VBL via the s_last_gamma_gen
 *    pattern. Adds ZERO compositor edits.
 *
 *  Active-fade cancellation:
 *    If ctx->fade_state.active != 0, the new SetGamma overrides the
 *    in-flight fade per DSp 1.7 spec p.74. Cancellation is a single
 *    uint8_t write to fade_state.active = 0; the new SetGamma's DMC
 *    push is the authoritative final state.
 *
 *  Persistence:
 *    After the DMC push succeeds, the staged LUT is memcpy'd into
 *    ctx->gamma_lut_persisted so the Pause→Resume path (which may
 *    add the SetState replay arm if device UAT shows DSp games depend
 *    on per-context gamma persistence) re-pushes the persisted LUT.
 */
extern "C" int32_t DSpContext_SetGammaHandler(uint32_t ctxRef,
                                               uint32_t tableAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("SetGamma: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	if (tableAddr == 0) {
		DSP_LOG("SetGamma: NULL tableAddr (ctxRef=%u) -> kDSpInvalidAttributesErr",
		        ctxRef);
		return kDSpInvalidAttributesErr;
	}

	/* Stage LUT from guest Mac RAM into a host-local 768-byte buffer.
	 * The guest may free the GammaTable immediately after SetGamma
	 * returns, so we must copy out before any DMC call. */
	uint8_t staged[768];
	DSpReadGammaLUTFromGuest(tableAddr, staged);

	/* Defer to core helper for the cancellation + DMC push + persistence
	 * write. ctx + staged are already validated, so DSpSetGammaCore's
	 * defensive re-checks are no-ops on this path. */
	int32_t rv = DSpSetGammaCore(ctx, staged);
	if (rv == kDSpNoErr) {
		DSP_LOG("SetGamma: ctx=%u tableAddr=0x%08x state=%u -> OK",
		        ctxRef, tableAddr, ctx->state);
	}
	return rv;
}

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD wrapper — host-LUT pattern (mirrors
 *  DSpTesting_SetCLUTEntriesByStruct). Accepts a 768-byte host-memory
 *  LUT instead of a guest Mac GammaTable* address. Bypasses the
 *  DSpReadGammaLUTFromGuest loop entirely.
 *
 *  Used by DSpGammaTests to exercise SetGamma at simulator
 *  speed without guest-RAM plumbing. The production path
 *  (DSpContext_SetGammaHandler) remains authoritative for real apps.
 */
extern "C" int32_t DSpTesting_SetGammaByLUT(uint32_t ctxRef,
                                              const uint8_t *lut_host_768)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (lut_host_768 == nullptr) return kDSpInvalidAttributesErr;
	return DSpSetGammaCore(ctx, lut_host_768);
}
#endif

/*
 *  Classic Mac GammaTable convention:
 *  write 768 bytes (256 R + 256 G + 256 B planar) into guest Mac RAM
 *  at tableOutAddr + 24. Symmetric with DSpReadGammaLUTFromGuest's
 *  24-byte header skip — the GammaTable header bytes (gVersion, gType,
 *  etc.) are owned by the caller and unchanged by this handler.
 *
 *  Defensive: caller has already validated tableOutAddr != 0; this
 *  helper trusts that invariant.
 */
static void DSpWriteGammaLUTToGuest(uint32_t tableOutAddr,
                                      const uint8_t *lut_768)
{
	for (uint32_t i = 0; i < 768; i++) {
		WriteMacInt8(tableOutAddr + 24 + i, lut_768[i]);
	}
}

/*
 *  Core GetGamma path shared by the
 *  production handler and the TESTING_BUILD host-LUT wrapper. Reads
 *  the current DMC snapshot's gamma_lut[768] into the caller's
 *  host buffer.
 *
 *  Rationale: GetGamma reads directly from the DMC snapshot
 *  (NOT from a per-context VBL-latched buffer like GetCLUT)
 *  because (1) the DMC snapshot is already VBL-latched by the
 *  compositor's s_last_gamma_gen pattern, (2) there's only one
 *  global gamma LUT (no per-context state to latch), (3) the
 *  compositor never writes back to the DMC snapshot.
 *
 *  Snapshot-NULL edge case: dmc_current_snapshot returns NULL in
 *  Quiescent state (DMC pre-create or post-shutdown). This is an
 *  extreme edge case in production but covered defensively here.
 */
static int32_t DSpGetGammaCore(DSpContextPrivate *ctx,
                                uint8_t *lut_out_host_768)
{
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (lut_out_host_768 == nullptr) return kDSpInvalidAttributesErr;

	const struct DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap == nullptr) {
		DSP_LOG("GetGamma: dmc_current_snapshot returned NULL "
		        "(DMC Quiescent) -> kDSpNotInitializedErr");
		return kDSpNotInitializedErr;
	}
	memcpy(lut_out_host_768, snap->gamma_lut, 768);
	return kDSpNoErr;
}

/*
 *  DSpContext_GetGamma (sub-opcode 401).
 *
 *  Argument contract:
 *    ctxRef        = context handle from DSpContext_Reserve
 *    tableOutAddr  = guest Mac address of a caller-allocated GammaTable
 *                    struct. The caller owns the 24-byte header bytes
 *                    (set to default values per classic Mac convention
 *                    or copied from a prior GetGamma); this handler
 *                    writes only the LUT block at tableOutAddr + 24.
 *
 *  Error map:
 *    kDSpInvalidContextErr    - ctxRef does not resolve to a context
 *    kDSpInvalidAttributesErr - tableOutAddr == 0
 *    kDSpNotInitializedErr    - dmc_current_snapshot returned NULL
 *    kDSpNoErr                - success; 768 bytes written to guest RAM
 *
 *  DMC contract:
 *    dmc_current_snapshot() returns a pointer to the published DMC
 *    snapshot. Reads from snap->gamma_lut[768] are atomic-snapshot-
 *    consistent. The snapshot may be replaced
 *    mid-flight by a concurrent DMC writer (e.g., another SetGamma
 *    or the gamma-fade VBL callback), but the snapshot
 *    pointer is reference-counted so reads against the captured
 *    pointer remain valid until the function returns.
 */
extern "C" int32_t DSpContext_GetGammaHandler(uint32_t ctxRef,
                                               uint32_t tableOutAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("GetGamma: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	if (tableOutAddr == 0) {
		DSP_LOG("GetGamma: NULL tableOutAddr (ctxRef=%u) -> kDSpInvalidAttributesErr",
		        ctxRef);
		return kDSpInvalidAttributesErr;
	}

	/* Stage LUT from DMC snapshot into a host-local 768-byte buffer. */
	uint8_t staged[768];
	int32_t rv = DSpGetGammaCore(ctx, staged);
	if (rv != kDSpNoErr) {
		return rv;  /* DSpGetGammaCore already logged the failure reason */
	}

	/* Egress to guest RAM. Header bytes at tableOutAddr + 0..23 are
	 * unchanged (caller owns header semantics). */
	DSpWriteGammaLUTToGuest(tableOutAddr, staged);

	DSP_LOG("GetGamma: ctx=%u tableOutAddr=0x%08x -> OK",
	        ctxRef, tableOutAddr);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD wrapper — host-LUT pattern (mirrors
 *  DSpTesting_GetCLUTEntriesByStruct). Reads the current DMC snapshot's
 *  gamma_lut[768] into the caller's host buffer. Bypasses the
 *  DSpWriteGammaLUTToGuest loop entirely.
 *
 *  Used by DSpGammaTests for round-trip + reference-curve
 *  assertions without guest-RAM plumbing. The production path
 *  (DSpContext_GetGammaHandler) remains authoritative for real apps.
 */
extern "C" int32_t DSpTesting_GetGammaByLUT(uint32_t ctxRef,
                                              uint8_t *lut_out_host_768)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (lut_out_host_768 == nullptr) return kDSpInvalidAttributesErr;
	return DSpGetGammaCore(ctx, lut_out_host_768);
}
#endif
