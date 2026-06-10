/*
 *  dsp_flatten_restore.mm - DrawSprocket context Save/Restore/Flatten
 *                           (sub-ops 739-741, PDF pp.21-23) + Queue/Switch.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Extracted verbatim from dsp_draw_context.mm (de-bloat, NO behaviour change):
 *  the self-consistent context (de)serialization cores + BE helpers, the
 *  Flatten/Restore/GetFlattenedSize production handlers + DSpTesting_* wrappers,
 *  and the Queue/Switch handlers/cores. All entry points are extern "C" and
 *  declared in dsp_draw_context.h; the internal statics have no out-of-module
 *  callers, so no extra header is needed.
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

/* ============================================================== */
/*  Save/Restore/Flatten                                          */
/*  (sub-ops 739-741, PDF pp.21-23)                               */
/*                                                                  */
/*  Self-consistent serialization: the SAME emulator Flattens its  */
/*  own context to a magic+version-headed blob and Restores it     */
/*  later (no second consumer of the byte layout exists on iOS).   */
/*  Flatten runs BEFORE the context's play state                   */
/*  goes Active (PDF p.22), so the back-buffer Metal resources do  */
/*  NOT exist yet and MUST NOT be serialized — only                */
/*  the attribute + bookkeeping subset is portable. Restore "has   */
/*  a high probability of failure" (p.22), so a magic/version      */
/*  mismatch -> kDSpContextNotFoundErr is a documented, valid      */
/*  outcome (NOT masked). Pure RAM serialization — ZERO new        */
/*  concurrency primitive.                                         */
/*                                                                  */
/*  The serialize/deserialize cores below are agnostic to where    */
/*  the bytes live: the guest-RAM handlers feed them WriteMacInt32  */
/*  / ReadMacInt32; the TESTING_BUILD host helpers feed them        */
/*  a plain uint8_t* big-endian byte buffer. Both produce + consume */
/*  the identical DSP_FLAT_* on-wire layout (validated by the      */
/*  DSpFlattenTests round-trip + golden fixture).                  */
/* ============================================================== */

/* Big-endian store/load helpers for the host-buffer (TESTING_BUILD) path so
 * the flattened blob byte layout matches the guest WriteMacInt32 (which is
 * big-endian on the Mac side) bit-for-bit. */
static inline void DSpFlatStoreBE32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)((v >> 24) & 0xFF);
	p[1] = (uint8_t)((v >> 16) & 0xFF);
	p[2] = (uint8_t)((v >>  8) & 0xFF);
	p[3] = (uint8_t)(v & 0xFF);
}

static inline uint32_t DSpFlatLoadBE32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	       ((uint32_t)p[2] <<  8) | ((uint32_t)p[3]);
}

/* Serialize the portable subset of `ctx` into the host blob `out` (>=
 * DSP_FLAT_SIZE bytes). Writes ONLY the magic+version header + the 12
 * Reserve-relevant DSpContextAttributes fields + the 3 bookkeeping fields.
 * Runtime-only fields (back_buffer/back_texture/cgrafptr_mac_addr/state/
 * staging_mac_addr/fade_state/events ring/alt-buffer handles) are NEVER touched
 * (info-disclosure mitigation). */
static void DSpFlattenSerializeToHost(const DSpContextPrivate *ctx, uint8_t *out)
{
	const DSpContextAttributes *a = &ctx->attr;
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_magic,              DSP_FLAT_MAGIC);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_version,            DSP_FLAT_VERSION);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_size,               DSP_FLAT_SIZE);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_displayWidth,       a->displayWidth);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_displayHeight,      a->displayHeight);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_colorNeeds,         a->colorNeeds);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_colorTable,         a->colorTable);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_contextOptions,     a->contextOptions);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_backBufferDepthMask, a->backBufferDepthMask);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_displayDepthMask,   a->displayDepthMask);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_backBufferBestDepth, a->backBufferBestDepth);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_displayBestDepth,   a->displayBestDepth);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_pageCount,          a->pageCount);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_gameMustConfirmSwitch, a->gameMustConfirmSwitch);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_max_frame_rate,     ctx->max_frame_rate);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_dirty_grid_w,       ctx->dirty_grid_w);
	DSpFlatStoreBE32(out + DSP_FLAT_OFF_dirty_grid_h,       ctx->dirty_grid_h);
}

