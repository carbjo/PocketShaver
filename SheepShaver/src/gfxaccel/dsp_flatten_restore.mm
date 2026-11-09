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
 *  Entry points are declared in dsp_draw_context.h.
 */
#import <Metal/Metal.h>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "dsp_engine.h"
#include "dsp_draw_context.h"
#include "dsp_mode_enumerate.h"
#include "dsp_context_private.h"
#include "dsp_display_mode_policy.h"
#include "dsp_guest_address.h"
#include "nqd_accel.h"
#include "dsp_engine_internal.h"

/*
 *  Save/Restore/Flatten (sub-ops 739-741, DSp 1.7 pp.21-23).
 *
 *  The blob is private to this emulator: a magic+version header followed by
 *  the DSP_FLAT_* fields in guest big-endian order. Flatten happens before
 *  the context goes Active (p.22), so only attributes and bookkeeping are
 *  saved, never Metal resources. Restore may legitimately fail (p.22); a
 *  header mismatch returns kDSpContextNotFoundErr.
 */

/* Sub-op 740 (p.23). outSize is checked before the context so a NULL
 * pointer reports kDSpInvalidAttributesErr. */
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

/* Sub-op 739 (p.23). The buffer holds DSP_FLAT_SIZE bytes. Runtime-only
 * fields are never written, which also avoids leaking host state. */
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

/* Sub-op 741 (p.22). Creates a fresh metadata-only context; the app
 * reserves it again before going Active. */
extern "C" int32_t DSpContext_RestoreHandler(uint32_t inFlatContext,
                                             uint32_t outRestoredContext)
{
	if (inFlatContext == 0 || outRestoredContext == 0) {
		DSP_LOG("Restore: NULL inFlatContext=0x%08x or outRestoredContext=0x%08x"
		        " -> kDSpInvalidAttributesErr", inFlatContext, outRestoredContext);
		return kDSpInvalidAttributesErr;
	}

	/* Validate the header before trusting any field. */
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

	/* DSP_ENUMERATION_INDEX_NONE keeps it off the GetFirst/GetNext chain.
	 * A full table is reported as the documented Restore failure. */
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


/*
 *  Queue/Switch (sub-ops 742-743, DSp 1.7 pp.26-27). Queue stages a child
 *  context on a parent; Switch applies it. Emul thread only.
 */

/* Apply Queue's optional guest DSpContextAttributes (p.65 layout, same
 * offsets as DSpWriteAttributesCore) to the child. Filler and reserved
 * fields are ignored. */
static int32_t DSpApplyDesiredAttributesToChild(DSpContextPrivate *child,
                                             uint32_t inDesiredAttributes)
{
	if (child == nullptr || inDesiredAttributes == 0) return kDSpInvalidAttributesErr;
	/* The last field read is gameMustConfirmSwitch (1 byte at +55), so all
	 * 56 bytes must be in mapped RAM. Reject before touching child->attr. */
	const uint32_t kDesiredAttrSize = 56u;
	if (!NQDMetalAddrInBuffer(inDesiredAttributes) ||
	    !NQDMetalAddrInBuffer(inDesiredAttributes + kDesiredAttrSize - 1u)) {
		DSP_LOG("Queue: inDesiredAttributes 0x%08x out of mapped RAM -> reject",
		        inDesiredAttributes);
		return kDSpInvalidAttributesErr;
	}
	DSpContextAttributes desired = child->attr;
	const uint32_t desiredWidth = ReadMacInt32(inDesiredAttributes +  4);
	const uint32_t desiredHeight = ReadMacInt32(inDesiredAttributes +  8);
	const uint32_t desiredBackDepth = ReadMacInt32(inDesiredAttributes + 40);
	const uint32_t desiredDisplayDepth = ReadMacInt32(inDesiredAttributes + 44);

	/* Reserve keeps the selected display mode and derives the back-buffer
	 * size from these. Do not normalize them here too. */
	desired.displayWidth        = desiredWidth;
	desired.displayHeight       = desiredHeight;
	desired.colorNeeds          = ReadMacInt32(inDesiredAttributes + 20);
	desired.colorTable          = ReadMacInt32(inDesiredAttributes + 24);
	desired.contextOptions      = ReadMacInt32(inDesiredAttributes + 28);
	desired.backBufferDepthMask = ReadMacInt32(inDesiredAttributes + 32);
	desired.displayDepthMask    = ReadMacInt32(inDesiredAttributes + 36);
	desired.backBufferBestDepth = desiredBackDepth;
	desired.displayBestDepth    = desiredDisplayDepth;
	desired.pageCount           = ReadMacInt32(inDesiredAttributes + 48);
	desired.gameMustConfirmSwitch = ReadMacInt8(inDesiredAttributes + 55);
	return DSpPrepareContextForQueue(child, &desired);
}

/* Records parent->queued_child. Desired attributes are applied by the
 * caller first. */
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
	/* The same-display check (p.26) always passes: there is one display. */
	parent->queued_child = childCtx;
	DSP_LOG("Queue: parent=%u staged child=%u", parentCtx, childCtx);
	return kDSpNoErr;
}