/* Validate + deserialize the host blob `in` (>= DSP_FLAT_SIZE bytes) into a
 * host DSpContextAttributes + the 2 bookkeeping scalars. Returns kDSpNoErr on
 * a valid magic+version; kDSpContextNotFoundErr on a magic/version mismatch
 * (the documented Restore-failure path, NOT masked). The caller allocates the
 * fresh metadata context on success. NEVER trusts any field before the magic+
 * version check (deserialization-tampering mitigation). */
static int32_t DSpFlattenDeserializeFromHost(const uint8_t *in,
                                             DSpContextAttributes *out_attr,
                                             uint32_t *out_max_frame_rate,
                                             uint32_t *out_dirty_grid_w,
                                             uint32_t *out_dirty_grid_h)
{
	uint32_t magic   = DSpFlatLoadBE32(in + DSP_FLAT_OFF_magic);
	uint32_t version = DSpFlatLoadBE32(in + DSP_FLAT_OFF_version);
	if (magic != DSP_FLAT_MAGIC || version != DSP_FLAT_VERSION) {
		/* PDF p.22: Restore "has a high probability of failure" — a stale /
		 * forged / wrong-version blob is reported as kDSpContextNotFoundErr,
		 * the documented valid outcome. No field is trusted past this point. */
		DSP_LOG("Restore: blob magic=0x%08x ver=%u mismatch "
		        "(want 0x%08x v%u) -> kDSpContextNotFoundErr",
		        magic, version, DSP_FLAT_MAGIC, DSP_FLAT_VERSION);
		return kDSpContextNotFoundErr;
	}

	/* Zero the out-struct then populate ONLY the round-tripped subset; the
	 * non-serialized attr fields (frequency/reserved/filler/host mirrors) stay
	 * zero and are re-derived by the metadata-context allocator. */
	DSpContextAttributes a = {};
	a.displayWidth        = DSpFlatLoadBE32(in + DSP_FLAT_OFF_displayWidth);
	a.displayHeight       = DSpFlatLoadBE32(in + DSP_FLAT_OFF_displayHeight);
	a.colorNeeds          = DSpFlatLoadBE32(in + DSP_FLAT_OFF_colorNeeds);
	a.colorTable          = DSpFlatLoadBE32(in + DSP_FLAT_OFF_colorTable);
	a.contextOptions      = DSpFlatLoadBE32(in + DSP_FLAT_OFF_contextOptions);
	a.backBufferDepthMask = DSpFlatLoadBE32(in + DSP_FLAT_OFF_backBufferDepthMask);
	a.displayDepthMask    = DSpFlatLoadBE32(in + DSP_FLAT_OFF_displayDepthMask);
	a.backBufferBestDepth = DSpFlatLoadBE32(in + DSP_FLAT_OFF_backBufferBestDepth);
	a.displayBestDepth    = DSpFlatLoadBE32(in + DSP_FLAT_OFF_displayBestDepth);
	a.pageCount           = DSpFlatLoadBE32(in + DSP_FLAT_OFF_pageCount);
	a.gameMustConfirmSwitch = DSpFlatLoadBE32(in + DSP_FLAT_OFF_gameMustConfirmSwitch);
	/* Host-only mirrors used by the dirty-rect clip code (Reserve_Core sets
	 * these from displayWidth/Height; mirror them here for the metadata ctx). */
	a.backBufferWidth     = a.displayWidth;
	a.backBufferHeight    = a.displayHeight;

	*out_attr            = a;
	*out_max_frame_rate  = DSpFlatLoadBE32(in + DSP_FLAT_OFF_max_frame_rate);
	*out_dirty_grid_w    = DSpFlatLoadBE32(in + DSP_FLAT_OFF_dirty_grid_w);
	*out_dirty_grid_h    = DSpFlatLoadBE32(in + DSP_FLAT_OFF_dirty_grid_h);
	return kDSpNoErr;
}

/* --- DSpContext_GetFlattenedSizeHandler (sub-op 740) ---
 *
 *  DSp 1.7 PDF p.23: DSpContext_GetFlattenedSize(inContext, UInt32 *outSize).
 *  Writes the byte count GetFlattenedSize/Flatten agree on (DSP_FLAT_SIZE).
 *  Validate outSize BEFORE the ctx lookup so a bad pointer +
 *  valid handle reports the more specific kDSpInvalidAttributesErr. */