/* Sub-op 742 (p.26). */
extern "C" int32_t DSpContext_QueueHandler(uint32_t parentCtx, uint32_t childCtx,
                                           uint32_t inDesiredAttributes)
{
	/* Resolve both contexts before any mutation. */
	DSpContextPrivate *child = DSpGetContext(childCtx);
	if (DSpGetContext(parentCtx) == nullptr || child == nullptr) {
		DSP_LOG("Queue: unresolved parent=%u or child=%u -> "
		        "kDSpInvalidContextErr", parentCtx, childCtx);
		return kDSpInvalidContextErr;
	}
	if (parentCtx == childCtx) return kDSpInvalidContextErr;
	int32_t rc = inDesiredAttributes != 0
	    ? DSpApplyDesiredAttributesToChild(child, inDesiredAttributes)
	    : DSpPrepareContextForQueue(child, &child->attr);
	if (rc != kDSpNoErr) return rc;
	return DSpQueueCore(parentCtx, childCtx);
}

/* Deactivate old, kill its VBL proc, activate new, all through SetState.
 * A failed activation restores old's VBL proc and re-activates it (best
 * effort), so the display is never left with no Active context. */
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
	/* Switch without a matching Queue is an error (p.27). */
	if (old->queued_child != newCtx) {
		DSP_LOG("Switch: old=%u was not queued to new=%u (queued_child=%u) -> "
		        "kDSpInternalErr (PDF p.27 switch-without-queue)",
		        oldCtx, newCtx, old->queued_child);
		return kDSpInternalErr;
	}
	/* SetState handles DMC ownership, the PixMap redirect and the fullscreen
	 * flag. The handoff guard stops old going Inactive from restoring the
	 * QuickDraw display mode in between. */
	DSpContext_SetStateSwitchHandoff(oldCtx);
	int32_t rc = DSpContext_SetStateHandler(
	    oldCtx, (uint32_t)kDSpContextState_Inactive);
	DSpContext_SetStateSwitchHandoff(0);
	if (rc != kDSpNoErr) {
		/* Nothing mutated yet. */
		DSP_LOG("Switch: old=%u SetState(Inactive) failed rc=%d",
		        oldCtx, rc);
		return rc;
	}
	/* Switching kills the outgoing context's VBL proc (p.27). Done only after
	 * deactivation succeeds, so an Active context never loses its proc. */
	uint32_t saved_vbl_proc   = old->vbl_proc_ptr;
	uint32_t saved_vbl_refcon = old->vbl_proc_refcon;
	old->vbl_proc_ptr    = 0;
	old->vbl_proc_refcon = 0;
	rc = DSpContext_SetStateHandler(
	    newCtx, (uint32_t)kDSpContextState_Active);
	if (rc != kDSpNoErr) {
		/* Roll back. queued_child stays set so the app can retry. */
		old->vbl_proc_ptr    = saved_vbl_proc;
		old->vbl_proc_refcon = saved_vbl_refcon;
		int32_t rb = DSpContext_SetStateHandler(
		    oldCtx, (uint32_t)kDSpContextState_Active);
		DSP_LOG("Switch: new=%u SetState(Active) failed rc=%d; rolled back "
		        "old=%u to Active (rollback rc=%d)",
		        newCtx, rc, oldCtx, rb);
		(void)rb; /* log-only when ACCEL_LOGGING_ENABLED=0 */
		return rc;
	}
	/* The next Switch needs a fresh Queue. */
	old->queued_child = 0;
	DSP_LOG("Switch: old=%u inactive -> new=%u active via SetState, "
	        "old VBL proc killed, queued_child cleared", oldCtx, newCtx);
	return kDSpNoErr;
}

/* Sub-op 743 (p.27). */
extern "C" int32_t DSpContext_SwitchHandler(uint32_t oldCtx, uint32_t newCtx)
{
	return DSpSwitchCore(oldCtx, newCtx);
}