extern "C" int32_t DSpContext_GetFlattenedSizeHandler(uint32_t ctxRef,
                                                      uint32_t outSize)
{
	if (outSize == 0) {
		DSP_LOG("GetFlattenedSize: NULL outSize (ctxRef=%u) -> "
		        "kDSpInvalidAttributesErr", ctxRef);
		return kDSpInvalidAttributesErr;
	}
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("GetFlattenedSize: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	WriteMacInt32(outSize, DSP_FLAT_SIZE);
	return kDSpNoErr;
}

/* --- DSpContext_FlattenHandler (sub-op 739) ---
 *
 *  DSp 1.7 PDF p.23: DSpContext_Flatten(inContext, void *outFlatContext).
 *  Serializes the portable {magic, version, size, attr, bookkeeping} subset to
 *  the guest out-buffer via WriteMacInt32 at the DSP_FLAT_* offsets. The buffer
 *  is sized by a prior GetFlattenedSize (DSP_FLAT_SIZE bytes). Runtime-only
 *  fields are NEVER serialized (Flatten is pre-Active, those
 *  resources do not exist; also the info-disclosure mitigation).
 *  Validate outFlatContext BEFORE the ctx lookup. */
extern "C" int32_t DSpContext_FlattenHandler(uint32_t ctxRef,
                                             uint32_t outFlatContext)
{
	if (outFlatContext == 0) {
		DSP_LOG("Flatten: NULL outFlatContext (ctxRef=%u) -> "
		        "kDSpInvalidAttributesErr", ctxRef);
		return kDSpInvalidAttributesErr;
	}
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("Flatten: invalid ctxRef=%u -> kDSpInvalidContextErr", ctxRef);
		return kDSpInvalidContextErr;
	}

	/* Serialize via WriteMacInt32 at the DSP_FLAT_* offsets — same field-
	 * serialize idiom as DSpWriteAttributesCore. */
	const DSpContextAttributes *a = &ctx->attr;
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_magic,               DSP_FLAT_MAGIC);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_version,             DSP_FLAT_VERSION);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_size,                DSP_FLAT_SIZE);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_displayWidth,        a->displayWidth);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_displayHeight,       a->displayHeight);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_colorNeeds,          a->colorNeeds);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_colorTable,          a->colorTable);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_contextOptions,      a->contextOptions);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_backBufferDepthMask, a->backBufferDepthMask);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_displayDepthMask,    a->displayDepthMask);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_backBufferBestDepth, a->backBufferBestDepth);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_displayBestDepth,    a->displayBestDepth);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_pageCount,           a->pageCount);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_gameMustConfirmSwitch, a->gameMustConfirmSwitch);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_max_frame_rate,      ctx->max_frame_rate);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_dirty_grid_w,        ctx->dirty_grid_w);
	WriteMacInt32(outFlatContext + DSP_FLAT_OFF_dirty_grid_h,        ctx->dirty_grid_h);

	DSP_LOG("Flatten: ctx=%u -> %u bytes (%ux%u@%ubpp pc=%u)",
	        ctxRef, DSP_FLAT_SIZE, a->displayWidth, a->displayHeight,
	        a->backBufferBestDepth, a->pageCount);
	return kDSpNoErr;
}

/* --- DSpContext_RestoreHandler (sub-op 741) ---
 *
 *  DSp 1.7 PDF p.22: DSpContext_Restore(void *inFlatContext,
 *  DSpContextReference *outRestoredContext). Reads the blob field-by-field,
 *  validates magic+version (mismatch -> kDSpContextNotFoundErr, the documented
 *  high-probability-of-failure path), then allocates a FRESH metadata-only
 *  context (NO Metal resources — the app re-Reserves before going Active per
 *  PDF p.22) and writes its ctxRef. Both out-ptrs NULL-guarded;
 *  no field is trusted past the magic+version check. */
extern "C" int32_t DSpContext_RestoreHandler(uint32_t inFlatContext,
                                             uint32_t outRestoredContext)
{
	if (inFlatContext == 0 || outRestoredContext == 0) {
		DSP_LOG("Restore: NULL inFlatContext=0x%08x or outRestoredContext=0x%08x"
		        " -> kDSpInvalidAttributesErr", inFlatContext, outRestoredContext);
		return kDSpInvalidAttributesErr;
	}

	/* Read the magic+version FIRST and validate before trusting any field. */
	uint32_t magic   = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_magic);
	uint32_t version = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_version);
	if (magic != DSP_FLAT_MAGIC || version != DSP_FLAT_VERSION) {
		DSP_LOG("Restore: blob magic=0x%08x ver=%u mismatch -> "
		        "kDSpContextNotFoundErr", magic, version);
		return kDSpContextNotFoundErr;
	}

	DSpContextAttributes attr = {};
	attr.displayWidth        = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_displayWidth);
	attr.displayHeight       = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_displayHeight);
	attr.colorNeeds          = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_colorNeeds);
	attr.colorTable          = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_colorTable);
	attr.contextOptions      = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_contextOptions);
	attr.backBufferDepthMask = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_backBufferDepthMask);
	attr.displayDepthMask    = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_displayDepthMask);
	attr.backBufferBestDepth = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_backBufferBestDepth);
	attr.displayBestDepth    = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_displayBestDepth);
	attr.pageCount           = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_pageCount);
	attr.gameMustConfirmSwitch = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_gameMustConfirmSwitch);
	attr.backBufferWidth     = attr.displayWidth;
	attr.backBufferHeight    = attr.displayHeight;

	/* Allocate a fresh metadata-only context (no back-buffer; the restored
	 * context is pre-Active per PDF p.22). DSP_ENUMERATION_INDEX_NONE marks it
	 * off the GetFirst/GetNext chain (a restored ctx is not an enumeration
	 * cursor). A full table -> kDSpContextNotFoundErr (no slot == cannot
	 * locate/host the restored context, the documented Restore-failure path). */
	uint32_t newRef = DSpAllocFirstContextHandle(&attr, DSP_ENUMERATION_INDEX_NONE);
	if (newRef == 0) {
		DSP_LOG("Restore: context table full -> kDSpContextNotFoundErr");
		return kDSpContextNotFoundErr;
	}
	DSpContextPrivate *ctx = DSpGetContext(newRef);
	if (ctx != nullptr) {
		ctx->max_frame_rate = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_max_frame_rate);
		ctx->dirty_grid_w   = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_dirty_grid_w);
		ctx->dirty_grid_h   = ReadMacInt32(inFlatContext + DSP_FLAT_OFF_dirty_grid_h);
	}

	WriteMacInt32(outRestoredContext, newRef);
	DSP_LOG("Restore: blob valid -> fresh metadata ctx=%u (%ux%u@%ubpp pc=%u)",
	        newRef, attr.displayWidth, attr.displayHeight,
	        attr.backBufferBestDepth, attr.pageCount);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/*
 *  Flatten/Restore host-helper twins. They operate on a plain
 *  host uint8_t* big-endian blob so the round-trip contract + golden fixture
 *  tests run with NO EMULATED_PPC frame, NO ROM, NO render (keeps
 *  the suite well under the 30s budget). The serialize/deserialize cores are
 *  shared with the guest-RAM handlers, so the host helpers are observationally
 *  identical to the production path.
 */
extern "C" int32_t DSpTesting_GetFlattenedSizeByValue(uint32_t ctxRef,
                                                      uint32_t *outSize)
{
	if (outSize == nullptr) return kDSpInvalidAttributesErr;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	*outSize = DSP_FLAT_SIZE;
	return kDSpNoErr;
}

extern "C" int32_t DSpTesting_FlattenToHost(uint32_t ctxRef, uint8_t *blob,
                                            uint32_t blob_cap)
{
	if (blob == nullptr) return kDSpInvalidAttributesErr;
	if (blob_cap < DSP_FLAT_SIZE) return kDSpInvalidAttributesErr;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	DSpFlattenSerializeToHost(ctx, blob);
	return kDSpNoErr;
}

extern "C" int32_t DSpTesting_RestoreFromHost(const uint8_t *blob,
                                              uint32_t blob_len,
                                              uint32_t *outRestoredCtxRef)
{
	if (blob == nullptr || outRestoredCtxRef == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	if (blob_len < DSP_FLAT_SIZE) return kDSpInvalidAttributesErr;

	DSpContextAttributes attr = {};
	uint32_t mfr = 0, gw = 0, gh = 0;
	int32_t rc = DSpFlattenDeserializeFromHost(blob, &attr, &mfr, &gw, &gh);
	if (rc != kDSpNoErr) return rc;   /* kDSpContextNotFoundErr on bad magic/version */

	uint32_t newRef = DSpAllocFirstContextHandle(&attr, DSP_ENUMERATION_INDEX_NONE);
	if (newRef == 0) return kDSpContextNotFoundErr;
	DSpContextPrivate *ctx = DSpGetContext(newRef);
	if (ctx != nullptr) {
		ctx->max_frame_rate = mfr;
		ctx->dirty_grid_w   = gw;
		ctx->dirty_grid_h   = gh;
	}
	*outRestoredCtxRef = newRef;
	return kDSpNoErr;
}
#endif

/* ===================================================================== *
 *  Queue/Switch (sub-ops 742-743).
 *
 *  DSp 1.7 PDF pp.26-27 (DSp-1.7-only deferred-context-switch exports).
 *  Queue (742) stages a child context against a parent; Switch (743) applies
 *  the staged switch. This is RAM-only single-writer bookkeeping on the emul
 *  thread (queued_child / state / vbl_proc_ptr fields) — NO cross-thread queue,
 *  NO concurrency primitive (the events_head/tail _Atomic SPSC ring is
 *  the retired sub-op-600 anti-pattern, deliberately NOT copied).
 * ===================================================================== */

/* Apply a guest DSpContextAttributes block (on-wire layout, PDF p.65 — same
 * offsets DSpWriteAttributesCore writes) onto a child context's attr. Only
 * called when inDesiredAttributes is non-zero (PDF p.26: Queue's
 * inDesiredAttributes is optional). The attr block is read field-by-field via
 * ReadMacInt32 at the canonical offsets — NO host-pointer cast of the guest
 * address (arm64 >4GiB safety), NO struct overlay.
	 * The caller NULL-guards the ptr; this core trusts only the 12 meaningful
	 * UInt32 fields and ignores filler/reserved. Desired attributes describe the
	 * child drawing environment; if the child came from FindBest/GetFirst, keep
	 * its selected display mode and store the desired size in backBufferWidth /
	 * backBufferHeight. */
static bool DSpApplyDesiredAttributesToChild(DSpContextPrivate *child,
                                             uint32_t inDesiredAttributes)
{
	if (child == nullptr || inDesiredAttributes == 0) return false;
	/* Validate the whole attribute-struct extent lies in mapped RAM
	 * before reading any field (ASVS V5; NQDMetalAddrInBuffer idiom). The
	 * on-wire block matches DSpWriteAttributesCore's layout; the last field
	 * read is gameMustConfirmSwitch (1 byte @ +55), so 56 bytes must be mapped.
	 * Reject-before-mutate: on a bogus non-NULL ptr leave child->attr untouched
	 * and report failure so the caller returns kDSpInvalidAttributesErr rather
	 * than faulting the ReadMacInt* translation layer. */
	const uint32_t kDesiredAttrSize = 56u;
	if (!NQDMetalAddrInBuffer(inDesiredAttributes) ||
	    !NQDMetalAddrInBuffer(inDesiredAttributes + kDesiredAttrSize - 1u)) {
		DSP_LOG("Queue: inDesiredAttributes 0x%08x out of mapped RAM -> reject",
		        inDesiredAttributes);
		return false;
	}
	const uint32_t desiredWidth = ReadMacInt32(inDesiredAttributes +  4);
	const uint32_t desiredHeight = ReadMacInt32(inDesiredAttributes +  8);
	const uint32_t desiredBackDepth = ReadMacInt32(inDesiredAttributes + 40);
	const uint32_t desiredDisplayDepth = ReadMacInt32(inDesiredAttributes + 44);

	child->attr.displayWidth        =
	    DSpReserveActualDisplayDimension(child->attr.displayWidth,
	                                     desiredWidth);
	child->attr.displayHeight       =
	    DSpReserveActualDisplayDimension(child->attr.displayHeight,
	                                     desiredHeight);
	child->attr.colorNeeds          = ReadMacInt32(inDesiredAttributes + 20);
	child->attr.colorTable          = ReadMacInt32(inDesiredAttributes + 24);
	child->attr.contextOptions      = ReadMacInt32(inDesiredAttributes + 28);
	child->attr.backBufferDepthMask = ReadMacInt32(inDesiredAttributes + 32);
	child->attr.displayDepthMask    = ReadMacInt32(inDesiredAttributes + 36);
	child->attr.backBufferBestDepth = desiredBackDepth;
	child->attr.displayBestDepth    =
	    DSpReserveActualDisplayDepth(child->attr.displayBestDepth,
	                                 desiredDisplayDepth,
	                                 desiredBackDepth);
	child->attr.pageCount           = ReadMacInt32(inDesiredAttributes + 48);
	child->attr.gameMustConfirmSwitch = ReadMacInt8(inDesiredAttributes + 55);
	child->attr.backBufferWidth     = DSpReserveBackBufferDimension(
	                                      child->attr.displayWidth,
	                                      desiredWidth);
	child->attr.backBufferHeight    = DSpReserveBackBufferDimension(
	                                      child->attr.displayHeight,
	                                      desiredHeight);
	return true;
}

/* Core deferred-switch staging shared by the production handler + the
 * TESTING_BUILD host helper. Resolves both ctxRefs, passes the same-display
 * check (trivially true on the single iOS fullscreen display), records
 * parent->queued_child = childRef.
 * inDesiredAttributes (a guest Mac address, 0 == none) is applied to the child
 * by the production handler BEFORE calling this core; the host helper passes 0.
 * Returns kDSpInvalidContextErr if either ctxRef is unresolved
 * (never deref a context pointer before the null-guard). */
static int32_t DSpQueueCore(uint32_t parentCtx, uint32_t childCtx)
{
	DSpContextPrivate *parent = DSpGetContext(parentCtx);
	DSpContextPrivate *child  = DSpGetContext(childCtx);
	if (parent == nullptr || child == nullptr) {
		DSP_LOG("Queue: unresolved parent=%u (%p) or child=%u (%p) -> "
		        "kDSpInvalidContextErr", parentCtx, (void *)parent,
		        childCtx, (void *)child);
		return kDSpInvalidContextErr;
	}
	/* Same-display check (PDF p.26): both contexts must be on the same
	 * display. PocketShaver has exactly one fullscreen display, so any two
	 * resolvable contexts trivially pass. Recorded explicitly so the intent
	 * is documented; there is no incompatible-display path on iOS. */
	parent->queued_child = childCtx;
	DSP_LOG("Queue: parent=%u staged child=%u", parentCtx, childCtx);
	return kDSpNoErr;
}

/* --- DSpContext_QueueHandler (sub-op 742) ---
 *
 *  DSp 1.7 PDF p.26: DSpContext_Queue(inParentContext, inChildContext,
 *  inDesiredAttributes). Queues a context to switch to. "DrawSprocket will
 *  check that both contexts are on the same display" — trivially true on the
 *  single iOS display. inDesiredAttributes (optional) is applied to the child
 *  when non-zero. Unresolved ctxRefs -> kDSpInvalidContextErr. */
extern "C" int32_t DSpContext_QueueHandler(uint32_t parentCtx, uint32_t childCtx,
                                           uint32_t inDesiredAttributes)
{
	/* Resolve both BEFORE any mutation (no deref before the
	 * null-guard inside DSpQueueCore). Apply optional attributes to the child
	 * only when the ptr is non-zero (never deref NULL). */
	DSpContextPrivate *child = DSpGetContext(childCtx);
	if (DSpGetContext(parentCtx) == nullptr || child == nullptr) {
		DSP_LOG("Queue: unresolved parent=%u or child=%u -> "
		        "kDSpInvalidContextErr", parentCtx, childCtx);
		return kDSpInvalidContextErr;
	}
	if (inDesiredAttributes != 0) {
		/* Reject-before-mutate — if the attribute struct is out of
		 * mapped RAM, fail without staging the switch. */
		if (!DSpApplyDesiredAttributesToChild(child, inDesiredAttributes)) {
			DSP_LOG("Queue: inDesiredAttributes=0x%08x invalid -> "
			        "kDSpInvalidAttributesErr", inDesiredAttributes);
			return kDSpInvalidAttributesErr;
		}
		DSP_LOG("Queue: applied inDesiredAttributes=0x%08x to child=%u",
		        inDesiredAttributes, childCtx);
	}
	return DSpQueueCore(parentCtx, childCtx);
}

/* Core deferred-switch apply shared by the production handler + the
 * TESTING_BUILD host helper. Requires a prior Queue (old->queued_child ==
 * newRef, else kDSpInternalErr per PDF p.27 "returns an error" — no partial
 * switch, reject-before-mutate). Kills the OLD context's
 * piggyback VBL proc (old->vbl_proc_ptr = 0 — the VBL service walk at
 * dsp_metal_renderer.mm early-outs on ==0), makes the new context active
 * (new->state = Active), and clears old->queued_child. */
static int32_t DSpSwitchCore(uint32_t oldCtx, uint32_t newCtx)
{
	DSpContextPrivate *old = DSpGetContext(oldCtx);
	DSpContextPrivate *neu = DSpGetContext(newCtx);
	if (old == nullptr || neu == nullptr) {
		DSP_LOG("Switch: unresolved old=%u (%p) or new=%u (%p) -> "
		        "kDSpInvalidContextErr", oldCtx, (void *)old,
		        newCtx, (void *)neu);
		return kDSpInvalidContextErr;
	}
	/* PDF p.27: "If you did not queue the contexts you want to switch (via
	 * DSpContext_Queue), DSpContext_Switch returns an error." Reject BEFORE
	 * any state mutation (no partial switch). */
	if (old->queued_child != newCtx) {
		DSP_LOG("Switch: old=%u was not queued to new=%u (queued_child=%u) -> "
		        "kDSpInternalErr (PDF p.27 switch-without-queue)",
		        oldCtx, newCtx, old->queued_child);
		return kDSpInternalErr;
	}
	/* PDF p.27: "switching contexts will kill any piggyback VBL routines
	 * attached to the context you are switching out." Clearing vbl_proc_ptr is
	 * the SetVBLProc(0) uninstall path (p.81) — the DSpVBLServiceCallback walk
	 * skips contexts with vbl_proc_ptr == 0. */
	old->vbl_proc_ptr    = 0;
	old->vbl_proc_refcon = 0;
	/* Make the new context active (same state scalar GetCurrentContext walks
	 * for). Single-display: there is no intermediate default-mode switch. */
	neu->state = (uint32_t)kDSpContextState_Active;
	/* Clear the staged switch — a subsequent Switch needs a fresh Queue. */
	old->queued_child = 0;
	DSP_LOG("Switch: old=%u -> new=%u active, old VBL proc killed, "
	        "queued_child cleared", oldCtx, newCtx);
	return kDSpNoErr;
}

/* --- DSpContext_SwitchHandler (sub-op 743) ---
 *
 *  DSp 1.7 PDF p.27: DSpContext_Switch(inOldContext, inNewContext). Switches
 *  the display context immediately. Requires a prior Queue (else returns an
 *  error). Kills the OLD context's piggyback VBL proc. Makes the new context
 *  active. Unresolved ctxRefs -> kDSpInvalidContextErr. */
extern "C" int32_t DSpContext_SwitchHandler(uint32_t oldCtx, uint32_t newCtx)
{
	return DSpSwitchCore(oldCtx, newCtx);
}

#ifdef TESTING_BUILD
/*
 *  Queue/Switch host-helper twins. Queue/Switch is pure RAM-only
 *  bookkeeping on DSpContextPrivate fields with NO guest-RAM struct deref, so
 *  the by-value wrappers call straight through the shared cores. The contract
 *  path passes inDesiredAttributes = 0 (no attribute override); the guest-RAM
 *  apply-on-non-zero branch is exercised on device/Catalyst. These run the
 *  deferred-switch + old-VBL-proc-kill + switch-without-queue-error contract
 *  with NO EMULATED_PPC frame, NO ROM, NO render.
 */
extern "C" int32_t DSpTesting_QueueByValue(uint32_t parentCtx, uint32_t childCtx,
                                           uint32_t inDesiredAttributes)
{
	(void)inDesiredAttributes;   /* contract path uses 0; guest-RAM apply is device-only */
	return DSpQueueCore(parentCtx, childCtx);
}

extern "C" int32_t DSpTesting_SwitchByValue(uint32_t oldCtx, uint32_t newCtx)
{
	return DSpSwitchCore(oldCtx, newCtx);
}

extern "C" int32_t DSpTesting_GetQueuedChildByValue(uint32_t ctxRef,
                                                    uint32_t *outChild)
{
	if (outChild == nullptr) return kDSpInvalidAttributesErr;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	*outChild = ctx->queued_child;
	return kDSpNoErr;
}
#endif

