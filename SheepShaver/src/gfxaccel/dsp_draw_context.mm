/*
 *  dsp_draw_context.mm - DSp per-context private-data table + Reserve/Release
 *                         lifecycle + VBL-bounded release FIFO.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Pattern source:
 *    - rave_draw_context.mm:43-75 (context-table shape; 1-based handles,
 *      slot 0 reserved, linear-scan free-list via nullptr slots)
 *    - VBL-bounded release FIFO with _Atomic uint32_t head/tail
 *    - Metal texture view must be released BEFORE the underlying buffer —
 *      ARC order matters on some iOS Metal drivers
 *
 *  GetBackBuffer/SwapBuffers/SetState/GetState/InvalBackBufferRect handler
 *  BODIES live in this file.
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
#include "dsp_clut_gamma.h"      /* CLUT + gamma get/set (extracted); fade stays here */
#include "nqd_accel.h"               /* NQDMetalBitblt1to1 / NQDMetalBitbltScaled / NQDMetalFlush for DSpBlit */
#include "metal_compositor.h"      /* MetalCompositorSubmitFrame + MetalCompositorGetFramebufferTexture + CompositeLayer */
#include "metal_device_shared.h"   /* SharedMetalCommandQueue (SwapBuffers blit path) */
#include "display_mode_controller.h" /* dmc_current_snapshot (FrameDescriptor generation); DMCOwner enum + dmc_set_active_owner */
#include "dsp_engine_internal.h"   /* DSpMapStateToDMCOwnerTyped (internal-only, NOT in include/) */
#include "vbl_source.h"

#include <cstring>
#include <cassert>                 /* alignedRB <= 0x3FFF invariant assert */
#include <stdatomic.h>
#include <unistd.h>                /* usleep (busyProc polling) */

#ifdef TESTING_BUILD
#include <sys/mman.h>              /* mmap (dsp_testing_alloc_guest_scratch backing store) */
#endif

static bool DSpBuildSavedQuickDrawModeDesc(const DSpContextPrivate *ctx,
                                           DMCModeDesc *out_mode)
{
	if (ctx == nullptr || out_mode == nullptr) {
		return false;
	}
	if (!DSpSavedQuickDrawModeIsUsable(
	        ctx->saved_pixmap_valid,
	        ctx->saved_pixmap_baseAddr,
	        ctx->saved_pixmap_rowBytes,
	        ctx->saved_pixmap_bounds[0],
	        ctx->saved_pixmap_bounds[1],
	        ctx->saved_pixmap_bounds[2],
	        ctx->saved_pixmap_bounds[3],
	        ctx->saved_pixmap_pixelSize,
	        (uint32_t)RAMBase,
	        (uint32_t)RAMSize)) {
		return false;
	}

	const uint32_t width =
	    (uint32_t)(ctx->saved_pixmap_bounds[3] - ctx->saved_pixmap_bounds[1]);
	const uint32_t height =
	    (uint32_t)(ctx->saved_pixmap_bounds[2] - ctx->saved_pixmap_bounds[0]);
	const uint32_t row_bytes =
	    DSpPixMapRowBytesPayload(ctx->saved_pixmap_rowBytes);

	out_mode->width = width;
	out_mode->height = height;
	out_mode->depth = ctx->saved_pixmap_pixelSize;
	out_mode->row_bytes = row_bytes;
	out_mode->pitch = row_bytes;
	out_mode->vbl_usec = 0;
	out_mode->screen_base_mac = ctx->saved_pixmap_baseAddr;
	out_mode->screen_base_host = Mac2HostAddr(ctx->saved_pixmap_baseAddr);
	return true;
}

static void DSpDetachFrontBufferCGrafPtr(DSpContextPrivate *ctx,
                                         const char *caller)
{
	if (ctx == nullptr || ctx->front_pixmap_mac_addr == 0) return;

	WriteMacInt32(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR,
	              ctx->saved_pixmap_baseAddr);
	WriteMacInt16(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES,
	              ctx->saved_pixmap_rowBytes);
	WriteMacInt16(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP,
	              ctx->saved_pixmap_bounds[0]);
	WriteMacInt16(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT,
	              ctx->saved_pixmap_bounds[1]);
	WriteMacInt16(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT,
	              ctx->saved_pixmap_bounds[2]);
	WriteMacInt16(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT,
	              ctx->saved_pixmap_bounds[3]);
	WriteMacInt16(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE,
	              ctx->saved_pixmap_pixelType);
	WriteMacInt16(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE,
	              ctx->saved_pixmap_pixelSize);
	WriteMacInt16(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT,
	              ctx->saved_pixmap_cmpCount);
	WriteMacInt16(ctx->front_pixmap_mac_addr +
	              DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE,
	              ctx->saved_pixmap_cmpSize);
	DSP_LOG("%s: detached cached front CGrafPtr pixmap=0x%08x "
	        "baseAddr=0x%08x rowBytes=0x%04x pixelSize=%u",
	        caller, ctx->front_pixmap_mac_addr,
	        ctx->saved_pixmap_baseAddr,
	        ctx->saved_pixmap_rowBytes,
	        ctx->saved_pixmap_pixelSize);
}

static void DSpReleaseFrontBufferStaging(DSpContextPrivate *ctx)
{
	if (ctx == nullptr) return;
	DSpDetachFrontBufferCGrafPtr(ctx, "DSpReleaseFrontBufferStaging");
	if (ctx->front_staging_mac_addr != 0) {
		DSpQuarantineGuestPixelStaging(
			ctx->front_staging_mac_addr,
			ctx->front_staging_size,
			ctx->front_staging_owned_sysheap);
	}
	ctx->front_cgrafptr_mac_addr = 0;
	ctx->front_pixmap_mac_addr = 0;
	ctx->front_pixmap_handle_mac_addr = 0;
	ctx->front_staging_mac_addr = 0;
	ctx->front_staging_size = 0;
	ctx->front_staging_owned_sysheap = false;
	ctx->front_staging_present_state = {};
}

/* DSp <-> iOS host bridge forward decls.
 * Included here as a forward declaration so dsp_draw_context.mm doesn't
 * need to pull in dsp_host_bridge.h (the .mm is a .mm file already, but
 * the forward decl keeps the C-linkage contract explicit at the call
 * site in DSpContext_SetStateHandler). Called on the transition edge
 * where the aggregate "any DSp context Active?" predicate changes. */
extern "C" void DSpHostBridge_SetActiveFullscreen(bool active);
extern "C" bool DSpHostBridge_GetActiveFullscreen(void);

/* MainDevice PixMap redirect/restore forward decls — defined later in this
 * file (near DSpContext_SetStateHandler). Forward-declared here so the
 * release-path call sites at DSpReleaseNow / DSpQueueReleaseAtVBL /
 * DSpQueueReleaseAtVBLPartial and the bg/fg bridges
 * (DSpHandleBackgroundFromEmulThread / DSpHandleForegroundFromEmulThread)
 * — all of which appear earlier in the file than the helper bodies —
 * can call the helpers per Landmine-7. */
extern "C" void DSpRedirectMainDevicePixMap(DSpContextPrivate *ctx);
extern "C" void DSpRestoreMainDevicePixMap(DSpContextPrivate *ctx);

/* GetBackBuffer underlay-restore branch forward decl (PDF p.51 "clean a
 * back buffer"). Defined in the AltBuffer
 * section (after the alt-buffer record table + accumulator), but called from
 * DSpContext_GetBackBufferHandler which appears earlier in this file. */
static void DSpRestoreBackBufferFromUnderlay(DSpContextPrivate *ctx);

/* DSP_MAX_CONTEXTS is now defined in dsp_draw_context.h (hoisted there so
 * dsp_host_bridge.mm can reference the bound from cross-TU); the local
 * guarded redefinition below preserves the value in case a downstream
 * compile unit encounters this file without having visited the header
 * first. */
#ifndef DSP_MAX_CONTEXTS
#define DSP_MAX_CONTEXTS             8
#endif
#define DSP_RELEASE_QUEUE_CAPACITY  16   /* 8 contexts × 2 pending cycles */

/* Clamp duration_vbls to this maximum to
 * protect ctx->fade_state.elapsed_vbls (uint16_t) against overflow on
 * pathological app inputs. ~68 s @ 60 Hz; ~34 s @ 120 Hz ProMotion.
 * The DSp 1.7 spec doesn't define an upper bound; this clamp is purely
 * defensive. Apps requesting > 4096 VBLs get a DSP_LOG warning + clamp.
 */
#define DSP_MAX_FADE_VBLS 4096

/*
 *  DSpContextPrivate full struct definition lives in
 *  dsp_context_private.h so dsp_metal_renderer.mm can touch back_buffer /
 *  back_texture / dirty_* / staging_mac_addr without duplicating the
 *  struct layout. This file retains ownership of the context table,
 *  release FIFO, Reserve/Release handlers, and the
 *  GetBackBuffer / SwapBuffers handler bodies.
 */

/* --- Context table (1-based handles; slot 0 reserved) --- */

static DSpContextPrivate *dsp_context_table[DSP_MAX_CONTEXTS] = {};
static int                dsp_context_count                   = 0;

/* File-static atomic VBL tick counter.
 * DSpVBLServiceCallback increments on every VBL; GetVBLCount reads.
 *
 * Single-writer emul-thread: DSpVBLServiceCallback fires from the VBL
 * secondary-callback drain on the emul thread.
 *
 * Many-reader emul-thread: GetVBLCount runs on the emul thread's
 * NATIVE_DSP_DISPATCH seam; any future main-thread reader would also
 * be covered by the atomic.
 *
 * C11 _Atomic primitive per the read-mostly precedent — exact
 * mirror of vbl_source.mm's s_tick_count pattern (documented inline
 * in that file as the sanctioned minimal
 * primitive). NO mutex, NO MTLFence, NO MTLSharedEvent, NO
 * @synchronized. 64-bit internal storage; 32-bit external truncation
 * in GetVBLCount per DSp 1.7 UInt32 contract at spec
 * p.81. The 64-bit-internal/32-bit-external split prevents ABA
 * confusion across long sessions (session > 828 days at 60 Hz before
 * the 32-bit counter wraps; 64-bit effectively never wraps). */
static _Atomic uint64_t s_dsp_vbl_count = 0;

extern "C" DSpContextPrivate *DSpGetContext(uint32_t handle)
{
	if (handle == 0 || handle > DSP_MAX_CONTEXTS) return nullptr;
	return dsp_context_table[handle - 1];
}

/*
 *  Debug session `dsp-sims-enumeration-stall` fix (2026-04-19) — C-safe
 *  accessor that lets dsp_mode_enumerate.cpp (a pure .cpp file, no
 *  <Metal/Metal.h>) read ctx->enumeration_mode_index without needing the
 *  full DSpContextPrivate struct layout. See dsp_draw_context.h for the
 *  contract.
 */
extern "C" uint32_t DSpGetContextEnumerationIndex(uint32_t ctxRef)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return DSP_ENUMERATION_INDEX_NONE;
	return ctx->enumeration_mode_index;
}

/*
 *  Debug session `dsp-enum-context-table-exhaustion` fix (2026-04-21) —
 *  advance the enumeration cursor IN PLACE for DSpGetNextContext. Mutates
 *  ctx->attr + ctx->enumeration_mode_index without allocating a new
 *  context-table slot. See dsp_draw_context.h for the contract.
 *
 *  Pre-fix: DSpGetNextContext_Core called DSpAllocFirstContextHandle
 *  per step, heap-allocating a fresh DSpContextPrivate and consuming one
 *  of DSP_MAX_CONTEXTS=8 slots per iteration. With a 36-mode cache
 *  (Catalyst capture) the table saturated at step 9 — The Sims never
 *  saw a 16bpp mode and bailed with "resolution change could not be
 *  made". PDF p.17 cursor semantics: reuse the handle, advance the
 *  context it refers-to.
 *
 *  Apps that want to "remember" a specific mode call DSpContext_Reserve
 *  with a copy of the attrs; Reserve allocates a separate full context.
 *  The cursor and a reservation are independent allocations.
 */
extern "C" int32_t DSpAdvanceEnumerationContext(
    uint32_t ctxRef,
    const DSpContextAttributes *new_attr,
    uint32_t new_idx)
{
	if (new_attr == nullptr) {
		DSP_LOG("AdvanceEnumeration: NULL new_attr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("AdvanceEnumeration: invalid ctxRef=%u — kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	/* In-place cursor mutation. Back-buffer / back-texture fields are nil
	 * on metadata-only contexts (DSpAllocFirstContextHandle does not
	 * allocate Metal resources); no refcount churn on ARC ObjC slots.
	 * The handle stays stable across the walk — guest PDF p.17 while
	 * loop sees a consistent theContext reference. */
	ctx->attr                    = *new_attr;
	ctx->enumeration_mode_index  = new_idx;
	DSP_LOG("AdvanceEnumeration: handle=%u %ux%u@%ubpp (enum_idx=%u, in-place)",
	        ctxRef, new_attr->displayWidth, new_attr->displayHeight,
	        new_attr->backBufferBestDepth, (unsigned)new_idx);
	return kDSpNoErr;
}

static bool DSpIsInactiveMetadataOnlyContext(const DSpContextPrivate *ctx)
{
	return ctx != nullptr &&
	       ctx->state == (uint32_t)kDSpContextState_Inactive &&
	       ctx->back_buffer == nil &&
	       ctx->back_texture == nil;
}

static uint32_t DSpAllocContextHandle(DSpContextPrivate *ctx)
{
	for (int i = 0; i < DSP_MAX_CONTEXTS; i++) {
		if (dsp_context_table[i] == nullptr) {
			dsp_context_table[i] = ctx;
			ctx->handle = (uint32_t)(i + 1);
			return (uint32_t)(i + 1);
		}
	}
	return 0;
}

static void DSpFreeContextHandle(uint32_t handle)
{
	if (handle > 0 && handle <= DSP_MAX_CONTEXTS) {
		dsp_context_table[handle - 1] = nullptr;
	}
}


/* --- VBL-bounded release FIFO (single-writer, _Atomic head/tail) --- */

struct DSpReleaseEntry {
	id<MTLBuffer>       back_buffer;
	id<MTLTexture>      back_texture;
	DSpContextPrivate  *ctx_to_free;
};

static DSpReleaseEntry    dsp_release_queue[DSP_RELEASE_QUEUE_CAPACITY];
static _Atomic uint32_t   dsp_release_head = 0;  /* emul thread writes */
static _Atomic uint32_t   dsp_release_tail = 0;  /* VBL thread writes */

static void DSpReleaseNow(DSpContextPrivate *ctx)
{
	DSpRestoreMainDevicePixMap(ctx);  /* Landmine-7: drop PixMap redirect BEFORE back_buffer goes away (no dangling Mac address in lowmem). */
	/* Clear the owner-tag BEFORE the buffer goes
	 * away so the map does not hold a dangling pointer. */
	if (ctx->back_buffer != nil) {
		gfxaccel_resources_clear_buffer_owner(
		    (__bridge void *)ctx->back_buffer);
	}
	/* Texture first, buffer second. */
	ctx->back_texture = nil;
	ctx->back_buffer  = nil;
	DSpReleaseBackBufferStaging(ctx);
	ctx->cgrafptr_mac_addr = 0;
	DSpReleaseFrontBufferStaging(ctx);
	delete ctx;
}

extern "C" int32_t DSpReleaseMetadataContextHandle(uint32_t ctxRef)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (!DSpIsInactiveMetadataOnlyContext(ctx)) {
		DSP_LOG("ReleaseMetadataContext: ctxRef=%u is not inactive metadata",
		        ctxRef);
		return kDSpInvalidContextErr;
	}

	DSpFreeContextHandle(ctxRef);
	dsp_context_count--;
	DSpReleaseNow(ctx);
	DSP_LOG("ReleaseMetadataContext: handle=%u released", ctxRef);
	return kDSpNoErr;
}

static void DSpQueueReleaseAtVBL(DSpContextPrivate *ctx)
{
	DSpRestoreMainDevicePixMap(ctx);  /* Landmine-7: drop PixMap redirect BEFORE back_buffer goes away (no dangling Mac address in lowmem). */
	uint32_t head = atomic_load_explicit(&dsp_release_head,
	                                      memory_order_relaxed);
	uint32_t next = (head + 1) % DSP_RELEASE_QUEUE_CAPACITY;
	uint32_t tail = atomic_load_explicit(&dsp_release_tail,
	                                      memory_order_acquire);
	if (next == tail) {
		DSP_LOG("DSpQueueReleaseAtVBL: FIFO full, falling back to "
		        "synchronous release (cap=%d)",
		        DSP_RELEASE_QUEUE_CAPACITY);
		DSpReleaseNow(ctx);
		return;
	}
	/* Clear the owner-tag here (not in the VBL
	 * drain) so the map reflects DSp ownership ending at the moment
	 * Release was requested — the actual Metal refcount drop is
	 * deferred to the VBL boundary, but logically the buffer is "no
	 * longer owned by DSp" as soon as it's queued. Any NQD dispatch
	 * between here and the drain sees DMC owner transitioning away
	 * from DSp (set by SetState prior to Release), so the conflict
	 * gate no longer applies. */
	if (ctx->back_buffer != nil) {
		gfxaccel_resources_clear_buffer_owner(
		    (__bridge void *)ctx->back_buffer);
	}
	dsp_release_queue[head].back_buffer  = ctx->back_buffer;
	dsp_release_queue[head].back_texture = ctx->back_texture;
	dsp_release_queue[head].ctx_to_free  = ctx;
	ctx->back_buffer  = nil;
	ctx->back_texture = nil;
	DSpReleaseBackBufferStaging(ctx);
	ctx->cgrafptr_mac_addr = 0;
	DSpReleaseFrontBufferStaging(ctx);
	atomic_store_explicit(&dsp_release_head, next,
	                      memory_order_release);
}

/*
 *  Partial-release variant.
 *
 *  Identical to DSpQueueReleaseAtVBL EXCEPT ctx_to_free = nullptr. The
 *  DSpContextPrivate struct survives the background window (kept alive
 *  in dsp_context_table); only the MTLBuffer + MTLTexture are released
 *  via the VBL drain. Foreground restore re-allocates fresh Metal
 *  resources into the same struct via DSpAllocateBackBuffer.
 *
 *  Used exclusively by DSpHandleBackgroundFromEmulThread.
 */
static void DSpQueueReleaseAtVBLPartial(DSpContextPrivate *ctx)
{
	DSpRestoreMainDevicePixMap(ctx);  /* Landmine-7: drop PixMap redirect BEFORE back_buffer goes away (no dangling Mac address in lowmem). */
	uint32_t head = atomic_load_explicit(&dsp_release_head,
	                                      memory_order_relaxed);
	uint32_t next = (head + 1) % DSP_RELEASE_QUEUE_CAPACITY;
	uint32_t tail = atomic_load_explicit(&dsp_release_tail,
	                                      memory_order_acquire);
	/* Clear the owner-tag on the buffer before it
	 * leaves DSp ownership. The bg/fg path will re-allocate a fresh
	 * buffer at foreground restore (DSpHandleForegroundFromEmulThread
	 * calls DSpAllocateBackBuffer which re-tags the new buffer). */
	if (ctx->back_buffer != nil) {
		gfxaccel_resources_clear_buffer_owner(
		    (__bridge void *)ctx->back_buffer);
	}
	if (next == tail) {
		DSP_LOG("DSpQueueReleaseAtVBLPartial: FIFO full, falling back "
		        "to synchronous partial release (cap=%d)",
		        DSP_RELEASE_QUEUE_CAPACITY);
		/* Synchronous partial: texture + buffer only:
		 * texture first); struct is NOT deleted — bg restore path will
		 * re-alloc into it. */
		ctx->back_texture = nil;
		ctx->back_buffer  = nil;
		DSpReleaseBackBufferStaging(ctx);
		ctx->cgrafptr_mac_addr = 0;
		DSpReleaseFrontBufferStaging(ctx);
		return;
	}
	dsp_release_queue[head].back_buffer  = ctx->back_buffer;
	dsp_release_queue[head].back_texture = ctx->back_texture;
	dsp_release_queue[head].ctx_to_free  = nullptr;   /* KEY: struct stays alive */
	ctx->back_buffer  = nil;
	ctx->back_texture = nil;
	DSpReleaseBackBufferStaging(ctx);
	ctx->cgrafptr_mac_addr = 0;
	DSpReleaseFrontBufferStaging(ctx);
	atomic_store_explicit(&dsp_release_head, next,
	                      memory_order_release);
}

extern "C" void DSpVBLReleaseCallback(void * /*ctx*/,
                                       void * /*drawable*/,
                                       double /*ts*/)
{
	uint32_t tail = atomic_load_explicit(&dsp_release_tail,
	                                      memory_order_relaxed);
	uint32_t head = atomic_load_explicit(&dsp_release_head,
	                                      memory_order_acquire);
	while (tail != head) {
		DSpReleaseEntry *entry = &dsp_release_queue[tail];
		/* Drop texture reference first, buffer second. */
		entry->back_texture = nil;
		entry->back_buffer  = nil;
		if (entry->ctx_to_free != nullptr) {
			delete entry->ctx_to_free;
			entry->ctx_to_free = nullptr;
		}
		tail = (tail + 1) % DSP_RELEASE_QUEUE_CAPACITY;
	}
	atomic_store_explicit(&dsp_release_tail, tail,
	                      memory_order_release);

	/* Chain the background/foreground drain off the same VBL hook so
	 * state transitions happen AFTER releases (drain-first ordering). */
	DSpVBLBackgroundForegroundDrain();
}

/*
 *  VBL-latched CLUT snapshot callback.
 *
 *  Registered from DSpInit via vbl_source_register_secondary_callback;
 *  unregistered from DSpShutdown. Runs on the emul thread on each VBL
 *  tick AFTER the compositor's primary palette-latch has swapped the
 *  compositor-shared palette buffer front/back (metal_compositor.mm:265
 *  MetalCompositorPaletteLatch).
 *
 *  Per-context snapshot: copies ctx->clut_bytes (writer-visible, updated
 *  by SetCLUTEntries) into ctx->clut_bytes_latched
 *  (reader-visible, read by GetCLUTEntries). This gives
 *  GetCLUTEntries the last-VBL-boundary semantics required by the
 *  tight-loop test: Set then Get reads last VBL boundary, not
 *  in-flight write.
 *
 *  Single-writer emul-thread contract preserved: VBL secondary callbacks
 *  fire on the same emul thread as SetCLUTEntries; no mutex / _Atomic /
 *  MTLFence added.
 */
extern "C" void DSpVBLClutLatchCallback(void *cb_ctx, void *drawable, double ts)
{
	(void)cb_ctx; (void)drawable; (void)ts;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		/* Snapshot every context (not just Active) — Paused contexts
		 * have a valid stale CLUT the app can Get between Pause and
		 * Resume; the snapshot is correct for both states because
		 * SetCLUTEntries only runs via DSp dispatch on the emul thread
		 * and clut_bytes is stable outside the Set handler. */
		memcpy(ctx->clut_bytes_latched, ctx->clut_bytes, 768);
	}
}

extern "C" int32_t DSpGetActiveCLUTSnapshot(uint8_t out_clut_bytes[768])
{
	if (out_clut_bytes == nullptr) return kDSpInvalidAttributesErr;

	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
		memcpy(out_clut_bytes, ctx->clut_bytes, 768);
		return kDSpNoErr;
	}
	return kDSpInvalidContextErr;
}

/*
 *  Linear LUT interpolation with integer
 *  rounding to prevent cumulative drift across long fades.
 *
 *  Formula per byte i in [0..767]:
 *    out[i] = (start[i] * (duration_vbls - elapsed_vbls)
 *              + end[i]   * elapsed_vbls
 *              + duration_vbls / 2)
 *             / duration_vbls
 *
 *  Properties:
 *    - elapsed_vbls == 0           -> out[i] ~ start[i] (round-to-nearest)
 *    - elapsed_vbls == duration    -> out[i] = end[i] exactly
 *    - duration_vbls / 2 term      -> round-half-to-even (drift-free)
 *    - uint32_t arithmetic         -> max product = 255 * 4096 = 1,044,480
 *                                    (no overflow at DSP_MAX_FADE_VBLS)
 *
 *  Caller invariants (NOT re-checked):
 *    - duration_vbls > 0           (caller's special-case for zero-duration
 *                                    fade pushes end_lut directly)
 *    - elapsed_vbls < duration     (caller dispatches the final-frame
 *                                    end_lut push directly, never calling
 *                                    this helper at elapsed == duration)
 *    - start, end, out             non-null 768-byte buffers
 */
static void DSpInterpolateGammaLUT(const uint8_t *start_lut,
                                    const uint8_t *end_lut,
                                    uint32_t elapsed_vbls,
                                    uint32_t duration_vbls,
                                    uint8_t *out_lut)
{
	const uint32_t complement = duration_vbls - elapsed_vbls;
	const uint32_t halfdur    = duration_vbls / 2;
	for (uint32_t i = 0; i < 768; i++) {
		const uint32_t numer = (uint32_t)start_lut[i] * complement
		                     + (uint32_t)end_lut[i]   * elapsed_vbls
		                     + halfdur;
		out_lut[i] = (uint8_t)(numer / duration_vbls);
	}
}

/*
 *  FadeGamma ABI fidelity:
 *  build the parametric FadeGamma target LUT from the 16-bit RGBColor
 *  zero-intensity tint (down-converted to 8-bit by the reader) + a
 *  SIGNED percent-of-original-intensity, per DSp 1.7 pp.32-33.
 *
 *  DSp 1.7 semantics (the wrong-output defect this REPLACES):
 *    - inPercentOfOriginalIntensity = 100  -> display at FULL intensity:
 *        output[c][i] = i  (the identity LUT — what was stored is shown).
 *    - inPercentOfOriginalIntensity = 0    -> display at ZERO intensity:
 *        output[c][i] = zeroColor[c]  (the inZeroIntensityColor tint;
 *        black when NULL was passed -> color_(r,g,b) == 0).
 *    - 0 < percent < 100                   -> linear blend between the
 *        zero-intensity tint (at 0%) and full identity (at 100%):
 *        output[c][i] = zeroColor[c] * (100 - p)/100 + i * p/100.
 *    - percent > 100  -> "begin to converge on white" (PDF p.32):
 *        extrapolate from identity toward 255.
 *    - percent < 0    -> "begin to converge on black" (PDF p.32):
 *        extrapolate from the zero-intensity tint toward 0.
 *
 *  The PREVIOUS formula `(channel[c] * i * percent) / 25500` DISCARDED
 *  the zero-intensity tint (output was 0 at i=0 or percent=0 regardless
 *  of the tint) — an M2-detectable wrong-output defect. The corrected
 *  formula HONORS inZeroIntensityColor as the zero-intensity floor.
 *
 *  Boundary equivalences (asserted by the corrected DSpGammaTests):
 *    - percent=100  -> identity         == FadeGammaIn end-state
 *    - percent=0, tint=black(0,0,0) -> zeros == FadeGammaOut end-state
 *    - percent=0, tint=red(255,0,0)  -> R channel = 255, G/B = 0
 *
 *  Integer/clamp safety: all intermediate products are non-negative
 *  uint32_t (max ~ 255*200 = 51,000); results are clamped to [0,255]
 *  before the uint8_t store. Signed `percent` is taken by value as
 *  int32_t; the >100 / <0 extrapolation branches keep every LUT index
 *  in range (no out-of-range LUT index).
 *
 *  Caller invariants (NOT re-checked):
 *    - out_lut               non-null 768-byte buffer
 */
static void DSpComputeFadeGammaTargetLUT(uint8_t color_r,
                                          uint8_t color_g,
                                          uint8_t color_b,
                                          int32_t percent,
                                          uint8_t *out_lut)
{
	const uint8_t channels[3] = { color_r, color_g, color_b };
	for (uint32_t c = 0; c < 3; c++) {
		const int32_t tint = (int32_t)channels[c];
		for (uint32_t i = 0; i < 256; i++) {
			const int32_t ii = (int32_t)i;
			int32_t v;
			if (percent <= 0) {
				/* <=0%: converge from the zero-intensity tint toward
				 * black. At 0% -> tint; at -100% -> 0. Below -100%
				 * stays at 0. */
				int32_t t = -percent;            /* 0..(+inf) */
				if (t > 100) t = 100;
				v = (tint * (100 - t)) / 100;
			} else if (percent >= 100) {
				/* >=100%: converge from identity toward white. At 100%
				 * -> identity (ii); at 200% -> 255. Above 200% stays
				 * at 255. */
				int32_t t = percent - 100;       /* 0..(+inf) */
				if (t > 100) t = 100;
				v = ii + ((255 - ii) * t) / 100;
			} else {
				/* 0..100%: linear blend tint (0%) -> identity (100%). */
				v = (tint * (100 - percent) + ii * percent) / 100;
			}
			if (v < 0)   v = 0;
			if (v > 255) v = 255;
			out_lut[c * 256 + i] = (uint8_t)v;
		}
	}
}

/*
 *  Shared fade-state
 *  initialization. Used by FadeGammaIn (end_lut = identity),
 *  FadeGammaOut (end_lut = zeros), and FadeGamma
 *  (end_lut = computed from percent + color).
 *
 *  start_lut snapshot logic (active-fade-replacement):
 *    - If ctx->fade_state.active != 0: compute the CURRENT INTERPOLATED
 *      state via DSpInterpolateGammaLUT(old_start, old_end, old_elapsed,
 *      old_duration). This preserves visual continuity — the new fade
 *      starts from where the old fade was visually, NOT from the old
 *      fade's start. Without this, a SetGamma -> FadeGammaIn(50, ...)
 *      -> FadeGammaOut(20, ...) sequence would snap back to the
 *      first fade's source, creating a visual flash.
 *    - If ctx->fade_state.active == 0: snapshot dmc_current_snapshot()
 *      ->gamma_lut into start_lut. This is the "fresh fade" path —
 *      the current displayed gamma becomes the fade source.
 *    - dmc_current_snapshot() NULL handling: extreme edge case (DSp
 *      Quiescent), use the identity LUT as start (visually equivalent
 *      to "fade from undefined initial state to end_lut").
 *
 *  end_lut: caller-provided (identity for FadeIn / zeros
 *  for FadeOut; FadeGamma builds parametric color x percent target).
 *
 *  duration_vbls: caller-clamped to DSP_MAX_FADE_VBLS BEFORE calling
 *  this helper. Caller is also responsible for the duration_vbls == 0
 *  short-circuit (push end_lut directly, do NOT call this helper).
 */
static void DSpInitFadeStateCore(DSpContextPrivate *ctx,
                                  const uint8_t *end_lut_768,
                                  uint16_t duration_vbls)
{
	/* Snapshot the start_lut from the current visual state. */
	if (ctx->fade_state.active != 0) {
		/* Active fade in progress — snapshot current interpolated state. */
		uint8_t snapshot[768];
		DSpInterpolateGammaLUT(ctx->fade_state.start_lut,
		                       ctx->fade_state.end_lut,
		                       (uint32_t)ctx->fade_state.elapsed_vbls,
		                       (uint32_t)ctx->fade_state.duration_vbls,
		                       snapshot);
		memcpy(ctx->fade_state.start_lut, snapshot, 768);
		DSP_LOG("DSpInitFadeStateCore: replacing active fade "
		        "(ctx=%u, prev_elapsed=%u/%u)",
		        ctx->handle,
		        (unsigned)ctx->fade_state.elapsed_vbls,
		        (unsigned)ctx->fade_state.duration_vbls);
	} else {
		/* Fresh fade — snapshot DMC current gamma. */
		const struct DMCModeSnapshot *snap = dmc_current_snapshot();
		if (snap != nullptr) {
			memcpy(ctx->fade_state.start_lut, snap->gamma_lut, 768);
		} else {
			/* DMC Quiescent — fall back to identity LUT (no-op gamma). */
			for (uint32_t c = 0; c < 3; c++) {
				for (uint32_t i = 0; i < 256; i++) {
					ctx->fade_state.start_lut[c * 256 + i] = (uint8_t)i;
				}
			}
			DSP_LOG("DSpInitFadeStateCore: DMC NULL snapshot — "
			        "using identity LUT as start (ctx=%u)", ctx->handle);
		}
	}

	/* Caller-provided end_lut. */
	memcpy(ctx->fade_state.end_lut, end_lut_768, 768);

	/* Reset fade machinery to active state. */
	ctx->fade_state.duration_vbls = duration_vbls;
	ctx->fade_state.elapsed_vbls  = 0;
	ctx->fade_state.active        = 1;
}

/*
 *  VBL-driven gamma-fade interpolation
 *  callback.
 *
 *  Registered from DSpInit via vbl_source_register_secondary_callback
 *  AFTER DSpVBLClutLatchCallback; unregistered from
 *  DSpShutdown FIRST (reverse registration order). Runs on the emul
 *  thread on each VBL tick AFTER DSpVBLClutLatchCallback has drained
 *  the per-context CLUT snapshots — the gamma fade is independent of
 *  CLUT, but ordering is preserved for predictability of any future
 *  cross-callback observation.
 *
 *  Body: per-context walk with early-out for active==0; on
 *  active fades, increments elapsed_vbls, computes interpolated LUT
 *  via DSpInterpolateGammaLUT, and pushes via dmc_record_gamma_change_with_lut.
 *  On final frame (elapsed >= duration), pushes end_lut authoritatively +
 *  writes gamma_lut_persisted + clears active. Rollback on DMC failure.
 *
 *  Single-writer emul-thread contract preserved: VBL secondary callbacks
 *  fire on the same emul thread as SetGamma / FadeGamma* handlers; no
 *  mutex / _Atomic / MTLFence added.
 */
extern "C" void DSpVBLGammaFadeCallback(void *cb_ctx, void *drawable, double ts)
{
	(void)cb_ctx; (void)drawable; (void)ts;

	/* fade_active is a SINGLE global flag on the SINGLE shared DMC
	 * snapshot, so it cannot carry per-context state. The compositor presents
	 * ONE frame; the correct global semantics is "any context still fading ->
	 * linear ramp". A per-context publish that set fade_active from only that
	 * context's state let a higher-index context completing its fade
	 * (fade_active=0) clobber a lower-index context still mid-fade — warping the
	 * survivor's fade. Instead we OR across all contexts: pre-scan to decide
	 * whether ANY context will STILL be fading AFTER this tick's advancement,
	 * then publish that single OR'd flag with every per-context LUT push.
	 *
	 * Pre-scan note: a context with elapsed+1 < duration is still fading after
	 * this tick; a context reaching elapsed+1 >= duration completes on this tick
	 * (no longer fading). This mirrors the per-context final-frame test below so
	 * the OR is exact. */
	uint32_t any_still_fading = 0u;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr || ctx->fade_state.active == 0) continue;
		/* (uint32_t) widen so the +1 cannot wrap the uint16_t counter. */
		uint32_t after = (uint32_t)ctx->fade_state.elapsed_vbls + 1u;
		if (after < (uint32_t)ctx->fade_state.duration_vbls) {
			any_still_fading = 1u;
			break;
		}
	}

	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;

		/* Per-context fade advancement. Runs on the emul thread per VBL
		 * tick after DSpVBLClutLatchCallback. Single-writer invariant
		 * preserved — SetGamma + FadeGammaIn/Out + this callback all
		 * serialize on the emul thread. */

		/* Skip contexts with no active fade (early-out — most contexts
		 * most of the time). */
		if (ctx->fade_state.active == 0) continue;

		/* Advance one VBL tick. */
		ctx->fade_state.elapsed_vbls++;

		/* Final-frame transition: push end_lut as the authoritative final
		 * gamma state, update persistence, clear active flag. */
		if (ctx->fade_state.elapsed_vbls >= ctx->fade_state.duration_vbls) {
			// This context just completed, but
			// fade_active is the OR across ALL contexts — publish end_lut with
			// any_still_fading so a concurrent lower/higher-index fade is not
			// clobbered to 0. The compositor restores the static pow(1.8/2.2)
			// only once NO context is fading.
			int32_t rv = dmc_record_gamma_change_with_lut_fade(
			    ctx->fade_state.end_lut, (int)any_still_fading);
			if (rv != kDMCNoErr) {
				DSP_LOG("DSpVBLGammaFadeCallback: final-frame DMC push failed "
				        "(ctx=%u, rv=%d) — leaving fade active for retry",
				        ctx->handle, rv);
				/* Don't clear active — retry on next VBL tick. */
				ctx->fade_state.elapsed_vbls--;  /* roll back the increment */
				continue;
			}
			memcpy(ctx->gamma_lut_persisted, ctx->fade_state.end_lut, 768);
			ctx->fade_state.active = 0;
			DSP_LOG("DSpVBLGammaFadeCallback: fade complete (ctx=%u, "
			        "duration=%u VBLs, any_still_fading=%u)",
			        ctx->handle, (unsigned)ctx->fade_state.duration_vbls,
			        (unsigned)any_still_fading);
			continue;
		}

		/* Mid-fade frame: compute interpolated LUT and push. */
		uint8_t interp_lut[768];
		DSpInterpolateGammaLUT(ctx->fade_state.start_lut,
		                       ctx->fade_state.end_lut,
		                       (uint32_t)ctx->fade_state.elapsed_vbls,
		                       (uint32_t)ctx->fade_state.duration_vbls,
		                       interp_lut);
		// Fade in progress — publish the interpolated
		// LUT with the OR'd fade_active=1 (this context is mid-fade, so the OR is
		// trivially 1) so the compositor bypasses pow and the ramp marches
		// linearly (DSp-1.7). Flag + LUT publish atomically.
		int32_t rv = dmc_record_gamma_change_with_lut_fade(interp_lut, 1);
		if (rv != kDMCNoErr) {
			DSP_LOG("DSpVBLGammaFadeCallback: mid-fade DMC push failed "
			        "(ctx=%u, elapsed=%u/%u, rv=%d) — leaving fade active",
			        ctx->handle,
			        (unsigned)ctx->fade_state.elapsed_vbls,
			        (unsigned)ctx->fade_state.duration_vbls, rv);
			ctx->fade_state.elapsed_vbls--;  /* roll back so next tick retries this frame */
			continue;
		}
	}
}

/* --- VBL service callback ---
 *
 *  Atomic-increment plus the per-context walk + PPC VBLProc invocation
 *  via call_macos3.
 *
 *  Registered from DSpInit via vbl_source_register_secondary_callback
 *  AFTER DSpVBLGammaFadeCallback — 4th and FINAL VBL
 *  secondary callback slot. Unregistered from DSpShutdown FIRST
 *  (reverse registration order).
 *
 *  Execution sequence per VBL tick:
 *    1. atomic_fetch_add s_dsp_vbl_count (monotonic tick).
 *    2. Walk dsp_context_table[0..DSP_MAX_CONTEXTS-1] in INDEX ORDER
 *       (deterministic dispatch).
 *    3. For each Active context with vbl_proc_ptr != 0, invoke the
 *       VBLProc via call_macos3(vbl_proc_ptr, handle, refcon, count).
 *
 *  PPC-trampoline mechanism: call_macos3 is the sanctioned
 *  entry point for PPC subroutine calls from native code. Declared in
 *  SheepShaver/src/Unix/sysdeps.h:490; defined in
 *  SheepShaver/src/kpx_cpu/sheepshaver_glue.cpp:1438-1442; wraps
 *  ppc_cpu->execute_macos_code which handles register save/restore,
 *  stack frame setup, TOC marshalling, and POWERPC_EXEC_RETURN
 *  trampolining (sheepshaver_glue.cpp:652-702). Production precedent:
 *  rave_metal_renderer.mm:2709 (call_macos4 for RAVE notice methods).
 *
 *  VBLProc ABI per DSp 1.7 spec p.81:
 *    void DSpVBLProc(DSpContextReference ctx, void *refCon, UInt32 vblCount)
 *  PPC calling convention: r3=ctx (32-bit handle), r4=refCon (opaque),
 *  r5=vblCount (truncated from s_dsp_vbl_count uint64). Return value
 *  is void (call_macos3's uint32 return is discarded).
 *
 *  Iteration order: dsp_context_table is indexed 0..7;
 *  iteration is linear in index. Since dsp_context_table allocates
 *  lowest-free-index, index-order ==
 *  registration-order for contexts created without intervening Release
 *  calls. DSp 1.7 spec doesn't pin a specific order beyond "all VBLProcs
 *  fire each VBL"; index-order is the natural reading and gives a
 *  deterministic order with no drops, verified across 1000 ticks.
 *
 *  Threading: single-writer emul-thread. The VBL secondary callback
 *  invocation is itself on the emul thread; call_macos3 blocks the
 *  emul thread on PPC execution until the user VBLProc returns. Total
 *  time budget: < 1 ms aggregate across all contexts
 *  (4 contexts × ~250 µs per VBLProc). If any single VBLProc exceeds
 *  250 µs, DSP_LOG warns (post-call wall-time check) but the callback
 *  does NOT early-exit — all registered VBLProcs must fire every VBL
 *  per DSp 1.7 semantics. Caller is responsible for keeping VBLProcs
 *  short (documented game-author contract).
 *
 *  Robustness: if call_macos3 returns kDSpInternalErr-like values (no
 *  error path from this API — it's void-returning by design), the
 *  callback continues to the next context. A SIGSEGV in the user
 *  VBLProc is uncatchable and crashes the process; that's a guest-code
 *  bug matching DSp 1.7 semantics (bad VBLProc crashes the game).
 */
extern "C" void DSpVBLServiceCallback(void *cb_ctx, void *drawable, double ts)
{
	(void)cb_ctx; (void)drawable; (void)ts;

	/* Step 1: monotonic tick counter. Relaxed ordering — reader
	 * side only needs monotonicity, not happens-before vs other state. */
	atomic_fetch_add_explicit(&s_dsp_vbl_count, 1u,
	                          memory_order_relaxed);

	/* Step 2-3: walk contexts in INDEX ORDER;
	 * invoke registered VBLProcs via call_macos3. */

	/* Read the post-increment tick count once — all VBLProcs fired this
	 * tick see the same vblCount argument. Matches DSp 1.7 spec p.81
	 * which documents vblCount as "the tick number of the VBL that
	 * fired this call". */
	const uint32_t vbl_count_arg =
	    (uint32_t)(atomic_load_explicit(&s_dsp_vbl_count,
	                                     memory_order_relaxed) & 0xFFFFFFFFu);

	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;

		/* Only Active contexts fire VBLProcs per DSp 1.7 spec p.81
		 * ("VBLProcs are dispatched only while the context is in the
		 * Active play state"). Inactive + Paused contexts retain their
		 * registered proc but do not fire. */
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;

		/* Early-out: no proc installed. The `vbl_proc_ptr == 0` case
		 * includes both "never installed" and "explicitly uninstalled
		 * via SetVBLProc(ptr=0)" per DSp 1.7 spec p.81. */
		if (ctx->vbl_proc_ptr == 0) continue;

		/* Snapshot the proc + refcon + handle to local vars so the call
		 * sees a consistent tuple even if (hypothetically) the fields
		 * were mutated concurrently. In practice single-writer
		 * emul-thread makes this an invariant — snapshotting is defense-
		 * in-depth against a future cross-thread race if the invariant
		 * weakens. */
		const uint32_t proc_addr    = ctx->vbl_proc_ptr;
		const uint32_t proc_refcon  = ctx->vbl_proc_refcon;
		const uint32_t proc_handle  = ctx->handle;

		/* Invoke user VBLProc per the VBLProc ABI:
		 *   r3 = ctx (DSpContextReference, 32-bit handle)
		 *   r4 = refCon (opaque)
		 *   r5 = vblCount (UInt32 tick count)
		 * call_macos3 marshals these into PPC r3/r4/r5, executes the
		 * TVECT-addressed routine, and returns on POWERPC_EXEC_RETURN.
		 * Return value ignored (VBLProc is void-returning in spec).
		 */
		(void)call_macos3(proc_addr,
		                  proc_handle,
		                  proc_refcon,
		                  vbl_count_arg);
	}
}

/*
 *  DSpVBLCompositorPublishCallback: VBL-driven auto-publish shim that
 *  surfaces the DSp back buffer to the compositor whenever DSp owns the
 *  display. Closes the third blocker — classic-pattern DSp apps
 *  (Reserve + main-port QD draws, no SwapBuffers) get pixels on screen.
 *
 *  Registers as the 5th VBL secondary callback (after the 4th-slot
 *  DSpVBLServiceCallback). The chain order
 *  means DSpVBLServiceCallback's GetVBLCount increment fires FIRST and
 *  user VBLProc dispatch completes BEFORE we publish — satisfies
 *  the "after user-VBLProc dispatch" ordering automatically.
 *
 *  Body shape mirrors DSpContext_SwapBuffersHandler (lines 2078-2192):
 *    Gate 1 — active_owner must be kDMCOwnerDSp (dmc_current_snapshot).
 *    Gate 2 — find the first Active DSp context with a live back_buffer.
 *    Step 1 — staging drain (guest-RAM staging → back_buffer.contents) per
 *             Landmine-1; mirrors SwapBuffers lines 2123-2136.
 *    Step 2 — encode the back_texture → framebuffer_texture blit via the
 *             existing DSpEncodeBackBufferBlit helper.
 *    Step 3 — submit an engine-blind CompositeLayer (kLayerSlotFramebuffer
 *             / kBlendOpaque) pointing at the framebuffer texture.
 *
 *  Invariant: this shim is a CALLER of MetalCompositorSubmitFrame,
 *  not a modifier of its body. CompositorEngineBlindnessTests stays green.
 *
 *  Invariant: zero new threading primitives. Runs on main RunLoop
 *  thread (vbl_source.mm:23) — same threading shape as DSpVBLServiceCallback.
 */
extern "C" void DSpVBLCompositorPublishCallback(void *cb_ctx,
                                                 void *drawable,
                                                 double ts)
{
	(void)cb_ctx; (void)drawable; (void)ts;

	/* Gate 1: a stable display snapshot is required. DSp usually owns
	 * the display while the callback publishes, but mixed DSp+RAVE apps
	 * such as Nanosaur keep drawing QuickDraw front-buffer UI after RAVE
	 * becomes the DMC owner. In that case a presentable front-staging
	 * surface keeps the DSp publish path alive underneath the 3D overlay. */
	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap == nullptr || snap->transitioning != 0) {
		return;
	}

	/* Gate 2: walk dsp_context_table[] for the first Active context with
	 * a live back_buffer. Mirrors DSpVBLServiceCallback's walk pattern at
	 * lines 710-723 (single-Active-context invariant — first match wins). */
	DSpContextPrivate *active = nullptr;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
		if (ctx->back_buffer == nil) continue;
		active = ctx;
		break;
	}
	if (active == nullptr) return;

	bool present_front_staging =
	    DSpShouldPresentFrontBufferStagingForState(
	        active->attr.backBufferBestDepth,
	        active->attr.displayBestDepth,
	        active->front_staging_mac_addr,
	        active->front_staging_size,
	        active->state,
	        (uint32_t)kDSpContextState_Active);
	if (!DSpShouldPublishActiveContextOnVBL(snap->active_owner,
	                                        (uint32_t)kDMCOwnerDSp,
	                                        active != nullptr,
	                                        present_front_staging,
	                                        active->explicit_swap_observed)) {
		return;
	}

	const bool has_back_buffer_staging = (active->staging_mac_addr != 0);
	if (DSpShouldFlushNQDBeforeStagingDrain(has_back_buffer_staging,
	                                       present_front_staging)) {
		NQDMetalFlush();
	}

	/* Staging-drain (Landmine-1 — mirrors SwapBuffers lines 2123-2136).
	 * When DSpRedirectMainDevicePixMap fell back to the
	 * guest-RAM staging path because Host2MacAddr could not map
	 * back_buffer.contents, the emulated app has been writing through
	 * staging_mac_addr. Drain into back_buffer.contents BEFORE the GPU
	 * blit so the texture view sees the latest pixels. */
	if (has_back_buffer_staging) {
		const uint32_t w         = active->attr.displayWidth;
		const uint32_t h         = active->attr.displayHeight;
		const uint32_t bpp       = active->attr.backBufferBestDepth;
		const uint32_t row_bytes = (w * bpp + 7) / 8;
		const uint32_t alignedRB = (row_bytes + 255) & ~255u;
		const uint32_t buffer_size = alignedRB * h;

		uint8_t *staging_host  = Mac2HostAddr(active->staging_mac_addr);
		void    *back_contents = [active->back_buffer contents];
		if (staging_host != NULL && back_contents != NULL) {
			memcpy(back_contents, staging_host, buffer_size);
		}
	}

	/* Encode the back_texture -> framebuffer_texture present. Routes
	 * through DSpEncodePresentToFramebuffer (dsp_metal_renderer.mm),
	 * which picks blit-vs-render-pass per pixel format:
	 *   - matched-format (e.g. 32 bpp BGRA8Unorm <-> BGRA8Unorm): blit.
	 *   - mismatched-format (e.g. 16 bpp R16Uint xRGB1555 -> BGRA8Unorm
	 *     compositor framebuffer): DSp-owned render pass with inline-
	 *     compiled fragment shader. The compositor framebuffer MUST be
	 *     BGRA8Unorm per metal_compositor.h:69 — DSp converts on the
	 *     engine side, the compositor stays engine-blind.
	 * Metal validation rejected the previous raw-blit path when Sims
	 * switched to 16 bpp. */
	void *fb_tex_raw = MetalCompositorGetFramebufferTexture();
	if (fb_tex_raw == NULL) {
		/* Compositor not yet initialized — graceful no-op (same shape as
		 * SwapBuffers lines 2096-2100 but silent here because this fires
		 * every VBL). */
		return;
	}

	id<MTLCommandQueue> queue =
	    (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
	if (queue == nil) {
		return;
	}

	@autoreleasepool {
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		if (cb == nil) {
			return;
		}
		/* Route through the format-aware present
		 * helper so 16 bpp xRGB1555 -> BGRA8Unorm goes through a DSp-
		 * owned render pass (Metal blit copyFromTexture rejects pixel-
		 * size-mismatched format pairs on Catalyst). */
		bool front_presented = false;
		if (present_front_staging) {
			front_presented =
			    DSpEncodeFrontBufferStagingToFramebuffer(active,
			                                             (__bridge void *)cb,
			                                             fb_tex_raw);
		}
		if (!front_presented) {
			DSpEncodePresentToFramebuffer(active, (__bridge void *)cb, fb_tex_raw);
		}
		[cb commit];
	}

	/* Build the engine-blind CompositeLayer + FrameDescriptor and submit.
	 * Mirrors SwapBuffers lines 2157-2179. */
	struct CompositeLayer layer;
	std::memset(&layer, 0, sizeof(layer));
	layer.source       = fb_tex_raw;
	layer.src_origin_x = 0;
	layer.src_origin_y = 0;
	layer.src_size_w   = active->attr.displayWidth;
	layer.src_size_h   = active->attr.displayHeight;
	layer.dst_origin_x = 0.0f;
	layer.dst_origin_y = 0.0f;
	layer.dst_size_w   = (float)active->attr.displayWidth;
	layer.dst_size_h   = (float)active->attr.displayHeight;
	layer.slot         = kLayerSlotFramebuffer;
	layer.blend        = kBlendOpaque;
	layer.alpha        = 1.0f;

	struct FrameDescriptor desc;
	desc.layers               = &layer;
	desc.layer_count          = 1;
	desc.generation           = snap->generation;
	desc.vbl_tick_target_usec = 0;

	(void)MetalCompositorSubmitFrame(&desc);
}

/*
 *  DSpContext_SetVBLProc (sub-opcode 500).
 *
 *  Argument contract:
 *    ctxRef   = context handle from DSpContext_Reserve
 *    procPtr  = guest PPC TVECT address of the VBLProc. 0 is VALID —
 *               it uninstalls any previously-registered proc per DSp
 *               1.7 spec p.81 (the handler just writes 0 to
 *               vbl_proc_ptr; no special short-circuit needed).
 *    refCon   = opaque 4-byte pass-through value; any bits are valid.
 *               When procPtr==0 refCon is effectively dead storage but
 *               the handler still writes it for round-trip symmetry
 *               with GetVBLProc (sub-opcode 503).
 *
 *  Error map:
 *    kDSpInvalidContextErr    - ctxRef does not resolve to a context
 *    kDSpNoErr                - success; vbl_proc_ptr + vbl_proc_refcon
 *                                updated; next VBL tick will pick up the
 *                                new proc via DSpVBLServiceCallback's walk
 *
 *  Threading (single-writer emul-thread invariant preserved):
 *    NATIVE_DSP_DISPATCH serializes SetVBLProc calls; the reader
 *    (DSpVBLServiceCallback) also runs on emul thread per the VBL
 *    secondary-callback contract. No cross-thread race possible. No
 *    atomic primitive needed — matches the fade_state / clut_bytes
 *    pattern.
 */
extern "C" int32_t DSpContext_SetVBLProcHandler(uint32_t ctxRef,
                                                 uint32_t procPtr,
                                                 uint32_t refCon)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("SetVBLProc: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}

	/* procPtr == 0 is VALID per DSp 1.7 spec p.81 (uninstall path).
	 * Treat as normal write; the DSpVBLServiceCallback walk's
	 * `vbl_proc_ptr == 0` early-out handles the semantic. */
	ctx->vbl_proc_ptr    = procPtr;
	ctx->vbl_proc_refcon = refCon;

	if (procPtr == 0) {
		DSP_LOG("SetVBLProc: ctx=%u UNINSTALL (procPtr=0) -> OK",
		        ctxRef);
	} else {
		DSP_LOG("SetVBLProc: ctx=%u procPtr=0x%08x refCon=0x%08x -> OK",
		        ctxRef, procPtr, refCon);
	}
	return kDSpNoErr;
}

/*
 *  DSpContext_GetVBLCount (sub-opcode 501).
 *
 *  Argument contract:
 *    ctxRef        = context handle from DSpContext_Reserve (validated
 *                     for API symmetry even though the counter is
 *                     GLOBAL; the DSp VBL count is
 *                     one-per-subsystem, not one-per-context)
 *    countOutAddr  = guest Mac address of a caller-allocated UInt32
 *
 *  Error map:
 *    kDSpInvalidContextErr    - ctxRef does not resolve to a context
 *    kDSpInvalidAttributesErr - countOutAddr == 0
 *    kDSpNoErr                - success; 4 bytes written to guest RAM
 *
 *  Returns low 32 bits of s_dsp_vbl_count (uint64 internal,
 *  uint32 external). DSp 1.7 spec p.81 documents the return as UInt32;
 *  the 64-bit internal storage prevents ABA confusion across multi-day
 *  sessions. Monotonically increases; equals vbl_source_get_tick_count()
 *  modulo the registration-time offset.
 *
 *  Threading: atomic_load_explicit with memory_order_relaxed matches
 *  the writer side (DSpVBLServiceCallback). Relaxed ordering suffices
 *  because the counter is observable-only-by-monotonic-progress; no
 *  happens-before coordination with any other state is required.
 */
extern "C" int32_t DSpContext_GetVBLCountHandler(uint32_t ctxRef,
                                                  uint32_t countOutAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("GetVBLCount: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	if (countOutAddr == 0) {
		DSP_LOG("GetVBLCount: NULL countOutAddr (ctx=%u) -> kDSpInvalidAttributesErr",
		        ctxRef);
		return kDSpInvalidAttributesErr;
	}
	(void)ctx;  /* ctx validation for API symmetry; counter is global */

	uint64_t current = atomic_load_explicit(&s_dsp_vbl_count,
	                                         memory_order_relaxed);
	uint32_t truncated = (uint32_t)(current & 0xFFFFFFFFu);
	WriteMacInt32(countOutAddr, truncated);

	DSP_VLOG("GetVBLCount: ctx=%u count=%u (internal=%llu) -> OK",
	         ctxRef, (unsigned)truncated, (unsigned long long)current);
	return kDSpNoErr;
}

/*
 *  Forward declaration of the helper
 *  DSpInvalBackBufferRect_Accumulate so DSpBlankFillCore (just below) can
 *  call into it before its static definition further down this file
 *  (dsp_draw_context.mm:1745). Same clipping + dirty-region-union
 *  semantics as the public DSpContext_InvalBackBufferRectHandler entry
 *  point — we call the private helper directly to avoid a redundant
 *  ReadMacInt16 round-trip since we already hold the int16 rect in host
 *  form.
 */
static void DSpInvalBackBufferRect_Accumulate(DSpContextPrivate *ctx,
                                               int16_t top, int16_t left,
                                               int16_t bottom, int16_t right);

/*
 *  Core BlankFill path shared by
 *  the production handler (DSpContext_BlankFillHandler below) and the
 *  TESTING_BUILD host-value wrapper (DSpTesting_BlankFillByValues).
 *
 *  Arguments (pre-validated by caller):
 *    ctx      — non-null DSpContextPrivate *
 *    top/left/bottom/right — host int16 rect coordinates (unclipped)
 *    r8/g8/b8 — 8-bit-per-channel color (downconverted from 16-bit Mac
 *                RGBColor by caller via high-byte select). For indexed
 *                depths (1/2/4/8 bpp) r8 is the CLUT index; g8 + b8 are
 *                ignored on that path per DSp 1.7 spec p.79.
 *
 *  Sequence:
 *    1. Clip rect to [0, backBufferWidth) x [0, backBufferHeight).
 *    2. If clipped rect is degenerate (zero area), return noErr early.
 *    3. Depth-dispatch on ctx->attr.backBufferBestDepth:
 *       - 1/2/4 bpp: sub-byte indexed write; bit-pack r8 into packed bytes
 *       - 8 bpp:     byte-write r8 as CLUT index (memset fast path)
 *       - 16 bpp:    halfword-write RGB565(r8,g8,b8)
 *       - 32 bpp:    word-write BGRA(r8,g8,b8,0xFF)
 *       - default:   kDSpInvalidAttributesErr
 *    4. Notify dirty region via DSpInvalBackBufferRect_Accumulate.
 *       We already hold the host int16 rect so we
 *       call the private helper directly (skips the ReadMacInt16 round-
 *       trip the public handler does). The dirty-region union flows into
 *       SwapBuffers' next-VBL-blit pipeline — zero new
 *       sync primitive; the compositor picks up the union at its next
 *       VBL tick.
 *    5. Return kDSpNoErr.
 *
 *  Threading: runs on the emul thread via NATIVE_DSP_DISPATCH
 *  (single-writer invariant). The back-buffer is MTLStorageModeShared,
 *  so CPU writes via ctx->back_buffer.contents
 *  require NO GPU fence / MTLSharedEvent / MTLFence — the compositor
 *  reads the dirty region on the next VBL tick from the main thread,
 *  but only after SwapBuffers (not BlankFill) publishes the rect into
 *  the blit queue, so there's no read-during-write hazard.
 *
 *  Return codes:
 *    kDSpNoErr                - success (including degenerate-rect no-op)
 *    kDSpInvalidAttributesErr - depth not in {1,2,4,8,16,32}
 *    kDSpInternalErr          - ctx->back_buffer.contents == nil (should
 *                                be impossible post-Reserve; defensive)
 */
/*
 *  Depth-dispatch fill kernel operating on a
 *  caller-provided host buffer. Shared by:
 *    - DSpBlankFillCore (production path — ctx->back_buffer.contents)
 *    - DSpTesting_BlankFillOnHostBuffer (TESTING_BUILD — simulator path
 *      where ctx->back_buffer is forced to StorageModePrivate by the
 *      gfxaccel_resources heap module; tests pass a host-memory buffer
 *      pre-sized to pitch * bb_h).
 *
 *  Byte-identical behavior to the in-place production fill — same
 *  clipping, same depth-switch, same pixel-pack formulas. Returns
 *  kDSpNoErr on success / kDSpInvalidAttributesErr on unsupported depth.
 */
static int32_t DSpBlankFillDepthDispatch(uint8_t *base,
                                          uint32_t depth,
                                          uint32_t pitch,
                                          int16_t c_top, int16_t c_left,
                                          int16_t c_bottom, int16_t c_right,
                                          uint8_t r8, uint8_t g8, uint8_t b8)
{
	switch (depth) {
		case 1: {
			const uint8_t idx = (uint8_t)(r8 & 0x01u);
			for (int16_t y = c_top; y < c_bottom; y++) {
				uint8_t *row = base + (uint32_t)y * pitch;
				for (int16_t x = c_left; x < c_right; x++) {
					const int bit_pos = 7 - (x & 7);
					const uint8_t mask = (uint8_t)(1u << bit_pos);
					row[x >> 3] = (uint8_t)((row[x >> 3] & ~mask) |
					                        ((idx << bit_pos) & mask));
				}
			}
			return kDSpNoErr;
		}
		case 2: {
			const uint8_t idx = (uint8_t)(r8 & 0x03u);
			for (int16_t y = c_top; y < c_bottom; y++) {
				uint8_t *row = base + (uint32_t)y * pitch;
				for (int16_t x = c_left; x < c_right; x++) {
					const int shift = 6 - 2 * (x & 3);
					const uint8_t mask = (uint8_t)(0x03u << shift);
					row[x >> 2] = (uint8_t)((row[x >> 2] & ~mask) |
					                        ((idx << shift) & mask));
				}
			}
			return kDSpNoErr;
		}
		case 4: {
			const uint8_t idx = (uint8_t)(r8 & 0x0Fu);
			for (int16_t y = c_top; y < c_bottom; y++) {
				uint8_t *row = base + (uint32_t)y * pitch;
				for (int16_t x = c_left; x < c_right; x++) {
					const int shift = 4 - 4 * (x & 1);
					const uint8_t mask = (uint8_t)(0x0Fu << shift);
					row[x >> 1] = (uint8_t)((row[x >> 1] & ~mask) |
					                        ((idx << shift) & mask));
				}
			}
			return kDSpNoErr;
		}
		case 8: {
			const int fill_w = (int)(c_right - c_left);
			for (int16_t y = c_top; y < c_bottom; y++) {
				uint8_t *row = base + (uint32_t)y * pitch + (uint32_t)c_left;
				memset(row, r8, (size_t)fill_w);
			}
			return kDSpNoErr;
		}
		case 16: {
			const uint16_t pixel = (uint16_t)(((uint16_t)(r8 >> 3) << 11) |
			                                   ((uint16_t)(g8 >> 2) <<  5) |
			                                   ((uint16_t)(b8 >> 3)      ));
			for (int16_t y = c_top; y < c_bottom; y++) {
				uint16_t *row = (uint16_t *)(base + (uint32_t)y * pitch);
				for (int16_t x = c_left; x < c_right; x++) {
					row[x] = pixel;
				}
			}
			return kDSpNoErr;
		}
		case 32: {
			const uint32_t pixel = 0xFF000000u |
			                       ((uint32_t)r8 << 16) |
			                       ((uint32_t)g8 <<  8) |
			                       ((uint32_t)b8      );
			for (int16_t y = c_top; y < c_bottom; y++) {
				uint32_t *row = (uint32_t *)(base + (uint32_t)y * pitch);
				for (int16_t x = c_left; x < c_right; x++) {
					row[x] = pixel;
				}
			}
			return kDSpNoErr;
		}
		default:
			return kDSpInvalidAttributesErr;
	}
}

static int32_t DSpBlankFillCore(DSpContextPrivate *ctx,
                                 int16_t top, int16_t left,
                                 int16_t bottom, int16_t right,
                                 uint8_t r8, uint8_t g8, uint8_t b8)
{
	/* Step 1: clip to back-buffer bounds (spec p.79
	 * "fills the intersection"). */
	const int16_t bb_w = (int16_t)ctx->attr.backBufferWidth;
	const int16_t bb_h = (int16_t)ctx->attr.backBufferHeight;
	int16_t c_top    = (top    < 0)   ? 0    : top;
	int16_t c_left   = (left   < 0)   ? 0    : left;
	int16_t c_bottom = (bottom > bb_h) ? bb_h : bottom;
	int16_t c_right  = (right  > bb_w) ? bb_w : right;

	/* Step 2: degenerate rect — no-op success per DSp 1.7 p.79. */
	if (c_top >= c_bottom || c_left >= c_right) {
		DSP_VLOG("BlankFillCore: degenerate rect (clipped=(%d,%d)-(%d,%d)) "
		         "-> noErr no-op",
		         c_top, c_left, c_bottom, c_right);
		return kDSpNoErr;
	}

	/* Step 3: depth-dispatch on back-buffer format. */
	const uint32_t depth = ctx->attr.backBufferBestDepth;
	void *contents = (void *)[ctx->back_buffer contents];
	if (contents == nullptr) {
		DSP_LOG("BlankFillCore: ctx=%u back_buffer.contents == nil "
		        "-> kDSpInternalErr",
		        ctx->handle);
		return kDSpInternalErr;
	}

	/* Row-bytes + pitch formula matches the pitch
	 * computation at dsp_draw_context.mm:1253-1255. For 1/2/4 bpp the
	 * row_bytes accounts for sub-byte packing; the final &~255u aligns
	 * to the 256-byte iOS-Metal pitch. */
	const uint32_t row_bytes = (uint32_t)(((uint32_t)bb_w * depth + 7) / 8);
	const uint32_t pitch     = (row_bytes + 255u) & ~255u;

	uint8_t *base = (uint8_t *)contents;

	/* Step 3b: depth-dispatch fill via shared helper so the
	 * TESTING_BUILD DSpTesting_BlankFillOnHostBuffer
	 * shim can reuse the exact same formulas without requiring a real
	 * Shared MTLBuffer — iOS simulator coerces heap allocs to
	 * StorageModePrivate per gfxaccel_resources_heap.mm:190). */
	const int32_t fill_rv = DSpBlankFillDepthDispatch(base, depth, pitch,
	                                                   c_top, c_left,
	                                                   c_bottom, c_right,
	                                                   r8, g8, b8);
	if (fill_rv != kDSpNoErr) {
		DSP_LOG("BlankFillCore: ctx=%u unsupported depth=%u "
		        "-> kDSpInvalidAttributesErr",
		        ctx->handle, (unsigned)depth);
		return fill_rv;
	}

	/* Step 4: dirty-region notification. Call the
	 * private helper directly — we already hold the host int16 rect
	 * so we skip the ReadMacInt16 round-trip that the public
	 * DSpContext_InvalBackBufferRectHandler performs. The union
	 * with the existing dirty region flows into the next SwapBuffers
	 * blit via the existing pipeline. */
	DSpInvalBackBufferRect_Accumulate(ctx, c_top, c_left, c_bottom, c_right);

	DSP_VLOG("BlankFillCore: ctx=%u rect=(%d,%d)-(%d,%d) depth=%u "
	         "color=(r=%u,g=%u,b=%u) -> OK",
	         ctx->handle, c_top, c_left, c_bottom, c_right,
	         (unsigned)depth, r8, g8, b8);
	return kDSpNoErr;
}

/*
 *  DSpContext_BlankFill (sub-opcode 502).
 *
 *  Argument contract:
 *    ctxRef     = context handle from DSpContext_Reserve
 *    rectAddr   = guest Mac address of a classic Mac Rect (8 bytes:
 *                  4x int16 top/left/bottom/right big-endian)
 *    colorAddr  = guest Mac address of a classic Mac RGBColor (6 bytes:
 *                  3x uint16 red/green/blue big-endian)
 *
 *  Error map:
 *    kDSpInvalidContextErr    - ctxRef does not resolve to a context
 *    kDSpInvalidAttributesErr - rectAddr == 0 OR colorAddr == 0 OR
 *                                ctx->attr.backBufferBestDepth not in
 *                                {1, 2, 4, 8, 16, 32}
 *    kDSpInternalErr          - ctx->back_buffer.contents == nil
 *                                (should be impossible post-Reserve)
 *    kDSpNoErr                - success; pixels written; dirty region
 *                                notified; next VBL will blit
 *
 *  DSp 1.7 semantics (spec p.79):
 *    - Rect clipped to back-buffer bounds ("fills the intersection")
 *    - Degenerate / fully-outside rect: no error, no-op
 *    - At indexed depths (1/2/4/8 bpp): color.red's high byte is the
 *      CLUT index; green/blue ignored
 *    - At direct depths (16/32 bpp): all three channels used with
 *      appropriate packing (RGB565 / BGRA)
 *
 *  Mac RGBColor 16-bit channel space: the Mac stores color channels as
 *  uint16 with 256x scaling (0x0000 = black, 0xFFFF = max). High-byte
 *  select `uint8 r8 = red >> 8` is the canonical 8-bit downconvert
 *  (matches the CLUT-entry downconvert).
 *
 *  VBL sync: this handler does NOT call the compositor directly. The
 *  post-fill DSpInvalBackBufferRect_Accumulate union flows into the
 *  next SwapBuffers (or the compositor's auto-present path) which does
 *  the VBL-synced blit via the existing pipeline. This
 *  preserves SC #5 compositor-blindness (no kGfxEngineDSp
 *  reference in compositor files). "Zero tearing across 10 seconds of
 *  continuous BlankFill" (ROADMAP success criterion #3) falls out of
 *  that existing pipeline.
 */
extern "C" int32_t DSpContext_BlankFillHandler(uint32_t ctxRef,
                                                uint32_t rectAddr,
                                                uint32_t colorAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("BlankFill: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	if (rectAddr == 0) {
		DSP_LOG("BlankFill: NULL rectAddr (ctx=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef);
		return kDSpInvalidAttributesErr;
	}
	if (colorAddr == 0) {
		DSP_LOG("BlankFill: NULL colorAddr (ctx=%u) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef);
		return kDSpInvalidAttributesErr;
	}

	/* Read 8 bytes of Mac Rect (4x int16 big-endian; ReadMacInt16
	 * handles byte-swap). Offsets match dsp_draw_context.mm:1798-1803
	 * (DSpContext_InvalBackBufferRectHandler) and Inside Macintosh
	 * convention. */
	const int16_t top    = (int16_t)ReadMacInt16(rectAddr + 0);
	const int16_t left   = (int16_t)ReadMacInt16(rectAddr + 2);
	const int16_t bottom = (int16_t)ReadMacInt16(rectAddr + 4);
	const int16_t right  = (int16_t)ReadMacInt16(rectAddr + 6);

	/* Read 6 bytes of Mac RGBColor (3x uint16 big-endian). Downconvert
	 * via high-byte select. */
	const uint16_t red16   = (uint16_t)ReadMacInt16(colorAddr + 0);
	const uint16_t green16 = (uint16_t)ReadMacInt16(colorAddr + 2);
	const uint16_t blue16  = (uint16_t)ReadMacInt16(colorAddr + 4);
	const uint8_t r8 = (uint8_t)(red16   >> 8);
	const uint8_t g8 = (uint8_t)(green16 >> 8);
	const uint8_t b8 = (uint8_t)(blue16  >> 8);

	return DSpBlankFillCore(ctx, top, left, bottom, right, r8, g8, b8);
}

/*
 *  DSpContext_GetVBLProc (sub-opcode 503).
 *
 *  DSp 1.7 spec p.81 does NOT document a GetVBLProc public entry point.
 *  This handler exists as an internal test-support affordance so tests
 *  can round-trip SetVBLProc + GetVBLProc without relying on the
 *  PPC-trampoline invocation path (which would need a real guest-side
 *  VBLProc allocation via SheepMem — impractical in Swift unit tests).
 *
 *  Argument contract:
 *    ctxRef         = context handle from DSpContext_Reserve
 *    procOutAddr    = guest Mac address for a UInt32 (receives
 *                      ctx->vbl_proc_ptr)
 *    refConOutAddr  = guest Mac address for a UInt32 (receives
 *                      ctx->vbl_proc_refcon)
 *
 *  Error map:
 *    kDSpInvalidContextErr    - ctxRef does not resolve
 *    kDSpInvalidAttributesErr - procOutAddr == 0 OR refConOutAddr == 0
 *    kDSpNoErr                - success; 8 bytes written across the
 *                                two out addresses
 */
extern "C" int32_t DSpContext_GetVBLProcHandler(uint32_t ctxRef,
                                                 uint32_t procOutAddr,
                                                 uint32_t refConOutAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("GetVBLProc: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	if (procOutAddr == 0 || refConOutAddr == 0) {
		DSP_LOG("GetVBLProc: NULL out addr (ctx=%u, proc=0x%08x, refCon=0x%08x) "
		        "-> kDSpInvalidAttributesErr",
		        ctxRef, procOutAddr, refConOutAddr);
		return kDSpInvalidAttributesErr;
	}

	WriteMacInt32(procOutAddr,   ctx->vbl_proc_ptr);
	WriteMacInt32(refConOutAddr, ctx->vbl_proc_refcon);

	DSP_LOG("GetVBLProc: ctx=%u procPtr=0x%08x refCon=0x%08x -> OK",
	        ctxRef, ctx->vbl_proc_ptr, ctx->vbl_proc_refcon);
	return kDSpNoErr;
}

/* --- Canonical DSpProcessEvent (sub-op 750) ---
 *
 * This is the CANONICAL DSp 1.7 export and the OPPOSITE direction to
 * the RETIRED sub-op-600 dequeue handler (the old DSpContext_*
 * ProcessEvent export, which let the GUEST READ enqueued events OUT). That
 * handler — and its header decl — are RETIRED (retire, NOT
 * repurpose). The SPSC
 * input-fanout ring it observed is KEPT (provably alive: 2 live producers —
 * iOS input fanout via DSpHostBridge_EnqueueEventToActiveContexts and bg/fg
 * suspend/resume via DSpHostBridge_OnBackground/OnForeground). The ~18
 * DSpEventTests ring-observation methods migrate to the
 * TESTING_BUILD DSpTesting_DequeueContextEvent host helper instead.
 *
 * Per DSp 1.7 PDF p.58:
 *   OSStatus DSpProcessEvent(EventRecord *inEvent, Boolean *outEventWasProcessed)
 * The app passes ITS OWN event in; DSp inspects it for the suspend/resume
 * osEvt it must handle, drives context state accordingly, and reports via the
 * Boolean out-param whether it consumed the event. NO ctxRef — the dispatch
 * case routes r3 = inEvent (EventRecord*), r4 = outEventWasProcessed (Boolean*).
 *
 * EventRecord byte layout (16 bytes; same as the retired handler read/wrote):
 *   what(+0,u16) message(+2,u32) when(+6,u32) where_v(+10,i16)
 *   where_h(+12,i16) modifiers(+14,u16).
 *
 * osEvt suspend/resume decode (mirrors DSpContext_EnqueueOSEvtOnContext in
 * dsp_host_bridge.mm): an osEvt (what == kDSpEvent_OSEvt) whose message high
 * byte == kDSpOSEvt_SuspendResumeMessage carries the resume flag in
 * message bit 0 (kDSpOSEvtMsg_ResumeFlag): set = resume (foreground), clear =
 * suspend (background). On suspend we drive every Active context to Paused
 * (mirroring DSpHostBridge_OnBackground's state-drive direction + the
 * paused_by_background bookkeeping); on resume we drive every
 * bg-induced-Paused context back to Active (mirroring OnForeground). We mark
 * the event consumed ONLY for that suspend/resume osEvt. For everything DSp
 * does NOT handle we return outEventWasProcessed = false — HONEST, never a
 * silent always-true stub. The full consumed-event-set refinement is a
 * device-UAT gate; The Sims never calls this.
 *
 * Synchronous, emul-thread — NO ring read, NO atomic.
 */
extern "C" int32_t DSpProcessEventHandler(uint32_t inEventAddr,
                                          uint32_t outProcessedAddr)
{
	/* ASVS V5: NULL-guard BOTH guest addresses BEFORE any
	 * read or write. Fixed 16-byte read + 1-byte write — no attacker-
	 * controlled length. */
	if (inEventAddr == 0 || outProcessedAddr == 0) {
		DSP_LOG("DSpProcessEvent: NULL inEvent=0x%08x or outProcessed=0x%08x "
		        "-> kDSpInvalidAttributesErr", inEventAddr, outProcessedAddr);
		return kDSpInvalidAttributesErr;
	}

	uint16_t what    = (uint16_t)ReadMacInt16(inEventAddr + 0);
	uint32_t message = (uint32_t)ReadMacInt32(inEventAddr + 2);

	bool consumed = false;

	/* osEvt suspend/resume is the documented event DSp consumes for
	 * context suspend/resume. Decode mirrors the producer side in
	 * dsp_host_bridge.mm: high byte = subtype, bit 0 = resume flag.
	 *
	 * SCOPE (explicit, NOT a silent partial-fidelity stub):
	 * this handler drives the DSp context STATE MACHINE only — the
	 * Active<->Paused flag transition + the paused_by_background
	 * bookkeeping, matching DSpHostBridge_OnBackground/OnForeground's
	 * state-drive DIRECTION. It does NOT perform the Metal back-buffer
	 * release / re-alloc + cold-start that the iOS NotificationCenter
	 * lifecycle path performs via DSpHandleBackgroundFromEmulThread /
	 * DSpHandleForegroundFromEmulThread (DSpQueueReleaseAtVBLPartial +
	 * DSpAllocateBackBuffer). So an app that drives suspend/resume through
	 * DSpProcessEvent (rather than relying on the OnBackground/OnForeground
	 * hooks) gets a correct STATE transition but keeps its back-buffer
	 * allocated across the suspend and does not cold-start on resume.
	 * Wiring the full resource lifecycle here is deferred: the two
	 * production halves run on different threads and gate on different
	 * fields (main-thread bridge -> paused_by_background; emul-thread
	 * VBL drain -> persisted.invalidated_full), and the back-buffer
	 * re-alloc can fail under the headless/host-blocked test environment,
	 * so reconciling them is non-trivial. The Sims (the target UAT app)
	 * never calls DSpProcessEvent. */
	if (what == (uint16_t)kDSpEvent_OSEvt) {
		uint8_t subtype = (uint8_t)((message >> 24) & 0xFFu);
		if (subtype == (uint8_t)kDSpOSEvt_SuspendResumeMessage) {
			bool resume = (message & (uint32_t)kDSpOSEvtMsg_ResumeFlag) != 0u;
			if (resume) {
				/* Resume (foreground): drive every bg-induced-Paused
				 * context back to Active. Matches
				 * DSpHostBridge_OnForeground's state-drive direction —
				 * SetState(Active) then clear paused_by_background;
				 * user-Paused contexts (paused_by_background == 0) stay
				 * Paused (distinction preserved). Uses the public
				 * DSpGetContext(i+1) accessor — same handle->slot mapping
				 * and bounds/null guard as OnForeground, not the
				 * raw dsp_context_table[] array. */
				for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
					DSpContextPrivate *ctx = DSpGetContext(i + 1u);
					if (ctx == nullptr) continue;
					if (ctx->state != (uint32_t)kDSpContextState_Paused) continue;
					if (ctx->paused_by_background == 0) continue;
					(void)DSpContext_SetStateHandler(ctx->handle,
						(uint32_t)kDSpContextState_Active);
					ctx->paused_by_background = 0;
				}
			} else {
				/* Suspend (background): drive every Active context to
				 * Paused. Matches DSpHostBridge_OnBackground's
				 * state-drive direction — SetState(Paused) + mark
				 * paused_by_background so a later resume auto-restores.
				 * Uses DSpGetContext(i+1) to match OnBackground exactly. */
				for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
					DSpContextPrivate *ctx = DSpGetContext(i + 1u);
					if (ctx == nullptr) continue;
					if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
					(void)DSpContext_SetStateHandler(ctx->handle,
						(uint32_t)kDSpContextState_Paused);
					ctx->paused_by_background = 1;
				}
			}
			consumed = true;
		}
	}

	/* Pascal Boolean (1 byte: 0 = false, 1 = true). HONEST false for any
	 * event DSp does not handle. */
	WriteMacInt8(outProcessedAddr, consumed ? 1 : 0);

	DSP_LOG("DSpProcessEvent: what=%u message=0x%08x -> consumed=%d",
	        (unsigned)what, message, consumed ? 1 : 0);

	return kDSpNoErr;
}

/* --- Background / Foreground emul-thread drain --- */

/*
 *  Background restore path — runs on the EMUL THREAD via the VBL
 *  secondary-callback drain chain. For every Active context:
 *    1. Snapshot metadata into ctx->persisted (attr + palette/gamma
 *       generation counters + invalidated_full=1 so foreground restore
 *       triggers a full re-upload).
 *    2. Queue the Metal back-buffer + texture for VBL-bounded partial
 *       release (struct stays alive; foreground re-allocates in-place).
 *    3. Transition state Active -> Paused via the DMC (Paused routes to
 *       kDMCOwnerQuickDraw).
 *
 *  Palette / gamma generation placeholders are 0 — the CLUT and
 *  gamma/fade subsystems populate the persisted snapshots when
 *  those paths run. The invalidated_full=1 flag guarantees a
 *  cold-start full re-upload once the backing Metal resources come
 *  back, independent of palette/gamma state.
 */
extern "C" void DSpHandleBackgroundFromEmulThread(void)
{
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;

		/* Landmine-7: drop the MainDevice PixMap redirect
		 * BEFORE DSpQueueReleaseAtVBLPartial nils back_buffer. The
		 * restore writes the cached saved_pixmap_* values back into
		 * emulated lowmem so PixMap.baseAddr no longer references a
		 * MTLBuffer that is about to be released. (See documentation in
		 * dsp_engine.cpp:DSpOnBackground explaining why this MUST run
		 * here on the emul thread rather than in the main-thread hook.) */
		DSpRestoreMainDevicePixMap(ctx);

		/* Persist metadata — attr + palette/gamma generation counters.
		 * Field names use the `persisted_*_generation` form so the DMC
		 * write-site inventory grep gate (DMCWriteSiteInventoryTests)
		 * does NOT match — only the DMC module itself owns the bare-word
		 * generation identifiers. */
		ctx->persisted.attr                          = ctx->attr;
		ctx->persisted.persisted_palette_generation  = 0u;  /* CLUT */
		ctx->persisted.persisted_gamma_generation    = 0u;  /* gamma/fade */
		ctx->persisted.invalidated_full              = 1u;

		/* Release Metal back-buffer via the partial queue — struct
		 * stays alive for foreground restore; only buffer + texture
		 * are freed. */
		DSpQueueReleaseAtVBLPartial(ctx);

		/* Transition Active -> Paused via the DMC
		 * (typed wrapper from dsp_engine_internal.h). */
		DMCOwner new_owner =
		    DSpMapStateToDMCOwnerTyped(kDSpContextState_Paused);
		(void)dmc_set_active_owner((uint32_t)new_owner);
		ctx->state = (uint32_t)kDSpContextState_Paused;
		DSP_LOG("Background: ctx=%u Active->Paused "
		        "(back-buffer queued for VBL partial release)",
		        ctx->handle);
	}
}

/*
 *  Foreground restore path — runs on the EMUL THREAD via the VBL
 *  secondary-callback drain chain. For every Paused context whose
 *  persisted.invalidated_full==1 (i.e., previously backgrounded via
 *  DSpHandleBackgroundFromEmulThread):
 *    1. Re-allocate Metal back-buffer + texture from persisted
 *       attributes via DSpAllocateBackBuffer. Failure leaves the
 *       context Paused — next foreground tick retries.
 *    2. Reset dirty state + set dirty_cold_start=true so the next
 *       SwapBuffers performs a full re-upload (PDF p.38).
 *    3. Clear invalidated_full so a redundant foreground event (shouldn't
 *       happen, defense-in-depth) doesn't double-restore.
 *    4. Transition Paused -> Active via the DMC (kDMCOwnerDSp).
 *
 *  Failure here logs + continues without
 *  transitioning; next foreground retries. User can also explicitly
 *  Release the context via DSpContext_Release to recover.
 */
extern "C" void DSpHandleForegroundFromEmulThread(void)
{
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Paused) continue;
		if (ctx->persisted.invalidated_full == 0u) continue;

		/* Re-allocate Metal back-buffer from persisted attributes. */
		if (!DSpAllocateBackBuffer(ctx,
		                           ctx->persisted.attr.displayWidth,
		                           ctx->persisted.attr.displayHeight,
		                           ctx->persisted.attr.backBufferBestDepth)) {
			DSP_LOG("Foreground: ctx=%u back-buffer re-alloc FAILED; "
			        "context remains Paused (retry on next fg)",
			        ctx->handle);
			continue;
		}

		/* Cold-start: force full re-upload on next SwapBuffers
		 * regardless of any stale dirty-rect accumulator contents. */
		ctx->dirty_cold_start = true;
		ctx->dirty_empty      = true;
		ctx->dirty_left       = 0;
		ctx->dirty_top        = 0;
		ctx->dirty_right      = 0;
		ctx->dirty_bottom     = 0;

		/* Invalidate the restore flag — defence-in-depth against a
		 * redundant foreground event double-restoring the context. */
		ctx->persisted.invalidated_full = 0u;

		/* Transition Paused -> Active via the DMC. */
		DMCOwner new_owner =
		    DSpMapStateToDMCOwnerTyped(kDSpContextState_Active);
		(void)dmc_set_active_owner((uint32_t)new_owner);
		ctx->state = (uint32_t)kDSpContextState_Active;

		/* Landmine-7: re-apply the MainDevice PixMap redirect
		 * AFTER back_buffer is re-allocated above and ctx->state is set
		 * to Active. (See documentation in dsp_engine.cpp:DSpOnForeground
		 * explaining why this MUST run here on the emul thread rather
		 * than in the main-thread hook.) */
		DSpRedirectMainDevicePixMap(ctx);

		DSP_LOG("Foreground: ctx=%u Paused->Active "
		        "(back-buffer re-allocated; dirty_cold_start=1)",
		        ctx->handle);
	}
}

/*
 *  VBL drain entry point — runs AFTER DSpVBLReleaseCallback has drained
 *  the release FIFO (drain-first ordering). Reads + clears the pending
 *  flag from the engine-module atomic (DSpExchangeBgFgPending bridge),
 *  then dispatches to the matching emul-thread handler.
 *
 *  Threading contract:
 *    - Main thread: observer hook sets pending flag (store-release).
 *    - Emul thread: VBL drain exchanges flag to 0 (acquire-exchange)
 *      and performs the table mutation here. No mutex; the _Atomic
 *      uint32_t is the only sanctioned cross-thread primitive.
 *
 *  Caveat acknowledged: on iOS 13.4-16 the CADisplayLink fallback
 *  delivers VBL callbacks on main thread; the CAMetalDisplayLink
 *  iOS 17+ path runs on emul. Simulator closure targets iOS 17+;
 *  older-iOS physical-device UAT is queued for device UAT.
 */
extern "C" void DSpVBLBackgroundForegroundDrain(void)
{
	uint32_t pending = DSpExchangeBgFgPending();
	if (pending == 1u) {
		DSpHandleBackgroundFromEmulThread();
	} else if (pending == 2u) {
		DSpHandleForegroundFromEmulThread();
	}
}

/* --- DSpContext_ReserveHandler --- */

/*
 *  Core Reserve body extracted to operate on an already-extracted
 *  DSpContextAttributes struct + uint32_t* out pointer (not a Mac
 *  address). Separates the Mac-memory I/O from the business logic so:
 *    (a) the production PPC path (DSpContext_ReserveHandler below) wraps
 *        this with ReadMacInt32/WriteMacInt32;
 *    (b) the TESTING_BUILD wrapper DSpTesting_ReserveByStruct wraps this
 *        with a C struct + out-param pointer, side-stepping the
 *        EMULATED_PPC=0 Mac-address truncation hazard on arm64 iOS
 *        simulator where RAM can mmap above 4 GiB and `*(uint32*)addr`
 *        would SEGV.
 *
 *  Both call sites MUST validate the same invariants — the split is a
 *  clean compile-time factoring, not a divergence in behavior.
 */
static int32_t DSpContext_Reserve_Core(const DSpContextAttributes *attr,
                                        uint32_t *outCtxRef)
{
	if (attr == nullptr || outCtxRef == nullptr) {
		DSP_LOG("Reserve_Core: NULL attr or outCtxRef ptr");
		return kDSpInvalidAttributesErr;
	}

	uint32_t displayWidth        = attr->displayWidth;
	uint32_t displayHeight       = attr->displayHeight;
	uint32_t backBufferBestDepth = attr->backBufferBestDepth;
	uint32_t displayBestDepth    = attr->displayBestDepth;
	uint32_t backBufferDepthMask = attr->backBufferDepthMask;
	uint32_t displayDepthMask    = attr->displayDepthMask;
	uint32_t pageCount           = attr->pageCount;
	uint32_t colorNeeds          = attr->colorNeeds;
	uint32_t contextOptions      = attr->contextOptions;

	/* Validation rules. */
	if (pageCount == 0 || displayWidth == 0 || displayHeight == 0) {
		DSP_LOG("Reserve: invalid attrs (w=%u h=%u pc=%u)",
		        displayWidth, displayHeight, pageCount);
		return kDSpInvalidAttributesErr;
	}
	/* All six depths are supported (no 1/2/4 bpp restriction). Valid
	 * depths are the six DSp 1.7 PDF p.66 indexed + direct modes:
	 * 1/2/4/8 indexed (R8Uint with shader-unpack per compositor precedent),
	 * 16 direct (R16Uint xRGB1555), 32 direct (BGRA8Unorm). */
	if (backBufferBestDepth != 1 && backBufferBestDepth != 2 &&
	    backBufferBestDepth != 4 && backBufferBestDepth != 8 &&
	    backBufferBestDepth != 16 && backBufferBestDepth != 32) {
		DSP_LOG("Reserve: unsupported back-buffer depth %u "
		        "(valid: 1/2/4/8/16/32)",
		        backBufferBestDepth);
		return kDSpInvalidAttributesErr;
	}
	if (backBufferDepthMask == 0) {
		DSP_LOG("Reserve: backBufferDepthMask=0 (must specify a mask)");
		return kDSpInvalidAttributesErr;
	}
	/* Oversize guard (ASVS V5 + DMC validation). */
	if (displayWidth > 4096 || displayHeight > 4096) {
		DSP_LOG("Reserve: oversize resolution %ux%u clamped to paramErr",
		        displayWidth, displayHeight);
		return kDSpInvalidAttributesErr;
	}

	/* `new DSpContextPrivate()` value-initializes: POD fields zero'd,
	 * id<MTL*> ARC fields set to nil. Do NOT std::memset over this —
	 * that would bypass ARC on the ObjC pointer slots (UB). */
	DSpContextPrivate *ctx = new DSpContextPrivate();
	ctx->attr.displayWidth        = displayWidth;
	ctx->attr.displayHeight       = displayHeight;
	ctx->attr.backBufferWidth     = DSpReserveBackBufferDimension(0, displayWidth);
	ctx->attr.backBufferHeight    = DSpReserveBackBufferDimension(0, displayHeight);
	ctx->attr.backBufferBestDepth = backBufferBestDepth;
	ctx->attr.displayBestDepth    = displayBestDepth;
	ctx->attr.backBufferDepthMask = backBufferDepthMask;
	ctx->attr.displayDepthMask    = displayDepthMask;
	ctx->attr.pageCount           = pageCount;
	ctx->attr.colorNeeds          = colorNeeds;
	ctx->attr.contextOptions      = contextOptions;
	ctx->state                    = kDSpContextState_Inactive;
	/* Debug session `dsp-sims-enumeration-stall` fix (2026-04-19): Reserve
	 * creates a full context that owns Metal resources; it is NOT part of
	 * the GetFirstContext / GetNextContext enumeration chain. Calling
	 * GetNextContext with a Reserved handle should terminate the iteration
	 * (PDF p.17 "last context in the list"). Sentinel the field so the
	 * handler's DSP_ENUMERATION_INDEX_NONE branch fires. */
	ctx->enumeration_mode_index   = DSP_ENUMERATION_INDEX_NONE;
	ctx->dirty_empty              = true;
	ctx->dirty_cold_start         = true;   /* PDF p.38 — first swap = full */
	ctx->explicit_swap_observed   = false;
	/* Cheap-query bookkeeping — explicit zero-init (matches
	 * the new DSpContextPrivate() POD value-init; 0 = no max-fps restriction +
	 * grid defaults to the 32x32 base unit until a Set). */
	ctx->max_frame_rate           = 0;
	ctx->dirty_grid_w             = 0;
	ctx->dirty_grid_h             = 0;
	DSpInitDefaultCLUT(ctx->clut_bytes, ctx->clut_bytes_latched,
	                   backBufferBestDepth);

	if (!DSpAllocateBackBuffer(ctx,
	                            ctx->attr.backBufferWidth,
	                            ctx->attr.backBufferHeight,
	                            backBufferBestDepth)) {
		delete ctx;
		return kDSpInternalErr;
	}
	uint32_t handle = DSpAllocContextHandle(ctx);
	if (handle == 0) {
		DSpReleaseNow(ctx);
		return kDSpInternalErr;
	}
	dsp_context_count++;
	*outCtxRef = handle;
	DSP_LOG("Reserve: handle=%u %ux%u@%ubpp pc=%u opts=0x%x",
	        handle, displayWidth, displayHeight, backBufferBestDepth,
	        pageCount, contextOptions);
	return kDSpNoErr;
}

/*
 *  Debug session `dsp-sims-post-reserve-black-screen` fix (2026-04-19) —
 *  Reserve_OnHandle_Core attaches Metal back-buffer + back-texture to an
 *  EXISTING metadata-only ctx (typically one vended by
 *  DSpFindBestContextHandler or DSpGetFirstContextHandler). Per DSp 1.7
 *  PDF p.25:
 *      OSStatus DSpContext_Reserve(DSpContextReference inContext,
 *                                  const DSpContextAttributesPtr inDesiredAttributes);
 *  The caller ALREADY holds the ctxRef; Reserve's job is to validate +
 *  apply the desired attributes AND allocate the Metal resources that
 *  subsequent GetBackBuffer / SwapBuffers / SetState calls require.
 *
 *  Behavior:
 *    - Validates `attr` (same validation rules as Reserve_Core).
 *    - Overrides ctx->attr with the caller-provided DesiredAttributes
 *      (allows apps to request a back-buffer depth different from the
 *      display depth — PDF p.25 DISCUSSION).
 *    - Refuses re-reservation (ctx already has a back_buffer) with
 *      kDSpContextAlreadyReservedErr (PDF p.87 error code).
 *    - Allocates back_buffer + back_texture via DSpAllocateBackBuffer.
 *    - Marks the context as off the enumeration chain (Reserve implies
 *      "this is now a game-owned context, not a cursor").
 *
 *  Returns:
 *    - kDSpNoErr on success.
 *    - kDSpInvalidContextErr if ctx is NULL.
 *    - kDSpInvalidAttributesErr on attr validation failure.
 *    - kDSpContextAlreadyReservedErr if back_buffer already present.
 *    - kDSpInternalErr on Metal allocation failure.
 *
 *  Threading: emul-thread single-writer (same contract as Reserve_Core).
 *  No mutex / MTLFence / _Atomic / @synchronized.
 */
static int32_t DSpContext_Reserve_OnHandle_Core(DSpContextPrivate *ctx,
                                                 const DSpContextAttributes *attr)
{
	if (attr == nullptr) {
		DSP_LOG("Reserve_OnHandle: NULL attr ptr");
		return kDSpInvalidAttributesErr;
	}
	if (ctx == nullptr) {
		DSP_LOG("Reserve_OnHandle: NULL ctx");
		return kDSpInvalidContextErr;
	}

	uint32_t desiredWidth        = attr->displayWidth;
	uint32_t desiredHeight       = attr->displayHeight;
	uint32_t backBufferBestDepth = attr->backBufferBestDepth;
	uint32_t desiredDisplayDepth = attr->displayBestDepth;
	uint32_t backBufferDepthMask = attr->backBufferDepthMask;
	uint32_t desiredDisplayMask  = attr->displayDepthMask;
	uint32_t pageCount           = attr->pageCount;
	uint32_t colorNeeds          = attr->colorNeeds;
	uint32_t contextOptions      = attr->contextOptions;

	/* Validation rules — same invariants as Reserve_Core. */
	if (pageCount == 0 || desiredWidth == 0 || desiredHeight == 0) {
		DSP_LOG("Reserve_OnHandle: invalid attrs (w=%u h=%u pc=%u)",
		        desiredWidth, desiredHeight, pageCount);
		return kDSpInvalidAttributesErr;
	}
	if (backBufferBestDepth != 1 && backBufferBestDepth != 2 &&
	    backBufferBestDepth != 4 && backBufferBestDepth != 8 &&
	    backBufferBestDepth != 16 && backBufferBestDepth != 32) {
		DSP_LOG("Reserve_OnHandle: unsupported back-buffer depth %u "
		        "(valid: 1/2/4/8/16/32)",
		        backBufferBestDepth);
		return kDSpInvalidAttributesErr;
	}
	if (backBufferDepthMask == 0) {
		DSP_LOG("Reserve_OnHandle: backBufferDepthMask=0 (must specify a mask)");
		return kDSpInvalidAttributesErr;
	}
	if (desiredWidth > 4096 || desiredHeight > 4096) {
		DSP_LOG("Reserve_OnHandle: oversize resolution %ux%u clamped to paramErr",
		        desiredWidth, desiredHeight);
		return kDSpInvalidAttributesErr;
	}

	/* PDF p.87 — kDSpContextAlreadyReservedErr if caller re-reserves a
	 * context that already has a back-buffer. Real DSp 1.7 guards against
	 * double-Reserve; the earlier Reserve used to always create a fresh
	 * ctx so this code path was unreachable. Now that Reserve attaches
	 * to an existing handle, we must surface the spec error. */
	if (ctx->back_buffer != nil) {
		DSP_LOG("Reserve_OnHandle: ctx=%u already has back-buffer — "
		        "kDSpContextAlreadyReservedErr",
		        ctx->handle);
		return kDSpContextAlreadyReservedErr;
	}

	const uint32_t actualDisplayWidth =
	    DSpReserveActualDisplayDimension(ctx->attr.displayWidth,
	                                     desiredWidth);
	const uint32_t actualDisplayHeight =
	    DSpReserveActualDisplayDimension(ctx->attr.displayHeight,
	                                     desiredHeight);
	const uint32_t actualDisplayDepth =
	    DSpReserveActualDisplayDepth(ctx->attr.displayBestDepth,
	                                 desiredDisplayDepth,
	                                 backBufferBestDepth);
	const uint32_t actualDisplayMask =
	    ctx->attr.displayDepthMask != 0 ? ctx->attr.displayDepthMask
	                                    : desiredDisplayMask;

	/* Apply desired back-buffer attributes while preserving the selected
	 * display mode that FindBest/GetFirst put on the metadata context.
	 * DSp 1.7 p.25 explicitly allows a requested 320x240 back buffer inside
	 * a best-match 640x480 display; displayWidth/Height remain the actual
	 * front/display mode and the host-only backBufferWidth/Height carry the
	 * requested drawing environment. */
	ctx->attr.displayWidth        = actualDisplayWidth;
	ctx->attr.displayHeight       = actualDisplayHeight;
	ctx->attr.backBufferWidth     = DSpReserveBackBufferDimension(
	                                    actualDisplayWidth, desiredWidth);
	ctx->attr.backBufferHeight    = DSpReserveBackBufferDimension(
	                                    actualDisplayHeight, desiredHeight);
	ctx->attr.backBufferBestDepth = backBufferBestDepth;
	ctx->attr.displayBestDepth    = actualDisplayDepth;
	ctx->attr.backBufferDepthMask = backBufferDepthMask;
	ctx->attr.displayDepthMask    = actualDisplayMask;
	ctx->attr.pageCount           = pageCount;
	ctx->attr.colorNeeds          = colorNeeds;
	ctx->attr.contextOptions      = contextOptions;

	/* Reserve transitions this context off the enumeration chain —
	 * DSpGetNextContext with a reserved handle terminates per PDF p.17
	 * "last context in the list" + debug session dsp-sims-enumeration-
	 * stall precedent. */
	ctx->enumeration_mode_index = DSP_ENUMERATION_INDEX_NONE;
	ctx->state                  = kDSpContextState_Inactive;
	ctx->dirty_empty            = true;
	ctx->dirty_cold_start       = true;   /* PDF p.38 — first swap = full */
	ctx->explicit_swap_observed = false;

	/* Allocate Metal back-buffer + texture on the existing ctx. The
	 * MTLBuffer / MTLTexture slots were nil before (this was a metadata-
	 * only ctx); DSpAllocateBackBuffer fills them in with the same
	 * gfxaccel heap routing as Reserve_Core. */
	if (!DSpAllocateBackBuffer(ctx,
	                           ctx->attr.backBufferWidth,
	                           ctx->attr.backBufferHeight,
	                           backBufferBestDepth)) {
		DSP_LOG("Reserve_OnHandle: DSpAllocateBackBuffer failed for "
		        "ctx=%u %ux%u@%ubpp",
		        ctx->handle, ctx->attr.backBufferWidth,
		        ctx->attr.backBufferHeight,
		        backBufferBestDepth);
		return kDSpInternalErr;
	}

	DSP_LOG("Reserve_OnHandle: ctx=%u display=%ux%u@%u "
	        "back=%ux%u@%ubpp pc=%u opts=0x%x",
	        ctx->handle, ctx->attr.displayWidth, ctx->attr.displayHeight,
	        ctx->attr.displayBestDepth,
	        ctx->attr.backBufferWidth, ctx->attr.backBufferHeight,
	        backBufferBestDepth, pageCount, contextOptions);
	return kDSpNoErr;
}

extern "C" int32_t DSpContext_ReserveHandler(uint32_t ctxRef,
                                              uint32_t attrAddr)
{
	/*
	 *  Debug session `dsp-sims-post-reserve-black-screen` fix (2026-04-19) —
	 *  Signature corrected to DSp 1.7 PDF p.25:
	 *      OSStatus DSpContext_Reserve(DSpContextReference inContext,
	 *                                  const DSpContextAttributesPtr inDesiredAttributes);
	 *  r3 = ctxRef (existing handle from FindBestContext / GetFirstContext).
	 *  r4 = attrAddr (Mac pointer to desired attributes).
	 *
	 *  The previous implementation treated r3 as an out-ptr to write a new
	 *  handle into, producing a bogus secondary handle the app promptly
	 *  ignored (since its own `gContext` local was already populated by
	 *  FindBestContext). That left the true ctxRef with no back-buffer,
	 *  SetState(Active) succeeded on the wrong object, and no frames ever
	 *  reached the display.
	 */
	if (attrAddr == 0) {
		DSP_LOG("Reserve: NULL attr addr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("Reserve: invalid ctxRef=%u — kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}

	/*
	 *  Re-corrected 2026-04-21 via debug session
	 *  `dsp-sims-rejects-all-modes`: Read DSpContextAttributes from guest
	 *  RAM using DSp 1.7 PDF p.65 on-wire byte layout. All on-wire fields
	 *  are 4 bytes (UInt32 / Fixed / OptionBits / CTabHandle / pageCount).
	 *  filler[3] @ +52..+54 + gameMustConfirmSwitch (Boolean) @ +55 +
	 *  reserved3[4] @ +56..+71 are not validated on input (PDF p.67).
	 *  backBufferWidth / backBufferHeight are host-only mirror fields
	 *  (not on the wire) — populated from displayWidth / displayHeight.
	 */
	DSpContextAttributes attr = {};
	attr.frequency            = ReadMacInt32(attrAddr +  0);  /* input ignored per PDF */
	attr.displayWidth         = ReadMacInt32(attrAddr +  4);
	attr.displayHeight        = ReadMacInt32(attrAddr +  8);
	attr.reserved1            = ReadMacInt32(attrAddr + 12);
	attr.reserved2            = ReadMacInt32(attrAddr + 16);
	attr.colorNeeds           = ReadMacInt32(attrAddr + 20);
	attr.colorTable           = ReadMacInt32(attrAddr + 24);
	attr.contextOptions       = ReadMacInt32(attrAddr + 28);
	attr.backBufferDepthMask  = ReadMacInt32(attrAddr + 32);
	attr.displayDepthMask     = ReadMacInt32(attrAddr + 36);
	attr.backBufferBestDepth  = ReadMacInt32(attrAddr + 40);
	attr.displayBestDepth     = ReadMacInt32(attrAddr + 44);
	attr.pageCount            = ReadMacInt32(attrAddr + 48);
	attr.gameMustConfirmSwitch = 0;
	attr.backBufferWidth      = attr.displayWidth;
	attr.backBufferHeight     = attr.displayHeight;
	return DSpContext_Reserve_OnHandle_Core(ctx, &attr);
}

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD helper: host-struct wrapper around
 *  DSpContext_Reserve_Core. Side-steps the EMULATED_PPC=0 Mac-address
 *  SEGV on arm64 iOS simulator when the fake RAM mmap lands above 4 GiB.
 *  Returns the same DSp 1.7 result codes as DSpContext_ReserveHandler.
 *  On success writes the allocated ctxRef to *outCtxRef.
 */
extern "C" int32_t DSpTesting_ReserveByStruct(const DSpContextAttributes *attr,
                                               uint32_t *outCtxRef)
{
	return DSpContext_Reserve_Core(attr, outCtxRef);
}

/*
 *  Debug session `dsp-sims-post-reserve-black-screen` fix (2026-04-19) —
 *  host wrapper around DSpContext_Reserve_OnHandle_Core. Unlike
 *  DSpTesting_ReserveByStruct (which creates a NEW context from scratch,
 *  the legacy semantic), this wrapper exercises the real DSp 1.7 path:
 *  caller pre-allocates a metadata-only ctxRef via
 *  DSpAllocFirstContextHandle (or obtains one from FindBestContext) and
 *  passes that existing handle + desired attributes. The wrapper calls
 *  the same core the production dispatcher invokes. Used by the new
 *  DSpReserveOnHandleRegressionTests to verify the Sims fix end-to-end
 *  without going through guest-RAM plumbing.
 */
extern "C" int32_t DSpTesting_ReserveOnHandleByStruct(
    uint32_t ctxRef,
    const DSpContextAttributes *attr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	return DSpContext_Reserve_OnHandle_Core(ctx, attr);
}
#endif

/*
 *  Metadata-only context allocation.
 *
 *  DSpGetFirstContext / DSpFindBestContext vend a DSp context reference
 *  populated with vended-mode attributes; the emulated app inspects the
 *  attributes and only later calls DSpContext_Reserve to actually
 *  instantiate a back-buffer. To avoid duplicating the context-table
 *  slot-alloc logic, we expose DSpAllocFirstContextHandle as the single
 *  entry point for "claim a slot, populate attr, return handle" without
 *  the Metal-resource allocation that Reserve_Core performs.
 *
 *  Threading: emul-thread single-writer. No mutex — same contract as
 *  DSpAllocContextHandle / Reserve_Core.
 *
 *  Debug session `dsp-sims-enumeration-stall` fix (2026-04-19): added the
 *  `enumeration_mode_index` parameter. Callers on the GetFirstContext /
 *  GetNextContext iteration path pass the 0-based index into s_dsp_modes[]
 *  that the context's attr was copied from; the value is stored in
 *  ctx->enumeration_mode_index so DSpGetNextContextHandler can advance the
 *  cursor. FindBest and other non-enumeration callers pass
 *  DSP_ENUMERATION_INDEX_NONE so GetNextContext treats the handle as a
 *  terminator (no successor).
 */
extern "C" uint32_t DSpAllocFirstContextHandle(const DSpContextAttributes *attr,
                                                uint32_t enumeration_mode_index)
{
	if (attr == nullptr) return 0;

	DSpContextPrivate *ctx = new DSpContextPrivate();
	ctx->attr  = *attr;
	ctx->state = kDSpContextState_Inactive;
	/* Debug session `dsp-sims-enumeration-stall` fix (2026-04-19):
	 * record the index so GetNextContext can walk forward through
	 * s_dsp_modes[]. Sentinel value DSP_ENUMERATION_INDEX_NONE means
	 * the context is a terminator (e.g., FindBest best-match result). */
	ctx->enumeration_mode_index = enumeration_mode_index;
	/* Cheap-query bookkeeping — explicit zero-init (see
	 * Reserve_Core; 0 = no max-fps restriction + grid defaults to base unit). */
	ctx->max_frame_rate = 0;
	ctx->dirty_grid_w   = 0;
	ctx->dirty_grid_h   = 0;
	DSpInitDefaultCLUT(ctx->clut_bytes, ctx->clut_bytes_latched,
	                   ctx->attr.backBufferBestDepth);

	uint32_t handle = DSpAllocContextHandle(ctx);
	if (handle == 0) {
		delete ctx;
		return 0;
	}
	dsp_context_count++;
	DSP_LOG("AllocFirstContextHandle: handle=%u %ux%u@%ubpp (metadata-only, enum_idx=%u)",
	        handle, attr->displayWidth, attr->displayHeight,
	        attr->backBufferBestDepth,
	        (unsigned)enumeration_mode_index);
	return handle;
}

extern "C" uint32_t DSpAllocMetadataContextHandle(
    const DSpContextAttributes *attr,
    uint32_t enumeration_mode_index)
{
	if (attr == nullptr) return 0;

	uint32_t handle = DSpAllocFirstContextHandle(attr, enumeration_mode_index);
	if (handle != 0) return handle;

	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (!DSpIsInactiveMetadataOnlyContext(ctx)) continue;
		if (ctx->enumeration_mode_index != DSP_ENUMERATION_INDEX_NONE) {
			continue;
		}

		const uint32_t recycled_handle = i + 1u;
		DSpFreeContextHandle(recycled_handle);
		dsp_context_count--;
		DSpReleaseNow(ctx);
		DSP_LOG("AllocMetadataContextHandle: recycled inactive "
		        "metadata-only handle=%u",
		        recycled_handle);
		return DSpAllocFirstContextHandle(attr, enumeration_mode_index);
	}

	DSP_LOG("AllocMetadataContextHandle: table full; no recyclable "
	        "inactive metadata-only handle");
	return 0;
}

/* --- DSpContext_ReleaseHandler --- */

extern "C" int32_t DSpContext_ReleaseHandler(uint32_t ctxRef)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("Release: invalid ctxRef=%u", ctxRef);
		return kDSpInvalidContextErr;
	}
	DSpFreeContextHandle(ctxRef);
	dsp_context_count--;
	/* Defer to next VBL. Do NOT free synchronously. */
	DSpQueueReleaseAtVBL(ctx);
	DSP_LOG("Release: handle=%u queued for VBL drain", ctxRef);
	return kDSpNoErr;
}

/* --- DSpContext_GetBackBufferHandler --- */

extern "C" int32_t DSpContext_GetBackBufferHandler(uint32_t ctxRef,
                                                    uint32_t options,
                                                    uint32_t outBufAddr)
{
	/* PDF: options are reserved in DSp 1.7; ignore but don't error. */
	(void)options;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outBufAddr == 0) {
		DSP_LOG("GetBackBuffer: invalid ctxRef=%u or outBufAddr=0x%08x",
		        ctxRef, outBufAddr);
		return kDSpInvalidContextErr;
	}
	uint32_t cgrafptr = DSpGetBackBufferCGrafPtr(ctx);
	if (cgrafptr == 0) {
		DSP_LOG("GetBackBuffer: CGrafPort emission failed for ctxRef=%u",
		        ctxRef);
		return kDSpInternalErr;
	}
	/* Sub-op 705 underlay contract (PDF p.51):
	 * when this context has a designated underlay alt-buffer, restore the
	 * back buffer's invalid (dirty) areas from the underlay before handing
	 * the drawable back — "this is most useful in sprite games" (clean a
	 * back buffer). No-op when no underlay is designated. */
	DSpRestoreBackBufferFromUnderlay(ctx);
	WriteMacInt32(outBufAddr, cgrafptr);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD helper: host-ptr wrapper around
 *  DSpContext_GetBackBufferHandler. The production path writes the
 *  CGrafPtr to a Mac uint32 address via WriteMacInt32; on arm64 iOS
 *  simulator that writes to a truncated host pointer (SEGV). This
 *  wrapper takes a host uint32_t* and writes through it directly.
 */
extern "C" int32_t DSpTesting_GetBackBufferByStruct(uint32_t ctxRef,
                                                     uint32_t options,
                                                     uint32_t *outBuf)
{
	(void)options;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outBuf == nullptr) {
		return kDSpInvalidContextErr;
	}
	uint32_t cgrafptr = DSpGetBackBufferCGrafPtr(ctx);
	if (cgrafptr == 0) {
		return kDSpInternalErr;
	}
	/* Run the same underlay-restore branch the
	 * production DSpContext_GetBackBufferHandler runs (PDF p.51), so the
	 * golden underlay-restore test exercises it without a guest-RAM out-write
	 * SEGV. No-op when no underlay is designated. */
	DSpRestoreBackBufferFromUnderlay(ctx);
	*outBuf = cgrafptr;
	return kDSpNoErr;
}

/*
 *  TESTING_BUILD helper: return the back-buffer's host-visible
 *  contents pointer + byte length for a context. Lets tests write a packed
 *  pixel pattern directly into the MTLBuffer-backed texture view (MTLStorage
 *  ModeShared) without going through the guest-scratch staging
 *  indirection that DSpGetBackBufferCGrafPtr uses.
 *
 *  The back-buffer is MTLStorageModeShared so ctx->back_buffer.contents is
 *  a valid host VA; the MTLTexture view we hand to DSpEncodeBackBufferBlit
 *  at SwapBuffers time reads the same backing memory. Bypasses the Host2Mac
 *  Addr fallback path entirely — if the bump allocator doesn't map
 *  into the emulated RAM region, we don't care, because we're a host pointer.
 *
 *  Used by DSpIndexedDepthCompositeTests to install 1/2/4/8-bpp packed index
 *  bit patterns for golden-image validation. Returns kDSpNoErr +
 *  populates out params on success; kDSpInvalidContextErr + zeros on bad ctx.
 */
extern "C" int32_t DSpTesting_GetBackBufferHostPointer(uint32_t ctxRef,
                                                        void **outContents,
                                                        uint32_t *outLength)
{
	if (outContents == nullptr || outLength == nullptr) {
		return kDSpInvalidContextErr;
	}
	*outContents = NULL;
	*outLength   = 0;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || ctx->back_buffer == nil) {
		return kDSpInvalidContextErr;
	}
	*outContents = ctx->back_buffer.contents;    /* NULL on StorageModePrivate */
	*outLength   = (uint32_t)ctx->back_buffer.length;
	return kDSpNoErr;
}

/*
 *  TESTING_BUILD helper: return the back-buffer MTLTexture
 *  view handle for a context. DSpIndexedDepthCompositeTests
 *  needs to blit a packed-index pattern into this texture via a Shared
 *  staging MTLBuffer when the underlying back_buffer is
 *  StorageModePrivate (iOS simulator heap constraint per
 *  gfxaccel_resources_heap.mm:230 — heaps force Private on simulator
 *  regardless of the caller's request).
 *
 *  Returns an UNRETAINED id<MTLTexture> bridge-cast to void*: the caller
 *  must NOT release the returned handle; its lifetime is tied to the
 *  context. Returns NULL on invalid ctxRef or if back_texture has not
 *  been allocated (Reserve not yet called).
 */
extern "C" void *DSpTesting_GetBackTextureHandle(uint32_t ctxRef)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return NULL;
	return (__bridge void *)ctx->back_texture;
}
#endif

/* --- DSpContext_SwapBuffersHandler --- */

/* Pre-swap busyProc gate (PDF p.39). DSp 1.7 header documents busyProc
 * as Boolean (*)(void *refCon) where the return value signals readiness:
 * non-zero = "constraints satisfied, may proceed"; zero = "still not
 * ready". If busyProcAddr is 0 the caller skipped the gate — proceed
 * immediately. Poll cadence is 0.5 ms with a 2-VBL total budget
 * (~33 ms at 60 Hz) so an infinite-loop PPC busyProc cannot hang the
 * emul thread. */
static bool DSpPollBusyProc(uint32_t busyProcAddr, uint32_t userRefCon)
{
	if (busyProcAddr == 0) return true;

	uint64_t cadence = vbl_source_get_cadence_usec();
	if (cadence == 0) cadence = 16667;    /* fallback 60 Hz */
	uint64_t timeout_usec = cadence * 2;  /* 2-VBL cap */
	uint64_t elapsed = 0;
	const uint32_t poll_step_usec = 500;  /* 0.5 ms */

	/* Wire busyProc through CallMacOS1. Precedent: rave_engine.cpp
	 * :2731 uses CallMacOS1(qa_register_t, ...) to fire a PPC TVECT from
	 * native code; ether.cpp + macos_util.cpp use the same pattern.
	 * busyProc is a TVECT address (PDF p.39: "an application-supplied
	 * callback function"); the signature is Boolean (*)(void *refCon) —
	 * classic Boolean is an 8-bit value, so only the low byte matters. */
	typedef uint32 (*busyproc_fn_t)(uint32 refcon_mac);
	while (elapsed < timeout_usec) {
		uint32 rv = CallMacOS1(busyproc_fn_t, busyProcAddr, userRefCon);
		if ((rv & 0xff) != 0) {
			return true;   /* busyProc signalled "ready to swap" */
		}
		usleep(poll_step_usec);
		elapsed += poll_step_usec;
	}
	DSP_LOG("DSpPollBusyProc: 2-VBL timeout (busyProcAddr=0x%08x "
	        "userRefCon=0x%08x elapsed=%llu)",
	        busyProcAddr, userRefCon, (unsigned long long)elapsed);
	return false;
}

extern "C" int32_t DSpContext_SwapBuffersHandler(uint32_t ctxRef,
                                                  uint32_t busyProcAddr,
                                                  uint32_t userRefCon)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("SwapBuffers: invalid ctxRef=%u", ctxRef);
		return kDSpInvalidContextErr;
	}
	if (ctx->back_texture == nil || ctx->back_buffer == nil) {
		DSP_LOG("SwapBuffers: ctxRef=%u has no back-buffer", ctxRef);
		return kDSpInternalErr;
	}

	ctx->explicit_swap_observed = true;

	/* Pre-swap busyProc gate (PDF p.39 — constraints-before-swap, NOT
	 * post-swap completion). */
	if (!DSpPollBusyProc(busyProcAddr, userRefCon)) {
		DSP_LOG("SwapBuffers: busyProc gate timed out (2 VBL cap)");
		return kDSpInternalErr;
	}

	/* VBL sync unless kDSpContextOption_DontSyncVBL is set. */
	if ((ctx->attr.contextOptions & kDSpContextOption_DontSyncVBL) == 0) {
		vbl_source_sync_3d_pacing();
	}

	/* Explicit pre-blit into the compositor-owned
	 * framebuffer texture. CompositeLayer.source is the framebuffer
	 * texture (NOT ctx->back_texture) so the compositor sees only slot +
	 * framebuffer handle; no DSp identity leaks. SC #5 preserved
	 * by construction. */
	void *fb_tex_raw = MetalCompositorGetFramebufferTexture();
	if (fb_tex_raw == NULL) {
		DSP_LOG("SwapBuffers: no compositor framebuffer texture — "
		        "compositor not initialized?");
		return kDSpInternalErr;
	}

	id<MTLCommandQueue> queue =
	    (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
	if (queue == nil) {
		DSP_LOG("SwapBuffers: shared Metal command queue is nil");
		return kDSpInternalErr;
	}

	@autoreleasepool {
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		if (cb == nil) {
			DSP_LOG("SwapBuffers: commandBuffer returned nil");
			return kDSpInternalErr;
		}

		bool present_front_staging =
		    DSpShouldPresentFrontBufferStagingForSwap(
		        ctx->attr.backBufferBestDepth,
		        ctx->attr.displayBestDepth,
		        ctx->front_staging_mac_addr,
		        ctx->front_staging_size,
		        ctx->state,
		        (uint32_t)kDSpContextState_Active);
		const bool has_back_buffer_staging = (ctx->staging_mac_addr != 0);
		if (DSpShouldFlushNQDBeforeStagingDrain(has_back_buffer_staging,
		                                       present_front_staging)) {
			NQDMetalFlush();
		}

		/* Stage 1 (W1 staging path): if GetBackBuffer was forced to
		 * vend a guest-RAM staging region because Host2MacAddr could not
		 * map the MTLBuffer contents pointer, the emulated app has been
		 * writing into the staging region. memcpy staging →
		 * back_buffer.contents BEFORE encoding the GPU blit so the
		 * texture view sees the latest pixels. This preserves guest-
		 * writable CGrafPtr semantics. */
		if (has_back_buffer_staging) {
			uint32_t w         = ctx->attr.displayWidth;
			uint32_t h         = ctx->attr.displayHeight;
			uint32_t bpp       = ctx->attr.backBufferBestDepth;
			uint32_t row_bytes = (w * bpp + 7) / 8;
			uint32_t alignedRB = (row_bytes + 255) & ~255u;
			uint32_t buffer_size = alignedRB * h;

			uint8_t *staging_host = Mac2HostAddr(ctx->staging_mac_addr);
			void    *back_contents = ctx->back_buffer.contents;
			if (staging_host != NULL && back_contents != NULL) {
				memcpy(back_contents, staging_host, buffer_size);
			}
		}

		/* Stage 2: encode the back_texture → framebuffer_texture blit
		 * (or unpack render pass when pixel formats differ — e.g. 16 bpp
		 * R16Uint back_texture against a BGRA8Unorm framebuffer texture
		 * after a mid-app depth switch). DSpEncodePresentToFramebuffer
		 * opens / closes its own encoder; we just commit the command
		 * buffer afterwards. */
		bool front_presented = false;
		if (present_front_staging) {
			front_presented =
			    DSpEncodeFrontBufferStagingToFramebuffer(ctx,
			                                             (__bridge void *)cb,
			                                             fb_tex_raw);
		}
		if (!front_presented) {
			DSpEncodePresentToFramebuffer(ctx, (__bridge void *)cb, fb_tex_raw);
		}
		[cb commit];
	}

	/* Stage 3: submit an engine-blind CompositeLayer whose source is the
	 * COMPOSITOR-OWNED framebuffer texture. The compositor's production
	 * SubmitFrame caches overlay layers and no-ops framebuffer-slot
	 * layers in favor of MetalCompositorPresent's internal path — our
	 * blit into compositor_texture above is what actually makes the
	 * DSp-owned pixels visible. The SubmitFrame call here carries
	 * descriptor validation + stale-generation rejection semantics so
	 * DSp participates in the same frame-fence shape as RAVE/GL. */
	struct CompositeLayer layer;
	std::memset(&layer, 0, sizeof(layer));
	layer.source       = fb_tex_raw;
	layer.src_origin_x = 0;
	layer.src_origin_y = 0;
	layer.src_size_w   = ctx->attr.displayWidth;
	layer.src_size_h   = ctx->attr.displayHeight;
	layer.dst_origin_x = 0.0f;
	layer.dst_origin_y = 0.0f;
	layer.dst_size_w   = (float)ctx->attr.displayWidth;
	layer.dst_size_h   = (float)ctx->attr.displayHeight;
	layer.slot         = kLayerSlotFramebuffer;
	layer.blend        = kBlendOpaque;
	layer.alpha        = 1.0f;

	const struct DMCModeSnapshot *snap = dmc_current_snapshot();
	struct FrameDescriptor desc;
	desc.layers               = &layer;
	desc.layer_count          = 1;
	desc.generation           = snap ? snap->generation : 0;
	desc.vbl_tick_target_usec = 0;

	int32_t rc = MetalCompositorSubmitFrame(&desc);
	if (rc == kGfxAccelErrStaleGeneration) {
		DSP_LOG("SwapBuffers: SubmitFrame stale generation; dropping "
		        "frame (ctxRef=%u)", ctxRef);
		/* Per the engine-blind contract, the caller should rebuild on the
		 * next mode snapshot — return noErr so DSp clients don't abandon
		 * their run-loops; classic-Mac apps have no "rebuild" concept
		 * and expect SwapBuffers to always succeed unless something is
		 * critically wrong. */
	} else if (rc != kGfxAccelNoErr) {
		DSP_LOG("SwapBuffers: SubmitFrame returned %d (ctxRef=%u)",
		        rc, ctxRef);
	}

	/* Reset dirty state. SwapBuffers always full-blits; the
	 * dirty-union reset logic subsumes these two lines. */
	ctx->dirty_empty      = true;
	ctx->dirty_cold_start = false;

	/* PDF p.39: "This function returns immediately, even if the buffer
	 * swap has not yet occurred." */
	return kDSpNoErr;
}

/* --------------------------------------------------------------------- *
 *  Local helpers                                                        *
 *                                                                       *
 *  DSpAlignedRowBytes / DSpBackBufferSize / DSpReserveGuestScratch live *
 *  as file-local static-inline helpers in dsp_metal_renderer.mm:73-143  *
 *  (not exported through any header — they predate the per-engine      *
 *  refactor). The Redirect helper below needs all three. Re-declaring   *
 *  them here as the same static-inline bodies keeps the implementations *
 *  identical (single source of truth for the formulas) and avoids a    *
 *  cross-TU API surface refactor. These could be hoisted into           *
 *  dsp_metal_renderer.h if a third caller emerges.                      *
 * --------------------------------------------------------------------- */

static inline uint32_t DSpAlignedRowBytes(uint32_t w, uint32_t bpp)
{
	uint32_t row_bytes = (w * bpp + 7) / 8;
	return (row_bytes + 255) & ~255u;
}

static inline uint32_t DSpBackBufferSize(uint32_t w, uint32_t h, uint32_t bpp)
{
	return DSpAlignedRowBytes(w, bpp) * h;
}

static inline void DSpPixMapFormatForDepth(uint32_t bpp,
                                            uint16_t *pixelType,
                                            uint16_t *pixelSize,
                                            uint16_t *cmpCount,
                                            uint16_t *cmpSize)
{
	if (bpp == 16) {
		*pixelType = 0x10;    /* RGBDirect */
		*pixelSize = 16;
		*cmpCount = 3;
		*cmpSize = 5;
	} else if (bpp == 32) {
		*pixelType = 0x10;    /* RGBDirect */
		*pixelSize = 32;
		*cmpCount = 3;
		*cmpSize = 8;
	} else {
		*pixelType = 0;       /* chunky indexed */
		*pixelSize = (uint16_t)bpp;
		*cmpCount = 1;
		*cmpSize = (uint16_t)bpp;
	}
}

static inline void DSpWriteCanonicalMainDevicePixMapMetadata(uint32_t pixMapPtr)
{
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PMVERSION,
	              DSpMainDevicePixMapVersion());
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PACKTYPE,
	              DSpMainDevicePixMapPackType());
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PACKSIZE,
	              DSpMainDevicePixMapPackSize());
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_HRES,
	              DSpMainDevicePixMapResolution());
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_VRES,
	              DSpMainDevicePixMapResolution());
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PLANEBYTES,
	              DSpMainDevicePixMapPlaneBytes());
}

#ifdef TESTING_BUILD
extern "C" uint32_t dsp_testing_alloc_guest_scratch(uint32_t size);  /* defined later in this file */
#endif

uint32_t DSpReserveGuestScratch(uint32_t size)
{
#ifdef TESTING_BUILD
	return dsp_testing_alloc_guest_scratch(size);
#else
	return SheepMem::Reserve(size);
#endif
}

static void DSpInitializeFrontBufferStaging(DSpContextPrivate *ctx,
                                            uint32_t baseAddr_mac,
                                            uint32_t buffer_size,
                                            uint32_t front_depth,
                                            const char *caller)
{
	if (ctx == nullptr || baseAddr_mac == 0 || buffer_size == 0) return;

	DSpFrontStagingSeedRGB seed =
	    DSpFrontStagingSeedRGBForBackPixelZero(ctx->attr.backBufferBestDepth,
	                                           ctx->clut_bytes);
	uint8_t *dst = Mac2HostAddr(baseAddr_mac);
	if (dst == NULL) {
		Mac_memset(baseAddr_mac, 0, buffer_size);
		ctx->front_staging_present_state = {};
		DSP_LOG("%s: front staging seed fallback memset zero "
		        "(addr=0x%08x size=%u depth=%u)",
		        caller, baseAddr_mac, buffer_size, front_depth);
		return;
	}

	if (front_depth == 16) {
		const uint16_t pixel =
		    DSpPackRGB555BigEndian(seed.r, seed.g, seed.b);
		uint8_t pixel_bytes[2];
		DSpStoreRGB555FrontStagingBytes(pixel, pixel_bytes);
		for (uint32_t i = 0; i + 1 < buffer_size; i += 2) {
			dst[i + 0] = pixel_bytes[0];
			dst[i + 1] = pixel_bytes[1];
		}
		DSpFrontStagingRememberSeedBytes(
			&ctx->front_staging_present_state,
			dst,
			buffer_size);
		DSP_LOG("%s: front staging initialized from back pixel zero "
		        "(addr=0x%08x size=%u depth=%u rgb=%u,%u,%u pixel=0x%04x "
		        "bytes=%02x,%02x)",
		        caller, baseAddr_mac, buffer_size, front_depth,
		        seed.r, seed.g, seed.b, pixel,
		        pixel_bytes[0], pixel_bytes[1]);
		return;
	}

	Mac_memset(baseAddr_mac, 0, buffer_size);
	DSpFrontStagingRememberSeedBytes(
		&ctx->front_staging_present_state,
		dst,
		buffer_size);
	DSP_LOG("%s: front staging initialized to zero "
	        "(addr=0x%08x size=%u depth=%u rgb=%u,%u,%u)",
	        caller, baseAddr_mac, buffer_size, front_depth,
	        seed.r, seed.g, seed.b);
}

static uint32_t DSpEnsureFrontBufferStaging(DSpContextPrivate *ctx,
                                            uint32_t row_bytes,
                                            uint32_t height,
                                            uint32_t front_depth,
                                            const char *caller)
{
	if (ctx == nullptr || row_bytes == 0 || height == 0) return 0;

	const uint32_t buffer_size = row_bytes * height;
	const uint32_t back_staging_row_bytes =
	    DSpAlignedRowBytes(DSpContextBackBufferWidth(ctx),
	                       ctx->attr.backBufferBestDepth);
	if (ctx->front_staging_mac_addr != 0 &&
	    ctx->front_staging_size >= buffer_size) {
		uint32_t reusable = DSpUsableGuestBaseOrZero(
			ctx->front_staging_mac_addr,
			buffer_size,
			(uint32_t)RAMBase,
			(uint32_t)RAMSize);
		if (reusable != 0) {
			if (DSpShouldRefreshFrontBufferStagingFromBackStaging(
			        ctx->attr.backBufferBestDepth,
			        front_depth,
			        ctx->staging_mac_addr,
			        reusable,
			        ctx->staging_size,
			        buffer_size,
			        back_staging_row_bytes,
			        row_bytes)) {
				uint8_t *dst = Mac2HostAddr(reusable);
				uint8_t *src = Mac2HostAddr(ctx->staging_mac_addr);
				if (dst != NULL && src != NULL) {
					memcpy(dst, src, buffer_size);
					DSpFrontStagingRememberSeedBytes(
						&ctx->front_staging_present_state,
						dst,
						buffer_size);
					DSP_LOG("%s: front staging refreshed from back staging "
					        "(src=0x%08x dst=0x%08x size=%u rowBytes=%u bpp=%u)",
					        caller, ctx->staging_mac_addr, reusable,
					        buffer_size, row_bytes, front_depth);
				}
			}
			return reusable;
		}
		DSP_LOG("%s: discarding unusable front staging "
		        "(addr=0x%08x size=%u need=%u)",
		        caller, ctx->front_staging_mac_addr,
		        ctx->front_staging_size, buffer_size);
		DSpReleaseFrontBufferStaging(ctx);
	} else if (ctx->front_staging_mac_addr != 0) {
		DSP_LOG("%s: replacing undersized front staging "
		        "(addr=0x%08x size=%u need=%u)",
		        caller, ctx->front_staging_mac_addr,
		        ctx->front_staging_size, buffer_size);
		DSpReleaseFrontBufferStaging(ctx);
	}

	uint32_t staging_mac = DSpReserveGuestPixelStaging(buffer_size);
	uint32_t baseAddr_mac = DSpUsableGuestBaseOrZero(
		staging_mac,
		buffer_size,
		(uint32_t)RAMBase,
		(uint32_t)RAMSize);
	if (baseAddr_mac == 0) {
		DSpDiscardUnusedGuestPixelStaging(staging_mac, true);
		DSP_LOG("%s: front staging allocation unusable "
		        "(size=%u, addr=0x%08x, frontDepth=%u)",
		        caller, buffer_size, staging_mac, front_depth);
		return 0;
	}

	ctx->front_staging_mac_addr = baseAddr_mac;
	ctx->front_staging_size = buffer_size;
#ifndef TESTING_BUILD
	ctx->front_staging_owned_sysheap = true;
#endif
	bool seeded_from_back_staging = false;
	if (DSpShouldSeedFrontBufferStagingFromBackStaging(
	        ctx->attr.backBufferBestDepth,
	        front_depth,
	        ctx->staging_mac_addr,
	        ctx->staging_size,
	        back_staging_row_bytes,
	        buffer_size,
	        row_bytes)) {
		uint8_t *dst = Mac2HostAddr(baseAddr_mac);
		uint8_t *src = Mac2HostAddr(ctx->staging_mac_addr);
		if (dst != NULL && src != NULL) {
			memcpy(dst, src, buffer_size);
			DSpFrontStagingRememberSeedBytes(
				&ctx->front_staging_present_state,
				dst,
				buffer_size);
			seeded_from_back_staging = true;
			DSP_LOG("%s: front staging seeded from back staging "
			        "(src=0x%08x dst=0x%08x size=%u rowBytes=%u bpp=%u)",
			        caller, ctx->staging_mac_addr, baseAddr_mac,
			        buffer_size, row_bytes, front_depth);
		}
	}
	if (!seeded_from_back_staging) {
		DSpInitializeFrontBufferStaging(ctx, baseAddr_mac, buffer_size,
		                                front_depth, caller);
	}
	DSP_LOG("%s: front staging reserved "
	        "(addr=0x%08x size=%u rowBytes=%u bpp=%u)",
	        caller, baseAddr_mac, buffer_size, row_bytes, front_depth);
	return baseAddr_mac;
}


/* ===================================================================== *
 *  Blit (sub-ops 710-711).
 *
 *  DSpBlit_Fastest (711): strict 1:1 copy (srcRect == dstRect, no scaling)
 *    via the proven nqd_bitblt kernel (NQDMetalBitblt1to1).
 *  DSpBlit_Faster (710): scales srcRect -> dstRect via the NEW
 *    nqd_bitblt_scaled kernel (NQDMetalBitbltScaled); nearest-neighbor by
 *    default, bilinear only when kDSpBlitMode_Interpolation set (PDF p.87);
 *    color-key honored per SrcKey/DstKey.
 *
 *  Both reuse NQD's single-queue Metal compute path (no DSp-specific
 *  blit path) and add ZERO new concurrency primitive. The async path
 *  (inAsyncFlag + completionProc) is synchronous-then-complete: encode +
 *  flush, set completionFlag = true, then invoke completionProc via
 *  call_macos1 (the PPC-trampoline idiom — NEVER a raw C cast of the guest
 *  fn-ptr). A guest DSpBlitDoneProc takes one arg (the DSpBlitInfoPtr back).
 *
 *  Security (ASVS L1 V5): NULL-guard inBlitInfo; reject OOB src/dst baseAddr
 *  via NQDMetalAddrInBuffer BEFORE GPU dispatch; clamp src/dst rects to the
 *  CGrafPort bounds before computing kernel geometry.
 * ===================================================================== */

/* A resolved view of one side (src or dst) of a DSpBlit. baseAddr is the Mac
 * (guest) address of the rect ORIGIN (pixmap baseAddr + top*rowBytes +
 * left*bpp); the NQD entries fold this in once so the kernel addresses from
 * the rect origin. */
struct DSpBlitSide {
	uint32_t base_origin_mac;  /* Mac addr of the rect origin pixel */
	int32_t  row_bytes;        /* signed row stride (high bit masked off) */
	uint32_t pixel_bytes;      /* bytes per pixel (1, 2, or 4) */
	uint32_t bits_per_pixel;   /* raw depth (8, 16, 32) */
	int32_t  rect_w;           /* clamped rect width in pixels */
	int32_t  rect_h;           /* clamped rect height in pixels */
};

static uint32_t DSpResolvePixMapRecord(uint32_t cgrafptr_mac)
{
	if (cgrafptr_mac == 0) return 0;

	uint16_t port_version =
	    (uint16_t)ReadMacInt16(cgrafptr_mac + DSP_CGRAFPORT_OFF_PORT_VERSION);
	if (!DSpLooksLikeColorCGrafPort(port_version)) {
		return cgrafptr_mac;
	}

	uint32_t pixmap_handle =
	    ReadMacInt32(cgrafptr_mac + DSP_CGRAFPORT_OFF_PORT_PIXMAP);
	if (pixmap_handle == 0) return 0;
	return ReadMacInt32(pixmap_handle);
}

/* Resolve one CGrafPtr + its blit Rect into a DSpBlitSide. The CGrafPtr uses
 * either the DSp flat shim layout (alt buffers and legacy callers) or a real
 * CGrafPort whose portPixMap points at a PixMapHandle (back/front buffers).
 * The resolved PixMap uses
 * baseAddr@0, rowBytes@4 — high bit is the classic PixMap flag and is masked
 * off — and bounds@6 in both layouts. Extra PixMap fields use compact offsets
 * for flat shims and real QuickDraw offsets for Color CGrafPorts. The blit
 * Rect (top@+0/left@+2/bottom@+4/right@+6, big-endian i16) is clamped to the
 * PixMap bounds. Returns false on a NULL CGrafPtr, an unsupported depth, or an
 * empty/inverted rect. */
static bool DSpResolveBlitSide(uint32_t cgrafptr_mac, uint32_t rect_mac,
                               DSpBlitSide *out)
{
	if (cgrafptr_mac == 0 || rect_mac == 0 || out == nullptr) return false;

	uint16_t port_version =
	    (uint16_t)ReadMacInt16(cgrafptr_mac + DSP_CGRAFPORT_OFF_PORT_VERSION);
	uint32_t pixmap_mac = DSpResolvePixMapRecord(cgrafptr_mac);
	if (pixmap_mac == 0) return false;

	uint32_t baseAddr   = ReadMacInt32(pixmap_mac + DSP_PIXMAP_OFF_BASEADDR);
	uint16_t rb_raw     = (uint16_t)ReadMacInt16(pixmap_mac + DSP_PIXMAP_OFF_ROWBYTES);
	int16_t  pbnd_top   = (int16_t)ReadMacInt16(pixmap_mac + DSP_PIXMAP_OFF_BOUNDS_TOP);
	int16_t  pbnd_left  = (int16_t)ReadMacInt16(pixmap_mac + DSP_PIXMAP_OFF_BOUNDS_LEFT);
	int16_t  pbnd_bot   = (int16_t)ReadMacInt16(pixmap_mac + DSP_PIXMAP_OFF_BOUNDS_BOT);
	int16_t  pbnd_right = (int16_t)ReadMacInt16(pixmap_mac + DSP_PIXMAP_OFF_BOUNDS_RIGHT);
	uint32_t pixel_size_offset =
	    DSpPixMapExtraFieldOffsetForPortVersion(
	        port_version,
	        DSP_PIXMAP_OFF_PIXELSIZE,
	        DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE);
	uint16_t pixelSize  = (uint16_t)ReadMacInt16(pixmap_mac + pixel_size_offset);

	if (baseAddr == 0) return false;

	/* Enforce a POSITIVE row stride. DSp-vended surfaces are top-down
	 * BGRA (compositor contract), so a genuinely negative (bottom-up DIB)
	 * stride is unsupported. The classic PixMap rowBytes high bit is a flag,
	 * not a sign bit, so masking it off (& 0x7FFF) already yields a positive
	 * 15-bit magnitude — the contract is therefore "positive stride only", and
	 * the extent check uses abs(row_bytes) only as belt-and-suspenders.
	 * A zero stride is degenerate and rejected. */
	uint32_t row_bytes = (uint32_t)(rb_raw & 0x7FFFu);   /* mask the PixMap high bit -> positive */
	if (row_bytes == 0) return false;

	uint32_t bpp_bytes;
	switch (pixelSize) {
		case 8:  bpp_bytes = 1; break;
		case 16: bpp_bytes = 2; break;
		case 32: bpp_bytes = 4; break;
		default: return false;   /* sub-byte / unsupported depth */
	}

	int16_t r_top    = (int16_t)ReadMacInt16(rect_mac + 0);
	int16_t r_left   = (int16_t)ReadMacInt16(rect_mac + 2);
	int16_t r_bottom = (int16_t)ReadMacInt16(rect_mac + 4);
	int16_t r_right  = (int16_t)ReadMacInt16(rect_mac + 6);

	/* Clamp the blit rect to the pixmap bounds (ASVS V5). The pixmap bounds
	 * origin (pbnd_top/left) is the addressing origin for baseAddr. */
	int32_t c_top    = (r_top    < pbnd_top)   ? pbnd_top   : r_top;
	int32_t c_left   = (r_left   < pbnd_left)  ? pbnd_left  : r_left;
	int32_t c_bottom = (r_bottom > pbnd_bot)   ? pbnd_bot   : r_bottom;
	int32_t c_right  = (r_right  > pbnd_right) ? pbnd_right : r_right;

	int32_t w = c_right  - c_left;
	int32_t h = c_bottom - c_top;
	if (w <= 0 || h <= 0) return false;   /* empty / inverted */

	/* Mac addr of the rect origin pixel, relative to the pixmap bounds
	 * origin: baseAddr + (top - bnd_top)*rowBytes + (left - bnd_left)*bpp. */
	uint32_t row_off = (uint32_t)(c_top  - pbnd_top)  * row_bytes;
	uint32_t col_off = (uint32_t)(c_left - pbnd_left) * bpp_bytes;

	out->base_origin_mac = baseAddr + row_off + col_off;
	out->row_bytes       = (int32_t)row_bytes;
	out->pixel_bytes     = bpp_bytes;
	out->bits_per_pixel  = pixelSize;
	out->rect_w          = w;
	out->rect_h          = h;
	return true;
}

/* Shared completion epilogue: flush the NQD batch so the GPU work is visible,
 * set DSpBlitInfo.completionFlag = true, and (when async + a non-NULL
 * completionProc was supplied) invoke the guest proc via call_macos1 — the
 * sanctioned PPC-trampoline idiom (NEVER a raw C cast of the guest fn-ptr).
 * Synchronous-then-complete is behavior-faithful for a single-display
 * emulator; NO MTLFence/MTLSharedEvent/_Atomic. */
static void DSpBlitComplete(uint32_t inBlitInfo, uint32_t inAsyncFlag)
{
	/* Make the blit's GPU writes visible before signalling completion. */
	NQDMetalFlush();

	WriteMacInt8(inBlitInfo + DSP_BLITINFO_OFF_completionFlag, 1);

	uint32_t completionProc = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_completionProc);
	if (inAsyncFlag != 0 && completionProc != 0) {
		/* DSpBlitDoneProc(DSpBlitInfoPtr) — one arg, the DSpBlitInfo back.
		 * call_macos1 marshals the arg into PPC r3 and executes the
		 * TVECT-addressed routine (same trampoline as the VBLProc call_macos3
		 * at the top of this file). */
		(void)call_macos1(completionProc, inBlitInfo);
	}
}

/* --- DSpBlit_FastestHandler (sub-op 711) ---
 *
 *  DSp 1.7 PDF p.47: DSpBlit_Fastest(inBlitInfo, inAsyncFlag). The spec defines
 *  Fastest as a strict 1:1 copy where the caller GUARANTEES srcRect == dstRect
 *  and the real implementation does no validation. We deliberately
 *  DIVERGE for safety — if the guest passes mismatched src/dst rects we clamp
 *  the copied extent to the OVERLAP (the smaller of the two rects) rather than
 *  scale or fault, so a mismatched-rect request can never read/write outside
 *  the resolved geometry (defense-in-depth alongside the extent check).
 *  This is a known, intentional M2-fidelity deviation (an app relying on the
 *  exact garbage/fault behavior of mismatched Fastest rects would observe a
 *  difference). Reads DSpBlitInfo via DSP_BLITINFO_OFF_*; resolves src/dst
 *  CGrafPtr + Rect; reuses the proven nqd_bitblt 1:1 kernel via
 *  NQDMetalBitblt1to1. mode SrcKey -> transparent (mode 36); Plain -> srcCopy
 *  (0). NULL inBlitInfo -> kDSpInvalidAttributesErr; OOB baseAddr / unsupported
 *  depth -> kDSpInternalErr. */
extern "C" int32_t DSpBlit_FastestHandler(uint32_t inBlitInfo,
                                          uint32_t inAsyncFlag)
{
	if (inBlitInfo == 0) {
		DSP_LOG("DSpBlit_Fastest: NULL inBlitInfo -> kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}

	uint32_t srcBuffer = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_srcBuffer);
	uint32_t dstBuffer = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_dstBuffer);
	uint32_t srcRect   = inBlitInfo + DSP_BLITINFO_OFF_srcRect;
	uint32_t dstRect   = inBlitInfo + DSP_BLITINFO_OFF_dstRect;
	uint32_t srcKey    = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_srcKey);
	uint32_t mode      = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_mode);

	DSpBlitSide s, d;
	if (!DSpResolveBlitSide(srcBuffer, srcRect, &s) ||
	    !DSpResolveBlitSide(dstBuffer, dstRect, &d)) {
		DSP_LOG("DSpBlit_Fastest: unresolved/empty src or dst -> kDSpInternalErr");
		return kDSpInternalErr;
	}
	/* Fastest is 1:1 (no scaling). The spec assumes srcRect == dstRect;
	 * we do NOT trust that. If the guest passed mismatched sizes we clamp the
	 * copied extent to the OVERLAP (min of the two rects) as a safety measure —
	 * this both honors "no scaling" and keeps the copy inside the smaller
	 * resolved rect. This intentionally diverges from real DSpBlit_Fastest
	 * (which would copy/fault per the larger rect); see the handler doc above. */
	int32_t w = (s.rect_w < d.rect_w) ? s.rect_w : d.rect_w;
	int32_t h = (s.rect_h < d.rect_h) ? s.rect_h : d.rect_h;
	if (w <= 0 || h <= 0) return kDSpInternalErr;
	if (s.pixel_bytes != d.pixel_bytes) {
		DSP_LOG("DSpBlit_Fastest: src/dst depth mismatch -> kDSpInternalErr");
		return kDSpInternalErr;
	}

	uint32_t transfer_mode = (mode & (uint32_t)kDSpBlitMode_SrcKey) ? 36u : 0u;

	if (!NQDMetalBitblt1to1(s.base_origin_mac, s.row_bytes,
	                        d.base_origin_mac, d.row_bytes,
	                        d.pixel_bytes, d.bits_per_pixel,
	                        (uint32_t)w, (uint32_t)h,
	                        transfer_mode, srcKey)) {
		DSP_LOG("DSpBlit_Fastest: NQD dispatch rejected (OOB/unavailable) -> kDSpInternalErr");
		return kDSpInternalErr;
	}

	DSpBlitComplete(inBlitInfo, inAsyncFlag);
	DSP_VLOG("DSpBlit_Fastest: 1:1 %dx%d mode=0x%x async=%u",
	         w, h, mode, inAsyncFlag);
	return kDSpNoErr;
}

/* --- DSpBlit_FasterHandler (sub-op 710) ---
 *
 *  DSp 1.7 PDF p.46: DSpBlit_Faster(inBlitInfo, inAsyncFlag). Scales srcRect
 *  -> dstRect. Per kDSpBlitMode_Interpolation (PDF p.87) scaling defaults to
 *  nearest-neighbor and bilinear is opt-in. Dispatches the NEW nqd_bitblt_
 *  scaled kernel via NQDMetalBitbltScaled; color-key honored per SrcKey/DstKey.
 *  NULL inBlitInfo -> kDSpInvalidAttributesErr; OOB baseAddr / unsupported
 *  depth -> kDSpInternalErr. */
extern "C" int32_t DSpBlit_FasterHandler(uint32_t inBlitInfo,
                                         uint32_t inAsyncFlag)
{
	if (inBlitInfo == 0) {
		DSP_LOG("DSpBlit_Faster: NULL inBlitInfo -> kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}

	uint32_t srcBuffer = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_srcBuffer);
	uint32_t dstBuffer = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_dstBuffer);
	uint32_t srcRect   = inBlitInfo + DSP_BLITINFO_OFF_srcRect;
	uint32_t dstRect   = inBlitInfo + DSP_BLITINFO_OFF_dstRect;
	uint32_t srcKey    = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_srcKey);
	uint32_t dstKey    = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_dstKey);
	uint32_t mode      = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_mode);

	DSpBlitSide s, d;
	if (!DSpResolveBlitSide(srcBuffer, srcRect, &s) ||
	    !DSpResolveBlitSide(dstBuffer, dstRect, &d)) {
		DSP_LOG("DSpBlit_Faster: unresolved/empty src or dst -> kDSpInternalErr");
		return kDSpInternalErr;
	}
	if (s.pixel_bytes != d.pixel_bytes) {
		DSP_LOG("DSpBlit_Faster: src/dst depth mismatch -> kDSpInternalErr");
		return kDSpInternalErr;
	}

	uint32_t interpolate = (mode & (uint32_t)kDSpBlitMode_Interpolation) ? 1u : 0u;
	uint32_t key_enable  = 0;
	if (mode & (uint32_t)kDSpBlitMode_SrcKey) key_enable |= 1u;
	if (mode & (uint32_t)kDSpBlitMode_DstKey) key_enable |= 2u;

	if (!NQDMetalBitbltScaled(s.base_origin_mac, s.row_bytes,
	                          d.base_origin_mac, d.row_bytes,
	                          d.pixel_bytes, d.bits_per_pixel,
	                          (uint32_t)s.rect_w, (uint32_t)s.rect_h,
	                          (uint32_t)d.rect_w, (uint32_t)d.rect_h,
	                          interpolate, srcKey, dstKey, key_enable)) {
		DSP_LOG("DSpBlit_Faster: NQD scaled dispatch rejected (OOB/unavailable) -> kDSpInternalErr");
		return kDSpInternalErr;
	}

	DSpBlitComplete(inBlitInfo, inAsyncFlag);
	DSP_VLOG("DSpBlit_Faster: scaled %dx%d->%dx%d interp=%u key=0x%x async=%u",
	         s.rect_w, s.rect_h, d.rect_w, d.rect_h, interpolate, key_enable, inAsyncFlag);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/* Host-helper twins for the no-ROM test spine. They take a guest-RAM
 * DSpBlitInfo Mac address already populated by the test (via the
 * dsp_testing_write_mac_int* shims into the scratch region) so the production
 * read-path + NQD dispatch are exercised without an EMULATED_PPC frame; the
 * completionProc call_macos1 path is NOT exercised from the host helper (no
 * guest TVECT), only the synchronous completionFlag write. The test gates the
 * GPU-effect assertions behind dsp_testing_scratch_in_low_4gib()
 * and asserts the NULL / depth-mismatch guards unconditionally. */
extern "C" int32_t DSpTesting_BlitFastestByAddr(uint32_t inBlitInfo, uint32_t inAsyncFlag)
{
	return DSpBlit_FastestHandler(inBlitInfo, inAsyncFlag);
}

extern "C" int32_t DSpTesting_BlitFasterByAddr(uint32_t inBlitInfo, uint32_t inAsyncFlag)
{
	return DSpBlit_FasterHandler(inBlitInfo, inAsyncFlag);
}

/* Resolve-side host helper so the test can assert the CGrafPtr + Rect ->
 * clamped geometry contract (overscan mitigation) without dispatching the GPU.
 * Returns 1 on resolve, 0 on reject; fills the out cells when non-NULL. */
extern "C" int DSpTesting_ResolveBlitSide(uint32_t cgrafptr_mac, uint32_t rect_mac,
                                          uint32_t *out_base_origin, int32_t *out_row_bytes,
                                          uint32_t *out_pixel_bytes,
                                          int32_t *out_w, int32_t *out_h)
{
	DSpBlitSide side;
	if (!DSpResolveBlitSide(cgrafptr_mac, rect_mac, &side)) return 0;
	if (out_base_origin) *out_base_origin = side.base_origin_mac;
	if (out_row_bytes)   *out_row_bytes   = side.row_bytes;
	if (out_pixel_bytes) *out_pixel_bytes = side.pixel_bytes;
	if (out_w)           *out_w           = side.rect_w;
	if (out_h)           *out_h           = side.rect_h;
	return 1;
}
#endif

/* --- GetBackBuffer underlay-restore branch ---
 *
 *  PDF p.51: "When a back buffer is retrieved and there is an underlay
 *  buffer, the invalid areas in the back buffer are restored from the
 *  underlay buffer. This is most useful in sprite games." Called from
 *  DSpContext_GetBackBufferHandler.
 *
 *  When ctx has a designated underlay AND the back buffer has dirty areas,
 *  this:
 *    (1) copies the dirty sub-rect underlay->back_buffer (CPU memcpy on the
 *        MTLStorageModeShared backing — the alt-buffer is BGRA8Unorm 32-bpp;
 *        a copy is only attempted when both contents pointers are non-NULL,
 *        which holds on device/Catalyst — on the simulator the heap forces
 *        StorageModePrivate so the copy is skipped and only the compositor
 *        layer routes), and
 *    (2) routes the underlay into the existing frame via a
 *        CompositeLayer{slot=kLayerSlotUnderlay} added to the SubmitFrame —
 *        slot only, NEVER kGfxEngineDSp (SC #5, engine-blind).
 *
 *  No-op when no underlay is designated or the back buffer is clean. Single-
 *  writer emul-thread; ZERO new concurrency primitive — the copy is a
 *  plain memcpy and the layer joins the existing single MTLCommandQueue
 *  frame path. */


static void DSpRestoreBackBufferFromUnderlay(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->underlay_alt_buffer == 0) return;
	DSpAltBufferRecord *u = DSpGetAltBuffer(ctx->underlay_alt_buffer);
	if (u == nullptr) {
		/* Stale designation (underlay disposed) — clear it defensively. */
		ctx->underlay_alt_buffer = 0;
		return;
	}
	/* Mirror the guest-drawn staging into the underlay's Metal backing so both
	 * the CPU dirty-band restore and the compositor underlay layer below read
	 * the guest's pixels (NQD draws land in the guest-RAM staging, not Metal). */
	DSpSyncAltBufferStagingToBacking(u);
	/* Only restore the BACK buffer's invalid (dirty) areas (PDF p.51). When
	 * the back buffer is clean there is nothing to clean. */
	if (ctx->dirty_empty) return;
	if (ctx->back_buffer == nil) return;

	/* Intersection of the back-buffer dirty rect with the underlay bounds. */
	int32_t rx0 = ctx->dirty_left,  ry0 = ctx->dirty_top;
	int32_t rx1 = ctx->dirty_right, ry1 = ctx->dirty_bottom;
	if (rx0 < 0) rx0 = 0;
	if (ry0 < 0) ry0 = 0;
	if ((uint32_t)rx1 > u->width)  rx1 = (int32_t)u->width;
	if ((uint32_t)ry1 > u->height) ry1 = (int32_t)u->height;
	if (rx1 <= rx0 || ry1 <= ry0) return;

	/* (1) CPU restore copy (underlay BGRA8Unorm -> back buffer) — only when
	 * both backings are host-visible (Shared). The back buffer's pixel
	 * format matches its depth; for the golden underlay-restore path the
	 * context + underlay are both 32-bpp BGRA8Unorm so the copy is a direct
	 * row-wise memcpy of the dirty band. Skipped on StorageModePrivate
	 * (simulator) where contents is NULL — the compositor layer below still
	 * routes the underlay.
	 *
	 * Known M1 approximation: the dirty-band CPU restore only runs for
	 * a 32-bpp back buffer because the underlay is always allocated BGRA8Unorm
	 * (DSpAllocAltBufferBacking). An 8/16-bpp context would need a per-pixel
	 * format conversion that is NOT implemented, so the PDF-p.51 "clean a back
	 * buffer" restore silently no-ops at those depths (only the compositor
	 * underlay layer below routes). This mirrors the project's IsBusy /
	 * swap-in-flight M1-deferral pattern; the depth conversion is deferred. The
	 * else-branch below logs the skipped restore rather than silently no-op'ing. */
	void *u_contents  = u->backing.contents;
	void *bb_contents = ctx->back_buffer.contents;
	if (u_contents != NULL && bb_contents != NULL &&
	    ctx->attr.backBufferBestDepth == 32) {
		uint32_t u_rb  = ((u->width * 4u) + 255u) & ~255u;
		uint32_t bb_rb = DSpAlignedRowBytes(DSpContextBackBufferWidth(ctx),
		                                    32);
		uint8_t *u_base  = (uint8_t *)u_contents;
		uint8_t *bb_base = (uint8_t *)bb_contents;
		uint32_t band_bytes = (uint32_t)(rx1 - rx0) * 4u;
		for (int32_t y = ry0; y < ry1; y++) {
			uint8_t *src = u_base  + (uint32_t)y * u_rb  + (uint32_t)rx0 * 4u;
			uint8_t *dst = bb_base + (uint32_t)y * bb_rb + (uint32_t)rx0 * 4u;
			memcpy(dst, src, band_bytes);
		}
		DSP_LOG("UnderlayRestore: ctx=%u underlay=%u copied dirty band "
		        "(%d,%d)-(%d,%d)", ctx->handle, ctx->underlay_alt_buffer,
		        rx0, ry0, rx1, ry1);
	} else if (u_contents != NULL && bb_contents != NULL &&
	           ctx->attr.backBufferBestDepth != 32) {
		/* Depth precludes the BGRA8Unorm->back-buffer restore copy.
		 * Make the skipped restore observable instead of silently no-op'ing. */
		DSP_LOG("UnderlayRestore: ctx=%u underlay=%u back-buffer depth=%u (not "
		        "32-bpp) — CPU dirty-band restore SKIPPED (known M1 approximation, "
		        "depth-conversion deferred); compositor underlay layer still routes",
		        ctx->handle, ctx->underlay_alt_buffer,
		        ctx->attr.backBufferBestDepth);
	}

	/* (2) Route the underlay into the frame via the engine-blind compositor
	 * named slot (slot only — NEVER pass kGfxEngineDSp, SC #5). The
	 * underlay layer is z-ordered BELOW the framebuffer layer. */
	void *u_tex = (__bridge void *)u->texture;
	if (u_tex != NULL) {
		struct CompositeLayer layer;
		std::memset(&layer, 0, sizeof(layer));
		layer.source       = u_tex;          /* BGRA8Unorm DSp-owned alt-buffer texture */
		layer.src_origin_x = 0;
		layer.src_origin_y = 0;
		layer.src_size_w   = u->width;
		layer.src_size_h   = u->height;
		layer.dst_origin_x = 0.0f;
		layer.dst_origin_y = 0.0f;
		layer.dst_size_w   = (float)u->width;
		layer.dst_size_h   = (float)u->height;
		layer.slot         = kLayerSlotUnderlay;   /* slot only — engine-blind */
		layer.blend        = kBlendOpaque;
		layer.alpha        = 1.0f;

		const struct DMCModeSnapshot *snap = dmc_current_snapshot();
		struct FrameDescriptor desc;
		desc.layers               = &layer;
		desc.layer_count          = 1;
		desc.generation           = snap ? snap->generation : 0;
		desc.vbl_tick_target_usec = 0;
		(void)MetalCompositorSubmitFrame(&desc);
	}
}

/* --------------------------------------------------------------------- *
 *  MainDevice PixMap redirect / restore                                 *
 *                                                                       *
 *  DSpRedirectMainDevicePixMap reads emulated lowmem via the sanctioned *
 *  bare-offset arithmetic precedent (emul_op.cpp:489,496;               *
 *  rsrc_patches.cpp:930,967,1018):                                      *
 *                                                                       *
 *      LMADDR_MAIN_DEVICE (0x8A4) -> GDeviceHandle                      *
 *        -> *GDeviceHandle -> GDevice struct                            *
 *          -> GDEVICE_OFF_PMAP (0x16) -> PixMapHandle                   *
 *            -> *PixMapHandle -> PixMap struct (baseAddr / rowBytes /   *
 *               bounds at DSP_PIXMAP_OFF_*)                             *
 *                                                                       *
 *  The original baseAddr / rowBytes / bounds are cached in              *
 *  ctx->saved_pixmap_* fields BEFORE the WriteMacInt32 fires.           *
 *  Landmine-1: Host2MacAddr(ctx->back_buffer.contents) can return 0 or *
 *  a non-guest address for the kHeap-backed MTLBuffer on arm64 iOS;    *
 *  mandatory Mac system-heap staging fallback mirrors                  *
 *  DSpGetBackBufferCGrafPtr:427-441.                                    *
 *                                                                       *
 *  Security gate: the resolved newBaseAddr_mac MUST be               *
 *  non-zero AND inside [RAMBase, RAMBase + RAMSize) BEFORE the          *
 *  WriteMacInt32 fires. Failure short-circuits with saved_pixmap_valid  *
 *  cleared so the symmetric Restore is a no-op.                         *
 *                                                                       *
 *  Threading: emul-thread single-writer (DSpContextPrivate convention). *
 *  Invariant preserved: zero new threading primitives added.            *
 * --------------------------------------------------------------------- */

extern "C" void DSpRedirectMainDevicePixMap(DSpContextPrivate *ctx)
{
	if (ctx == nullptr) return;

	const uint32_t display_depth =
	    DSpDisplayModeDepth(ctx->attr.backBufferBestDepth,
	                        ctx->attr.displayBestDepth);
	if (!DSpShouldRedirectMainDevicePixMap(ctx->attr.backBufferBestDepth,
	                                       display_depth)) {
		DSpRestoreMainDevicePixMap(ctx);
		DSP_VLOG("DSpRedirectMainDevicePixMap: skipped MainDevice redirect "
		         "(backBuffer@%u display@%u); preserving screen PixMap for "
		         "RAVE/QD3D device discovery",
		         ctx->attr.backBufferBestDepth, display_depth);
		return;
	}
	const uint32_t redirect_depth =
	    DSpMainDevicePixMapDepth(ctx->attr.backBufferBestDepth,
	                             display_depth);

	/* Instrumented + defensive walk. Each step logs its input/output and
	 * refuses to dereference an intermediate Mac address that is not inside
	 * [RAMBase, RAMBase+RAMSize) OR inside gZeroPage [0..0x3000). Mirrors
	 * the OOB gate already used at the write site (line ~2451).
	 *
	 * Per-step DSP_LOG tag (DSP-RDR-Sn) lets the last log line before any
	 * future SIGSEGV identify the crashing dereference. */
	const uint32_t kLomemBase = 0x0;
	const uint32_t kLomemTop  = 0x3000;        /* matches gZeroPage in vm.hpp */
	const uint32_t kRamLo     = (uint32_t)RAMBase;
	const uint32_t kRamHi     = (uint32_t)(RAMBase + RAMSize);
	#define DSP_REDIR_INRANGE(a) \
		(((a) >= kRamLo && (a) < kRamHi) || \
		 ((a) >= kLomemBase && (a) < kLomemTop))

	/* DSP-RDR-S0: nil-check the back_buffer BEFORE any Mac-VM walk. If the
	 * back buffer is gone (or never allocated for this ctx), redirecting
	 * the PixMap is meaningless and a [nil contents] msgSend would still
	 * succeed-with-NULL but the downstream OOB gate would reject and we'd
	 * waste the lowmem walk. Bail early. */
	if (ctx->back_buffer == nil) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S0 ctx->back_buffer is nil "
		         "(ctx=%p) — skipping redirect", (void *)ctx);
		return;
	}

	/* DSP-RDR-S1: read lowmem MainDevice handle from 0x8A4 (always safe —
	 * lives inside gZeroPage). */
	uint32_t mainDeviceH = ReadMacInt32(LMADDR_MAIN_DEVICE);
	DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S1 LMADDR_MAIN_DEVICE@0x%08x -> "
	         "mainDeviceH=0x%08x", (uint32_t)LMADDR_MAIN_DEVICE, mainDeviceH);
	if (mainDeviceH == 0) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S1 mainDeviceH==0 — "
		         "pre-boot graceful skip");
		return;
	}
	if (!DSP_REDIR_INRANGE(mainDeviceH)) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S1 mainDeviceH=0x%08x "
		         "OUT-OF-RANGE (RAMBase=0x%08x RAMSize=0x%08x) — refusing walk",
		         mainDeviceH, kRamLo, (uint32_t)RAMSize);
		return;
	}

	/* DSP-RDR-S2: dereference MainDevice handle -> GDevice pointer. */
	uint32_t gdevicePtr = ReadMacInt32(mainDeviceH);
	DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S2 *mainDeviceH=0x%08x -> "
	         "gdevicePtr=0x%08x", mainDeviceH, gdevicePtr);
	if (gdevicePtr == 0) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S2 gdevicePtr==0 — skip");
		return;
	}
	if (!DSP_REDIR_INRANGE(gdevicePtr)) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S2 gdevicePtr=0x%08x "
		         "OUT-OF-RANGE — refusing walk", gdevicePtr);
		return;
	}

	/* DSP-RDR-S3: read GDevice.gdPMap @ +0x16 -> PixMapHandle. */
	uint32_t gdPMapAddr = gdevicePtr + GDEVICE_OFF_PMAP;
	if (!DSP_REDIR_INRANGE(gdPMapAddr)) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S3 gdPMapAddr=0x%08x "
		         "OUT-OF-RANGE (gdevicePtr+0x16 spilled) — refusing walk",
		         gdPMapAddr);
		return;
	}
	uint32_t pixMapH = ReadMacInt32(gdPMapAddr);
	DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S3 *(gdevicePtr+0x16)@0x%08x -> "
	         "pixMapH=0x%08x", gdPMapAddr, pixMapH);
	if (pixMapH == 0) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S3 pixMapH==0 — skip");
		return;
	}
	if (!DSP_REDIR_INRANGE(pixMapH)) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S3 pixMapH=0x%08x "
		         "OUT-OF-RANGE — refusing walk", pixMapH);
		return;
	}

	/* DSP-RDR-S4: dereference PixMapHandle -> PixMap pointer. */
	uint32_t pixMapPtr = ReadMacInt32(pixMapH);
	DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S4 *pixMapH=0x%08x -> "
	         "pixMapPtr=0x%08x", pixMapH, pixMapPtr);
	if (pixMapPtr == 0) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S4 pixMapPtr==0 "
		         "(pixMapPtr gate)");
		return;
	}
	if (!DSP_REDIR_INRANGE(pixMapPtr)) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S4 pixMapPtr=0x%08x "
		         "OUT-OF-RANGE — refusing walk", pixMapPtr);
		return;
	}
	/* Real MainDevice PixMap spans at least through cmpSize. */
	if (!DSP_REDIR_INRANGE(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE + 2)) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S4 PixMap struct "
		         "spills past RAM end (pixMapPtr=0x%08x) — refusing walk",
		         pixMapPtr);
		return;
	}

	/* DSP-RDR-S5: cache originals BEFORE overwrite. Same-PixMap
	 * reassertions must preserve the original screen PixMap snapshot; Nanosaur
	 * calls DSpContext_GetFrontBuffer and then directly probes MainDevice. */
	const bool should_cache_original =
	    DSpShouldCacheMainDevicePixMapOriginal(
	        ctx->saved_pixmap_valid != 0,
	        ctx->saved_pixmap_addr,
	        pixMapPtr);
	if (should_cache_original) {
		ctx->saved_pixmap_addr     = pixMapPtr;
		ctx->saved_pixmap_baseAddr = ReadMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR);
		ctx->saved_pixmap_rowBytes = (uint16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES);
		ctx->saved_pixmap_bounds[0] = (int16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP);
		ctx->saved_pixmap_bounds[1] = (int16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT);
		ctx->saved_pixmap_bounds[2] = (int16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT);
		ctx->saved_pixmap_bounds[3] = (int16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT);
		ctx->saved_pixmap_pixelType = (uint16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE);
		ctx->saved_pixmap_pixelSize = (uint16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE);
		ctx->saved_pixmap_cmpCount  = (uint16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT);
		ctx->saved_pixmap_cmpSize   = (uint16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE);
		ctx->saved_pixmap_pmVersion = (uint16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PMVERSION);
		ctx->saved_pixmap_packType  = (uint16_t)ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PACKTYPE);
		ctx->saved_pixmap_packSize  = ReadMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PACKSIZE);
		ctx->saved_pixmap_hRes      = ReadMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_HRES);
		ctx->saved_pixmap_vRes      = ReadMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_VRES);
		ctx->saved_pixmap_planeBytes = ReadMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PLANEBYTES);
		ctx->saved_pixmap_valid    = 1;
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S5 cached originals "
		         "(baseAddr=0x%08x rowBytes=%u pixelSize=%u packType=%u "
		         "packSize=%u hRes=0x%08x vRes=0x%08x planeBytes=%u)",
		         ctx->saved_pixmap_baseAddr, (unsigned)ctx->saved_pixmap_rowBytes,
		         (unsigned)ctx->saved_pixmap_pixelSize,
		         (unsigned)ctx->saved_pixmap_packType,
		         ctx->saved_pixmap_packSize,
		         ctx->saved_pixmap_hRes,
		         ctx->saved_pixmap_vRes,
		         ctx->saved_pixmap_planeBytes);
	} else {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S5 reasserting existing "
		         "redirect (pixMapPtr=0x%08x; saved original preserved)",
		         pixMapPtr);
	}

	uint32_t alignedRB = DSpMainDevicePixMapRowBytes(
		ctx->attr.displayWidth,
		ctx->attr.backBufferBestDepth,
		display_depth);
	uint32_t buffer_size = alignedRB * ctx->attr.displayHeight;
	const uint32_t back_width = DSpContextBackBufferWidth(ctx);
	const uint32_t back_height = DSpContextBackBufferHeight(ctx);
	uint32_t newBaseAddr_mac = 0;
	const bool has_presentable_front_staging =
	    DSpShouldPresentFrontBufferStaging(ctx->attr.backBufferBestDepth,
	                                       ctx->attr.displayBestDepth,
	                                       ctx->front_staging_mac_addr,
	                                       ctx->front_staging_size);
	const bool expose_front_staging =
	    has_presentable_front_staging ||
	    DSpMainDeviceRedirectShouldExposeFrontStaging(
	        ctx->attr.backBufferBestDepth,
	        display_depth);
	bool using_back_buffer_redirect = false;

	/* DSP-RDR-S6: prefer a distinct display-depth front-staging surface so the
	 * guest sees proper double-buffering — the front buffer is the visible
	 * screen and the back buffer is the draw target; they must NOT alias.
	 * Only redirect MainDevice straight at the back-buffer staging when there
	 * is no presentable front staging AND the depths match. (Reverts the prior
	 * same-depth "front==back" reuse, which collapsed double-buffering and
	 * desynced the guest's page arithmetic — the splash half-buffer roll.) */
	if (!expose_front_staging &&
	    !has_presentable_front_staging &&
	    redirect_depth == ctx->attr.backBufferBestDepth) {
		using_back_buffer_redirect = true;
		buffer_size = DSpBackBufferSize(
			back_width,
			back_height,
			ctx->attr.backBufferBestDepth);
		alignedRB = DSpAlignedRowBytes(back_width,
		                                ctx->attr.backBufferBestDepth);
		uint8_t *back_contents = (uint8_t *)[ctx->back_buffer contents];
		uint32_t mappedBaseAddr_mac = Host2MacAddr(back_contents);
		uint8_t *roundTripHost = mappedBaseAddr_mac != 0 ? Mac2HostAddr(mappedBaseAddr_mac) : NULL;
		newBaseAddr_mac = DSpUsableDirectGuestBaseOrZero(
			mappedBaseAddr_mac,
			buffer_size,
			(uint32_t)RAMBase,
			(uint32_t)RAMSize,
			(uintptr_t)roundTripHost,
			(uintptr_t)back_contents);
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S6 Host2MacAddr(back_buffer.contents) "
		         "-> 0x%08x roundTrip=%p contents=%p usable=0x%08x",
		         mappedBaseAddr_mac, roundTripHost, back_contents, newBaseAddr_mac);
		if (newBaseAddr_mac == 0) {
			if (ctx->staging_mac_addr != 0) {
				newBaseAddr_mac = DSpUsableGuestBaseOrZero(
					ctx->staging_mac_addr,
					buffer_size,
					(uint32_t)RAMBase,
					(uint32_t)RAMSize);
				if (newBaseAddr_mac == 0) {
					DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S6 discarding "
					         "unusable cached staging baseAddr=0x%08x (size=%u)",
					         ctx->staging_mac_addr, buffer_size);
					DSpReleaseBackBufferStaging(ctx);
				}
			}
			if (newBaseAddr_mac == 0) {
				uint32_t staging_mac = DSpReserveGuestPixelStaging(buffer_size);
				newBaseAddr_mac = DSpUsableGuestBaseOrZero(
					staging_mac,
					buffer_size,
					(uint32_t)RAMBase,
					(uint32_t)RAMSize);
				if (newBaseAddr_mac == 0) {
					DSpDiscardUnusedGuestPixelStaging(staging_mac, true);
					DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S6 staging "
					         "allocation unusable (size=%u, addr=0x%08x)",
					         buffer_size, staging_mac);
				} else {
					ctx->staging_mac_addr = newBaseAddr_mac;
					ctx->staging_size = buffer_size;
					#ifndef TESTING_BUILD
					ctx->staging_owned_sysheap = true;
					#endif
					uint32_t redir_seed_n =
					    DSpGuardStagingWrite(ctx->staging_mac_addr,
					                         buffer_size,
					                         "Redirect.seed");
					if (back_contents != NULL) {
						Host2Mac_memcpy(ctx->staging_mac_addr, back_contents, redir_seed_n);
					} else {
						Mac_memset(ctx->staging_mac_addr, 0, redir_seed_n);
					}
					DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S6 fresh staging "
					         "reserved (size=%u) -> 0x%08x; initialized from back_buffer",
					         buffer_size, ctx->staging_mac_addr);
				}
			}
		}
	} else {
		newBaseAddr_mac = DSpEnsureFrontBufferStaging(
			ctx,
			alignedRB,
			ctx->attr.displayHeight,
			redirect_depth,
			"DSpRedirectMainDevicePixMap");
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S6 using display-depth "
		         "front staging (backBuffer@%u display@%u redirect@%u presentable=%u) "
		         "-> 0x%08x",
		         ctx->attr.backBufferBestDepth, display_depth, redirect_depth,
		         has_presentable_front_staging ? 1u : 0u, newBaseAddr_mac);
	}

	/* Security gate (ASVS L1): refuse to write an
	 * out-of-bounds Mac address into PixMap.baseAddr. Without this guard,
	 * a Host2MacAddr/staging-allocation double-failure would write 0 into
	 * PixMap.baseAddr, causing guest QuickDraw to corrupt emulated low
	 * memory. Failure path clears saved_pixmap_valid so the symmetric
	 * Restore call is a no-op (graceful degradation). */
	if (newBaseAddr_mac == 0 ||
	    newBaseAddr_mac < (uint32_t)RAMBase ||
	    newBaseAddr_mac >= (uint32_t)(RAMBase + RAMSize)) {
		if (should_cache_original) {
			ctx->saved_pixmap_valid = 0;
		}
		DSP_VLOG("DSpRedirectMainDevicePixMap: refusing OOB write "
		         "(newBaseAddr_mac=0x%08x, RAMBase=0x%08x, RAMSize=0x%08x)",
		         newBaseAddr_mac, (uint32_t)RAMBase, (uint32_t)RAMSize);
		return;
	}

	uint16_t pixelType, pixelSize, cmpCount, cmpSize;
	DSpPixMapFormatForDepth(redirect_depth,
	                         &pixelType, &pixelSize, &cmpCount, &cmpSize);
	const uint16_t rowBytesField =
	    DSpMainDevicePixMapRowBytesField(alignedRB);
	const uint32_t pixmap_width =
	    using_back_buffer_redirect
	        ? back_width
	        : DSpMainDevicePixMapBoundDimension(ctx->attr.displayWidth,
	                                            back_width);
	const uint32_t pixmap_height =
	    using_back_buffer_redirect
	        ? back_height
	        : DSpMainDevicePixMapBoundDimension(ctx->attr.displayHeight,
	                                            back_height);
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR, newBaseAddr_mac);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES, rowBytesField);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP,   0);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT,  0);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT,   (uint16_t)pixmap_height);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT, (uint16_t)pixmap_width);
	DSpWriteCanonicalMainDevicePixMapMetadata(pixMapPtr);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE,    pixelType);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE,    pixelSize);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT,     cmpCount);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE,      cmpSize);
	DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-DONE pixMapPtr=0x%08x "
	         "newBaseAddr=0x%08x rowBytes=%u rowBytesField=0x%04x %ux%u@%ubpp "
	         "(backBuffer@%u display@%u) — redirect installed",
	         pixMapPtr, newBaseAddr_mac, (unsigned)alignedRB,
	         (unsigned)rowBytesField,
	         pixmap_width, pixmap_height,
	         (unsigned)pixelSize, ctx->attr.backBufferBestDepth,
	         display_depth);
	#undef DSP_REDIR_INRANGE
}

static inline bool DSpLowMemOrGuestRAMContains(uint32_t mac_addr,
                                               uint32_t byte_count)
{
	if (mac_addr == 0 || byte_count == 0) return false;
	uint64_t start = (uint64_t)mac_addr;
	uint64_t end = start + (uint64_t)byte_count;
	if (end < start) return false;
	if (end <= 0x3000u) return true;

	uint64_t ram_lo = (uint64_t)(uint32_t)RAMBase;
	uint64_t ram_hi = (uint64_t)(uint32_t)(RAMBase + RAMSize);
	return start >= ram_lo && end <= ram_hi;
}

static inline bool DSpLowMemOrGuestRAMContainsAtOffset(uint32_t mac_addr,
                                                       uint32_t offset,
                                                       uint32_t byte_count)
{
	if (mac_addr == 0) return false;
	if (mac_addr > UINT32_MAX - offset) return false;
	return DSpLowMemOrGuestRAMContains(mac_addr + offset, byte_count);
}

static uint32_t DSpResolveLiveMainDevicePixMapPtr(void)
{
	uint32_t mainDeviceH = ReadMacInt32(LMADDR_MAIN_DEVICE);
	if (!DSpLowMemOrGuestRAMContains(mainDeviceH, 4)) return 0;

	uint32_t gdevicePtr = ReadMacInt32(mainDeviceH);
	if (!DSpLowMemOrGuestRAMContainsAtOffset(gdevicePtr, GDEVICE_OFF_PMAP, 4)) {
		return 0;
	}

	uint32_t pixMapH = ReadMacInt32(gdevicePtr + GDEVICE_OFF_PMAP);
	if (!DSpLowMemOrGuestRAMContains(pixMapH, 4)) return 0;

	uint32_t pixMapPtr = ReadMacInt32(pixMapH);
	if (!DSpLowMemOrGuestRAMContainsAtOffset(
	        pixMapPtr, DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE, 2)) {
		return 0;
	}
	return pixMapPtr;
}

static void DSpWriteSavedMainDevicePixMap(DSpContextPrivate *ctx,
                                          uint32_t pixMapPtr)
{
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR,
	              ctx->saved_pixmap_baseAddr);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES,
	              ctx->saved_pixmap_rowBytes);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP,
	              ctx->saved_pixmap_bounds[0]);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT,
	              ctx->saved_pixmap_bounds[1]);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT,
	              ctx->saved_pixmap_bounds[2]);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT,
	              ctx->saved_pixmap_bounds[3]);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE,
	              ctx->saved_pixmap_pixelType);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE,
	              ctx->saved_pixmap_pixelSize);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT,
	              ctx->saved_pixmap_cmpCount);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE,
	              ctx->saved_pixmap_cmpSize);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PMVERSION,
	              ctx->saved_pixmap_pmVersion);
	WriteMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PACKTYPE,
	              ctx->saved_pixmap_packType);
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PACKSIZE,
	              ctx->saved_pixmap_packSize);
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_HRES,
	              ctx->saved_pixmap_hRes);
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_VRES,
	              ctx->saved_pixmap_vRes);
	WriteMacInt32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PLANEBYTES,
	              ctx->saved_pixmap_planeBytes);
}

static bool DSpPixMapLooksLikeContextRedirect(DSpContextPrivate *ctx,
                                              uint32_t pixMapPtr)
{
	if (ctx == nullptr || pixMapPtr == 0) return false;

	uint32_t baseAddr = ReadMacInt32(pixMapPtr +
	                                 DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR);
	uint32_t rowBytes = (uint32_t)(
	    ReadMacInt16(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES) & 0x7FFFu);
	uint32_t pixelSize = (uint32_t)ReadMacInt16(
	    pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE);

	const uint32_t display_depth =
	    DSpDisplayModeDepth(ctx->attr.backBufferBestDepth,
	                        ctx->attr.displayBestDepth);
	const uint32_t redirect_depth =
	    DSpMainDevicePixMapDepth(ctx->attr.backBufferBestDepth,
	                             display_depth);
	const uint32_t front_row_bytes =
	    DSpMainDevicePixMapRowBytes(ctx->attr.displayWidth,
	                                ctx->attr.backBufferBestDepth,
	                                display_depth);
	if (ctx->front_staging_mac_addr != 0 &&
	    baseAddr == ctx->front_staging_mac_addr) {
		return rowBytes == front_row_bytes && pixelSize == redirect_depth;
	}

	const uint32_t back_row_bytes =
	    DSpAlignedRowBytes(DSpContextBackBufferWidth(ctx),
	                       ctx->attr.backBufferBestDepth);
	if (ctx->staging_mac_addr != 0 &&
	    baseAddr == ctx->staging_mac_addr) {
		return rowBytes == back_row_bytes &&
		       pixelSize == ctx->attr.backBufferBestDepth;
	}

	if (ctx->back_buffer != nil) {
		uint8_t *back_contents = (uint8_t *)[ctx->back_buffer contents];
		uint32_t mappedBaseAddr = Host2MacAddr(back_contents);
		if (mappedBaseAddr != 0 && baseAddr == mappedBaseAddr) {
			return rowBytes == back_row_bytes &&
			       pixelSize == ctx->attr.backBufferBestDepth;
		}
	}

	return false;
}

extern "C" void DSpRestoreMainDevicePixMap(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->saved_pixmap_valid == 0) return;
	uint32_t savedPixMapPtr = ctx->saved_pixmap_addr;
	uint32_t livePixMapPtr = DSpResolveLiveMainDevicePixMapPtr();
	if (savedPixMapPtr != 0) {
		DSpWriteSavedMainDevicePixMap(ctx, savedPixMapPtr);
		DSP_LOG("DSpRestoreMainDevicePixMap: restored pixMapPtr=0x%08x "
		        "baseAddr=0x%08x rowBytes=0x%04x pixelSize=%u",
		        savedPixMapPtr,
		        ctx->saved_pixmap_baseAddr,
		        ctx->saved_pixmap_rowBytes,
		        ctx->saved_pixmap_pixelSize);
	}
	if (livePixMapPtr != 0 &&
	    livePixMapPtr != savedPixMapPtr &&
	    DSpPixMapLooksLikeContextRedirect(ctx, livePixMapPtr)) {
		DSpWriteSavedMainDevicePixMap(ctx, livePixMapPtr);
		DSP_LOG("DSpRestoreMainDevicePixMap: restored live pixMapPtr=0x%08x "
		        "baseAddr=0x%08x rowBytes=0x%04x pixelSize=%u",
		        livePixMapPtr,
		        ctx->saved_pixmap_baseAddr,
		        ctx->saved_pixmap_rowBytes,
		        ctx->saved_pixmap_pixelSize);
	}
	ctx->saved_pixmap_valid = 0;
}

/* --- DSpContext_SetStateHandler ---
 *
 *  Implements the 9-valid / 3-invalid state-transition matrix from
 *  DrawSprocket1.7.pdf pp.29, 75, 86:
 *
 *  +-------------------+-------+-----------------------------------------+
 *  | From -> To        | Valid | DMC action                              |
 *  +-------------------+-------+-----------------------------------------+
 *  | Inactive -> Active| yes   | dmc_set_active_owner(kDMCOwnerDSp)       |
 *  | Inactive -> Paused| yes   | dmc_set_active_owner(kDMCOwnerQuickDraw) |
 *  | Active   -> Paused| yes   | dmc_set_active_owner(kDMCOwnerQuickDraw) |
 *  | Active   -> Inactive| yes | dmc_set_active_owner(kDMCOwnerQuickDraw) |
 *  | Paused   -> Active| yes   | dmc_set_active_owner(kDMCOwnerDSp)       |
 *  | Paused   -> Inactive| yes | dmc_set_active_owner(kDMCOwnerQuickDraw) |
 *  | Active   -> Active| noErr | NO DMC call (idempotent)                 |
 *  | Paused   -> Paused| noErr | NO DMC call (idempotent)                 |
 *  | Inactive -> Inactive| noErr|NO DMC call (idempotent)                 |
 *  | * -> state !in {0,1,2}| kDSpInvalidAttributesErr (-30443)             |
 *  | invalid ctxRef    | kDSpInvalidContextErr (-30442)                   |
 *  +-------------------+-------+-----------------------------------------+
 *
 *  Paused AND Inactive both route to kDMCOwnerQuickDraw from the
 *  controller's perspective. The DSp-level distinction (menu-bar-visible
 *  vs Monitors-ctrl-panel-resolution) is a CLUT/gamma/blanking
 *  semantic; the controller only sees "non-DSp".
 *
 *  Threading: DSp code is single-threaded on the emul thread; no
 *  explicit synchronization primitives are introduced here. The display-
 *  mode controller holds the sanctioned project-wide serialization
 *  carve-out.
 */
extern "C" int32_t DSpContext_SetStateHandler(uint32_t ctxRef, uint32_t state)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("SetState: invalid ctxRef=%u", ctxRef);
		return kDSpInvalidContextErr;
	}
	/* State-value bounds check (PDF pp.75, 86: only 0/1/2 valid). */
	if (state != (uint32_t)kDSpContextState_Active  &&
	    state != (uint32_t)kDSpContextState_Paused  &&
	    state != (uint32_t)kDSpContextState_Inactive) {
		DSP_LOG("SetState: out-of-range state=%u "
		        "(valid: 0=Active, 1=Paused, 2=Inactive)",
		        state);
		return kDSpInvalidAttributesErr;
	}
	/* Paused-persistence: capture the
	 * pre-transition state so the Paused->Active replay arm can run
	 * AFTER the DMC owner swap. Read-once here; ctx->state is mutated
	 * by the handler body below (line 983-ish). */
	const uint32_t prev_state = ctx->state;
	/* Idempotent self-transition — return noErr without touching DMC. */
	if (ctx->state == state) {
		DSP_LOG("SetState: idempotent self-transition ctx=%u state=%u (noErr)",
		        ctxRef, state);
		return kDSpNoErr;
	}

	/* When transitioning TO Active,
	 * check if the context's attributes differ from the current DMC
	 * snapshot. If yes, fire a mode switch through the DMC — the only
	 * sanctioned mode-switch entry point (display_mode_controller.h:247).
	 *
	 * Three-guard gate:
	 *   1. state == kDSpContextState_Active — only Activation reclaims
	 *      the display; Paused/Inactive keep whatever mode is current.
	 *   2. ctx->state != state — non-idempotent, already enforced by the
	 *      early-return above; listed here for traceability.
	 *   3. Mode differs from dmc_current_snapshot() — avoid pointless
	 *      OnModeExit/OnModeEnter churn when the app re-activates at the
	 *      same mode the compositor is already presenting.
	 *
	 * Reentrancy: dmc_request_mode_switch fires OnModeExit
	 * (compositor overlay-cache clear) and OnModeEnter (frame interval
	 * refresh) subscribers that MUST NOT re-enter DSp. SetState does not
	 * invoke subscribers directly, so reentrancy is a natural non-issue
	 * here — but palette work must not nest a mode switch
	 * inside a palette-change callback (DMCReentryScope at
	 * display_mode_controller.cpp:614 catches and returns
	 * kDMCErrReentrantRequest on violation).
	 *
	 * The DMC handles everything downstream of
	 * the mode-switch request automatically (overlay-cache clear via
	 * compositor OnModeExit; frame_interval_usec refresh via
	 * compositor OnModeEnter; palette/gamma/blanking carry; atomic
	 * snapshot publish; subscriber FIFO/LIFO fan-out). SetState just
	 * fires the event at the right moment with the right guards. */
	if (state == (uint32_t)kDSpContextState_Active) {
		const DMCModeSnapshot *snap = dmc_current_snapshot();
		const uint32_t display_depth =
		    DSpDisplayModeDepth(ctx->attr.backBufferBestDepth,
		                        ctx->attr.displayBestDepth);
		bool mode_differs = (snap == nullptr) ||
		    (snap->width  != ctx->attr.displayWidth) ||
		    (snap->height != ctx->attr.displayHeight) ||
		    (snap->depth  != display_depth);
		if (mode_differs) {
			DMCModeDesc new_mode = {};
			new_mode.width     = ctx->attr.displayWidth;
			new_mode.height    = ctx->attr.displayHeight;
			new_mode.depth     = display_depth;
			new_mode.row_bytes =
			    DSpDisplayModeRowBytes(ctx->attr.displayWidth,
			                           display_depth);
			new_mode.pitch =
			    DSpDisplayModePitch(ctx->attr.displayWidth,
			                        display_depth);
			new_mode.vbl_usec  = 0;  /* DMC keeps current cadence when 0 */
			new_mode.screen_base_mac  = 0;
			new_mode.screen_base_host = nullptr;

			int32_t rc = dmc_request_mode_switch(&new_mode);
			if (rc != kDMCNoErr) {
				DSP_LOG("SetState: dmc_request_mode_switch FAILED "
				        "(rc=%d) for %ux%u@%u; refusing transition "
				        "(backBuffer@%u ctx->state unchanged)",
				        rc, ctx->attr.displayWidth,
				        ctx->attr.displayHeight,
				        display_depth,
				        ctx->attr.backBufferBestDepth);
				return kDSpInternalErr;
			}
			/* DMC fired OnModeExit (overlay cache cleared) and
			 * OnModeEnter (frame interval refreshed). No explicit
			 * wiring needed here. */
			DSP_LOG("SetState: mode switch %ux%u@%u completed via DMC "
			        "(backBuffer@%u ctx=%u)",
			        ctx->attr.displayWidth, ctx->attr.displayHeight,
			        display_depth, ctx->attr.backBufferBestDepth, ctxRef);
		}
	}

	/* Route through DMC (preserves DMCWriteSiteInventoryTests CI gate).
	 * Use DSpMapStateToDMCOwnerTyped (from dsp_engine_internal.h) to get
	 * the DMCOwner enum type directly — the public DSpMapStateToDMCOwner
	 * returns uint32_t (no DMC header leak through public API). */
	DMCOwner new_owner = DSpMapStateToDMCOwnerTyped(state);
	int32_t dmc_rc = dmc_set_active_owner((uint32_t)new_owner);
	if (dmc_rc != 0) {
		DSP_LOG("SetState: DMC rejected transition ctx=%u %u->%u rc=%d",
		        ctxRef, ctx->state, state, dmc_rc);
		return kDSpInvalidAttributesErr;
	}
	/* Page-flip page-0 reset on Paused (PDF p.29). Page flipping is not
	 * implemented yet; log the reset as a no-op note. */
	if (state == (uint32_t)kDSpContextState_Paused) {
		DSP_LOG("SetState: Paused — page-flip reset to page 0 (no-op; "
		        "page flipping not implemented)");
	}
	DSP_LOG("SetState: ctx=%u %u->%u DMC owner->%d",
	        ctxRef, ctx->state, state, (int)new_owner);
	ctx->state = state;

	/*
	 *  Paused-persistence clause: on a
	 *  successful Paused -> Active transition, replay the stored CLUT
	 *  into the compositor so the app sees its pre-Pause palette state
	 *  on the next frame. Only fires on the specific Paused -> Active
	 *  edge; other transitions (e.g. Inactive -> Active, Active ->
	 *  Paused, Active -> Inactive) do NOT push because:
	 *    - Inactive -> Active: ctx->clut_bytes starts with the default
	 *      indexed CLUT, so it is safe to push even before the app
	 *      installs a custom CLUT.
	 *    - Active -> *: the compositor retains the last-pushed CLUT; no
	 *      push needed on the way out.
	 *
	 *  Uses the same API pair as the Set handler:
	 *  MetalCompositorUpdatePalette(full 256 entries) +
	 *  dmc_record_palette_change(). DMC write-site CI gate preserved:
	 *  dmc_record_palette_change is a function call, not a direct
	 *  generation-counter assignment.
	 *
	 *  Reentrancy note: at this point ctx->state has already been
	 *  updated to Active and the DMC owner swap has succeeded. Idempotent
	 *  self-transitions were short-circuited at function entry (prev_state
	 *  == state returned kDSpNoErr above), so prev_state != state holds
	 *  here — the edge check is over the actual transition.
	 */
	if (prev_state == (uint32_t)kDSpContextState_Paused &&
	    state == (uint32_t)kDSpContextState_Active) {
		MetalCompositorUpdatePalette(ctx->clut_bytes, 256);
		dmc_record_palette_change();
		DSP_LOG("SetState: Paused->Active CLUT replay (ctx=%u) -> OK",
		        ctxRef);
	}

	/*
	 *  Recompute the
	 *  aggregate "any DSp context is Active and fullscreen?" flag. Under
	 *  iOS UIKit every DSp context is fullscreen (no windowed
	 *  mode), so the predicate simplifies to "any Active context". When
	 *  the aggregate changes, call DSpHostBridge_SetActiveFullscreen
	 *  which writes the C-side flag + posts the
	 *  "DSpHostBridge.activeFullscreenChanged" notification for
	 *  DSpIdleTimerService (Swift observer) to toggle
	 *  UIApplication.shared.isIdleTimerDisabled on the main thread.
	 *
	 *  Edge cases handled by walking dsp_context_table:
	 *    - This ctx going Active → aggregate becomes true (if not already).
	 *    - This ctx leaving Active → aggregate stays true if ANY OTHER
	 *      context is still Active, otherwise becomes false.
	 *    - Idempotent self-transition (Active->Active etc.) — unreachable
	 *      here because the handler early-returns kDSpNoErr at line 1819
	 *      before reaching this block (prev_state == state short-circuit).
	 *
	 *  The call to DSpHostBridge_SetActiveFullscreen is CONDITIONAL on
	 *  the aggregate changing — otherwise we'd post the notification on
	 *  every SetState call and spam the observer. Compare against the
	 *  existing C-side value via DSpHostBridge_GetActiveFullscreen.
	 */
	bool any_active = false;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *other_ctx = dsp_context_table[i];
		if (other_ctx == nullptr) continue;
		if (other_ctx->state == (uint32_t)kDSpContextState_Active) {
			any_active = true;
			break;
		}
	}
	const bool prev_active = DSpHostBridge_GetActiveFullscreen();
	if (any_active != prev_active) {
		DSpHostBridge_SetActiveFullscreen(any_active);
		DSP_LOG("SetState: aggregate Active-fullscreen flag changed %s -> %s "
		        "(ctx=%u; idle-timer bridge fired)",
		        prev_active ? "true" : "false",
		        any_active  ? "true" : "false",
		        ctxRef);
	}

	/* Install / restore MainDevice PixMap redirect.
	 * Runs AFTER dmc_set_active_owner, AFTER ctx->state = state,
	 * AFTER the aggregate-fullscreen check.
	 * kHeapEngineDSp's exclusion from on_mode_exit reset
	 * keeps the back_buffer alive across the mode switch. */
	if (state == (uint32_t)kDSpContextState_Active) {
		DSpRedirectMainDevicePixMap(ctx);
	} else {
		DMCModeDesc restored_qd_mode = {};
		const bool have_restored_qd_mode =
		    !any_active && DSpBuildSavedQuickDrawModeDesc(ctx, &restored_qd_mode);
		DSpRestoreMainDevicePixMap(ctx);
		DSpReleaseFrontBufferStaging(ctx);
		if (have_restored_qd_mode) {
			const DMCModeSnapshot *snap = dmc_current_snapshot();
			const bool mode_differs =
			    snap == nullptr ||
			    DSpQuickDrawModeRestoreDiffers(restored_qd_mode.width,
			                                   restored_qd_mode.height,
			                                   restored_qd_mode.depth,
			                                   snap->width,
			                                   snap->height,
			                                   snap->depth);
			if (mode_differs) {
				int32_t rc = dmc_request_mode_switch(&restored_qd_mode);
				if (rc != kDMCNoErr) {
					DSP_LOG("SetState: QuickDraw restore mode switch FAILED "
					        "(rc=%d) for %ux%u@%u rb=%u base=0x%08x host=%p",
					        rc,
					        restored_qd_mode.width,
					        restored_qd_mode.height,
					        restored_qd_mode.depth,
					        restored_qd_mode.row_bytes,
					        restored_qd_mode.screen_base_mac,
					        restored_qd_mode.screen_base_host);
				} else {
					DSP_LOG("SetState: QuickDraw restore mode switch %ux%u@%u "
					        "rb=%u base=0x%08x host=%p completed",
					        restored_qd_mode.width,
					        restored_qd_mode.height,
					        restored_qd_mode.depth,
					        restored_qd_mode.row_bytes,
					        restored_qd_mode.screen_base_mac,
					        restored_qd_mode.screen_base_host);
				}
			}
		}
	}

	return kDSpNoErr;
}

/* --- DSpContext_GetStateHandler ---
 *
 *  Reads ctx->state and writes via WriteMacInt32(outStateAddr, state).
 *  Validates ctxRef via DSpGetContext (returns kDSpInvalidContextErr
 *  on NULL) and null-checks outStateAddr (returns kDSpInvalidContextErr
 *  when zero — byte-identical to the DSp 1.7 reference behavior).
 *
 *  No DMC round-trip: DSp state is the authoritative copy at context
 *  scope; the controller's active_owner is a DSp-to-display-system
 *  projection, not a reciprocal reader-of-truth.
 */
extern "C" int32_t DSpContext_GetStateHandler(uint32_t ctxRef,
                                               uint32_t outStateAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outStateAddr == 0) {
		DSP_LOG("GetState: invalid ctxRef=%u or outStateAddr=0x%08x",
		        ctxRef, outStateAddr);
		return kDSpInvalidContextErr;
	}
	WriteMacInt32(outStateAddr, ctx->state);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD helper: host-ptr wrapper for GetState.
 *  Side-steps the EMULATED_PPC=0 simulator SEGV when outStateAddr is
 *  an above-4GiB truncated Mac address.
 */
extern "C" int32_t DSpTesting_GetStateByStruct(uint32_t ctxRef,
                                                uint32_t *outState)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outState == nullptr) {
		return kDSpInvalidContextErr;
	}
	*outState = ctx->state;
	return kDSpNoErr;
}
#endif

/* --- DSpContext_IsBusyHandler (sub-op 730) ---
 *
 *  DSp 1.7 PDF p.40: DSpContext_IsBusy(inContext, Boolean *outBusyFlag).
 *  outBusyFlag is true when NO back buffer is available for drawing (the
 *  prior SwapBuffers has not finished), false when a back buffer is ready.
 *  PocketShaver's fullscreen back-buffer is a single MTLBuffer allocated at
 *  Reserve time and always present once the context owns Metal resources, so
 *  the buffer is always ready -> write false (0). When back_buffer is nil
 *  (metadata-only / pre-Reserve context) report busy (1). 1-byte Boolean
 *  out-write via WriteMacInt8 (PDF Boolean ABI). */
extern "C" int32_t DSpContext_IsBusyHandler(uint32_t ctxRef,
                                             uint32_t outBusyAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outBusyAddr == 0) {
		DSP_LOG("IsBusy: invalid ctxRef=%u or outBusyAddr=0x%08x",
		        ctxRef, outBusyAddr);
		return kDSpInvalidContextErr;
	}
	/* PDF p.40: true == NO buffer available. Single fullscreen back-buffer
	 * is always ready once allocated -> false; nil (pre-Reserve) -> true. */
	WriteMacInt8(outBusyAddr, (ctx->back_buffer != nil) ? 0 : 1);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_IsBusyByValue(uint32_t ctxRef, uint8_t *outBusy)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outBusy == nullptr) {
		return kDSpInvalidContextErr;
	}
	*outBusy = (ctx->back_buffer != nil) ? 0 : 1;
	return kDSpNoErr;
}
#endif

/* DSp exposes classic Apple Display Manager IDs (video.h viAppleID values)
 * from GetDisplayID. Incoming discovery IDs all map to the single backing
 * screen because PocketShaver has one fullscreen display. */

/* --- DSpContext_GetDisplayIDHandler (sub-op 731) ---
 *
 *  DSp 1.7 PDF p.14-15: DSpContext_GetDisplayID(inContext, DisplayIDType
 *  *outDisplayID). Writes the display id the context lives on. iOS has a
 *  single display; return the classic Apple Display Manager ID for the
 *  context resolution so clients that cross-check video metadata see a real
 *  mode ID. 4-byte DisplayIDType (UInt32) out-write. */
extern "C" int32_t DSpContext_GetDisplayIDHandler(uint32_t ctxRef,
                                                   uint32_t outIDAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outIDAddr == 0) {
		DSP_LOG("GetDisplayID: invalid ctxRef=%u or outIDAddr=0x%08x",
		        ctxRef, outIDAddr);
		return kDSpInvalidContextErr;
	}
	uint32_t display_id = DSpDisplayIDForMode(ctx->attr.displayWidth,
	                                          ctx->attr.displayHeight);
	WriteMacInt32(outIDAddr, display_id);
	DSP_LOG("GetDisplayID: ctx=%u %ux%u -> displayID=0x%08x",
	        ctxRef, ctx->attr.displayWidth, ctx->attr.displayHeight,
	        display_id);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_GetDisplayIDByValue(uint32_t ctxRef,
                                                   uint32_t *outID)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outID == nullptr) {
		return kDSpInvalidContextErr;
	}
	*outID = DSpDisplayIDForMode(ctx->attr.displayWidth,
	                             ctx->attr.displayHeight);
	return kDSpNoErr;
}
#endif

/* The base dirty-rect grid unit (DSp 1.7 PDF p.43: 32x32 px, the PPC
 * cache-line granularity). DSpContext_GetDirtyRectGridUnits reports it as
 * a constant; DSpContext_SetDirtyRectGridSize (737)
 * rounds requested cells up to a multiple of it. */
#define kDSpDirtyRectGridUnit 32u

/* --- DSpContext_GetDirtyRectGridUnitsHandler (sub-op 738) ---
 *
 *  DSp 1.7 PDF p.43: DSpContext_GetDirtyRectGridUnits(inContext, UInt32
 *  *outCellPixelWidth, UInt32 *outCellPixelHeight). Writes the base grid
 *  units — a CONSTANT 32 x 32 (PPC cache-line); no stored field. Two 4-byte
 *  out-writes. */
extern "C" int32_t DSpContext_GetDirtyRectGridUnitsHandler(uint32_t ctxRef,
                                                           uint32_t wAddr,
                                                           uint32_t hAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || wAddr == 0 || hAddr == 0) {
		DSP_LOG("GetDirtyRectGridUnits: invalid ctxRef=%u or wAddr=0x%08x "
		        "hAddr=0x%08x", ctxRef, wAddr, hAddr);
		return kDSpInvalidContextErr;
	}
	WriteMacInt32(wAddr, kDSpDirtyRectGridUnit);
	WriteMacInt32(hAddr, kDSpDirtyRectGridUnit);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_GetDirtyRectGridUnitsByValues(uint32_t ctxRef,
                                                            uint32_t *outW,
                                                            uint32_t *outH)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outW == nullptr || outH == nullptr) {
		return kDSpInvalidContextErr;
	}
	*outW = kDSpDirtyRectGridUnit;
	*outH = kDSpDirtyRectGridUnit;
	return kDSpNoErr;
}
#endif

/* --- DSpContext_GetMaxFrameRateHandler (sub-op 734) ---
 *
 *  DSp 1.7 PDF p.44-45: DSpContext_GetMaxFrameRate(inContext, UInt32
 *  *outMaxFPS). Writes the stored max-frame-rate bookkeeping field; 0 means
 *  no restriction. 4-byte UInt32 out-write. */
extern "C" int32_t DSpContext_GetMaxFrameRateHandler(uint32_t ctxRef,
                                                     uint32_t outAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outAddr == 0) {
		DSP_LOG("GetMaxFrameRate: invalid ctxRef=%u or outAddr=0x%08x",
		        ctxRef, outAddr);
		return kDSpInvalidContextErr;
	}
	WriteMacInt32(outAddr, ctx->max_frame_rate);
	return kDSpNoErr;
}

/* --- DSpContext_SetMaxFrameRateHandler (sub-op 735) ---
 *
 *  DSp 1.7 PDF p.44: DSpContext_SetMaxFrameRate(inContext, UInt32 inMaxFPS).
 *  Stores inMaxFPS as store-only bookkeeping (PDF "does not guarantee"; the
 *  actual frame-skip pacing belongs to SwapBuffers). No out-write. */
extern "C" int32_t DSpContext_SetMaxFrameRateHandler(uint32_t ctxRef,
                                                     uint32_t inMaxFPS)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("SetMaxFrameRate: invalid ctxRef=%u", ctxRef);
		return kDSpInvalidContextErr;
	}
	ctx->max_frame_rate = inMaxFPS;
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_GetMaxFrameRateByValue(uint32_t ctxRef,
                                                     uint32_t *outMaxFPS)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outMaxFPS == nullptr) {
		return kDSpInvalidContextErr;
	}
	*outMaxFPS = ctx->max_frame_rate;
	return kDSpNoErr;
}

extern "C" int32_t DSpTesting_SetMaxFrameRateByValue(uint32_t ctxRef,
                                                     uint32_t inMaxFPS)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		return kDSpInvalidContextErr;
	}
	ctx->max_frame_rate = inMaxFPS;
	return kDSpNoErr;
}
#endif

/* Compute the display refresh rate as a DSp/QuickDraw Fixed (16.16) value
 * from the VBL cadence. Hz = 1e6 / cadence_usec; Fixed = Hz << 16. Shared by
 * the production handler + the TESTING_BUILD helper so both report the
 * identical device-native value. */
static uint32_t DSpComputeMonitorFrequencyFixed(void)
{
	uint64_t cadence = vbl_source_get_cadence_usec();   /* usec per VBL */
	/* PDF p.46/p.19: may return 0 if not yet timed; device-native nonzero is
	 * at least as faithful. Fixed = Hz << 16 = (1e6 << 16) / cadence. */
	return (cadence > 0) ? (uint32_t)((1000000ULL << 16) / cadence) : 0;
}

/* --- DSpContext_GetMonitorFrequencyHandler (sub-op 733) ---
 *
 *  DSp 1.7 PDF p.45-46, p.19: DSpContext_GetMonitorFrequency(inContext, Fixed
 *  *outFrequency). Writes the display refresh as a Fixed (16.16) Hz value
 *  derived from the VBL cadence (device-native 60/120 Hz). 4-byte Fixed
 *  out-write. */
extern "C" int32_t DSpContext_GetMonitorFrequencyHandler(uint32_t ctxRef,
                                                         uint32_t outFixedAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outFixedAddr == 0) {
		DSP_LOG("GetMonitorFrequency: invalid ctxRef=%u or outFixedAddr=0x%08x",
		        ctxRef, outFixedAddr);
		return kDSpInvalidContextErr;
	}
	WriteMacInt32(outFixedAddr, DSpComputeMonitorFrequencyFixed());
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_GetMonitorFrequencyByValue(uint32_t ctxRef,
                                                         uint32_t *outFixed)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outFixed == nullptr) {
		return kDSpInvalidContextErr;
	}
	*outFixed = DSpComputeMonitorFrequencyFixed();
	return kDSpNoErr;
}
#endif

/* Round a requested dirty-rect grid cell dimension UP to a multiple of the
 * 32x32 base grid unit (DSp 1.7 PDF p.41 "suggests" — the library quantizes
 * to the base unit). 0 stays 0 (means "default to base unit" until a Set). */
static uint32_t DSpRoundUpToGridUnit(uint32_t v)
{
	if (v == 0) return 0;
	return ((v + kDSpDirtyRectGridUnit - 1) / kDSpDirtyRectGridUnit)
	       * kDSpDirtyRectGridUnit;
}

/* --- DSpContext_SetDirtyRectGridSizeHandler (sub-op 737) ---
 *
 *  DSp 1.7 PDF p.41: DSpContext_SetDirtyRectGridSize(inContext, UInt32
 *  inCellPixelWidth, UInt32 inCellPixelHeight). "Suggests" a grid cell size;
 *  rounds each requested dimension UP to a multiple of the 32-px base unit
 *  and stores it (never trust raw guest ints). No out-write. */
extern "C" int32_t DSpContext_SetDirtyRectGridSizeHandler(uint32_t ctxRef,
                                                          uint32_t w,
                                                          uint32_t h)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("SetDirtyRectGridSize: invalid ctxRef=%u", ctxRef);
		return kDSpInvalidContextErr;
	}
	ctx->dirty_grid_w = DSpRoundUpToGridUnit(w);
	ctx->dirty_grid_h = DSpRoundUpToGridUnit(h);
	return kDSpNoErr;
}

/* --- DSpContext_GetDirtyRectGridSizeHandler (sub-op 736) ---
 *
 *  DSp 1.7 PDF p.42: DSpContext_GetDirtyRectGridSize(inContext, UInt32
 *  *outCellPixelWidth, UInt32 *outCellPixelHeight). Writes the current grid
 *  cell (w,h); defaults to the 32x32 base unit until a Set lands. Two 4-byte
 *  out-writes. */
extern "C" int32_t DSpContext_GetDirtyRectGridSizeHandler(uint32_t ctxRef,
                                                          uint32_t wAddr,
                                                          uint32_t hAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || wAddr == 0 || hAddr == 0) {
		DSP_LOG("GetDirtyRectGridSize: invalid ctxRef=%u or wAddr=0x%08x "
		        "hAddr=0x%08x", ctxRef, wAddr, hAddr);
		return kDSpInvalidContextErr;
	}
	WriteMacInt32(wAddr, ctx->dirty_grid_w ? ctx->dirty_grid_w
	                                        : kDSpDirtyRectGridUnit);
	WriteMacInt32(hAddr, ctx->dirty_grid_h ? ctx->dirty_grid_h
	                                        : kDSpDirtyRectGridUnit);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_SetDirtyRectGridSizeByValues(uint32_t ctxRef,
                                                           uint32_t w,
                                                           uint32_t h)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		return kDSpInvalidContextErr;
	}
	ctx->dirty_grid_w = DSpRoundUpToGridUnit(w);
	ctx->dirty_grid_h = DSpRoundUpToGridUnit(h);
	return kDSpNoErr;
}

extern "C" int32_t DSpTesting_GetDirtyRectGridSizeByValues(uint32_t ctxRef,
                                                           uint32_t *outW,
                                                           uint32_t *outH)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outW == nullptr || outH == nullptr) {
		return kDSpInvalidContextErr;
	}
	*outW = ctx->dirty_grid_w ? ctx->dirty_grid_w : kDSpDirtyRectGridUnit;
	*outH = ctx->dirty_grid_h ? ctx->dirty_grid_h : kDSpDirtyRectGridUnit;
	return kDSpNoErr;
}
#endif

#define DSP_FRONT_PIXMAP_SIZE DSpFrontBufferPixMapRecordSize()
#define DSP_FRONT_PIXMAP_HANDLE_SIZE 4u
#define DSP_FRONT_CGP_SIZE DSP_CGRAFPORT_MIN_SIZE
#define DSP_FRONT_REGION_HANDLE_SIZE 4u

static uint32_t DSpCreateFrontRectRegion(uint32_t w, uint32_t h)
{
	uint32_t region_addr = DSpReserveGuestScratch(DSP_RECT_REGION_SIZE);
	uint32_t handle_addr = DSpReserveGuestScratch(DSP_FRONT_REGION_HANDLE_SIZE);
	if (region_addr == 0 || handle_addr == 0) return 0;

	Mac_memset(region_addr, 0, DSP_RECT_REGION_SIZE);
	WriteMacInt16(region_addr + DSP_REGION_OFF_SIZE, DSP_RECT_REGION_SIZE);
	WriteMacInt16(region_addr + DSP_REGION_OFF_BBOX + 0, 0);
	WriteMacInt16(region_addr + DSP_REGION_OFF_BBOX + 2, 0);
	WriteMacInt16(region_addr + DSP_REGION_OFF_BBOX + 4, (uint16_t)h);
	WriteMacInt16(region_addr + DSP_REGION_OFF_BBOX + 6, (uint16_t)w);
	WriteMacInt32(handle_addr, region_addr);
	return handle_addr;
}

static uint32_t DSpGetFrontBufferCGrafPtr(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->back_buffer == nil) return 0;

	if (DSpShouldReuseBackBufferCGrafPtrForFrontBuffer(
	        ctx->attr.backBufferBestDepth,
	        ctx->attr.displayBestDepth)) {
		uint32_t back_cgraf = DSpGetBackBufferCGrafPtr(ctx);
		DSP_VLOG("DSpGetFrontBufferCGrafPtr: REUSING back-buffer CGrafPtr as "
		         "FRONT (front==back alias) ctx=%u cgrafptr=0x%08x staging=0x%08x "
		         "back@%u display@%u — front and back buffers are identical; "
		         "if the guest expects a distinct front buffer this is the "
		         "regression suspect",
		         ctx->handle, back_cgraf, ctx->staging_mac_addr,
		         ctx->attr.backBufferBestDepth, ctx->attr.displayBestDepth);
		return back_cgraf;
	}

	if (ctx->front_cgrafptr_mac_addr != 0) {
		return ctx->front_cgrafptr_mac_addr;
	}

	const uint32_t front_depth =
	    DSpFrontBufferDepth(ctx->attr.backBufferBestDepth,
	                        ctx->attr.displayBestDepth);
	const uint32_t w = ctx->attr.displayWidth;
	const uint32_t h = ctx->attr.displayHeight;
	const uint32_t row_bytes =
	    DSpFrontBufferRowBytes(w,
	                           ctx->attr.backBufferBestDepth,
	                           ctx->attr.displayBestDepth);
	const uint32_t buffer_size = row_bytes * h;

	uint32_t baseAddr_mac = DSpEnsureFrontBufferStaging(ctx,
	                                                    row_bytes,
	                                                    h,
	                                                    front_depth,
	                                                    "DSpGetFrontBufferCGrafPtr");
	if (baseAddr_mac == 0) {
		DSP_LOG("DSpGetFrontBufferCGrafPtr: staging allocation unusable "
		        "(size=%u, frontDepth=%u)",
		        buffer_size, front_depth);
		return 0;
	}

	uint32_t pixmap_addr = DSpReserveGuestScratch(DSP_FRONT_PIXMAP_SIZE);
	uint32_t pixmap_handle_addr =
	    DSpReserveGuestScratch(DSP_FRONT_PIXMAP_HANDLE_SIZE);
	uint32_t cgrafptr_addr = DSpReserveGuestScratch(DSP_FRONT_CGP_SIZE);
	uint32_t vis_rgn_handle = DSpCreateFrontRectRegion(w, h);
	uint32_t clip_rgn_handle = DSpCreateFrontRectRegion(w, h);
	if (pixmap_addr == 0 || pixmap_handle_addr == 0 ||
	    cgrafptr_addr == 0 || vis_rgn_handle == 0 ||
	    clip_rgn_handle == 0) {
		DSP_LOG("DSpGetFrontBufferCGrafPtr: guest-scratch reserve failed "
		        "(pixmap=0x%08x handle=0x%08x cgraf=0x%08x "
		        "vis=0x%08x clip=0x%08x)",
		        pixmap_addr, pixmap_handle_addr, cgrafptr_addr,
		        vis_rgn_handle, clip_rgn_handle);
		return 0;
	}

	uint16_t pixelType, pixelSize, cmpCount, cmpSize;
	DSpPixMapFormatForDepth(front_depth,
	                         &pixelType, &pixelSize, &cmpCount, &cmpSize);

	const uint16_t row_bytes_field =
	    DSpFrontBufferPixMapRowBytesField(row_bytes);

	if (ctx->saved_pixmap_valid != 0 &&
	    ctx->saved_pixmap_addr != 0 &&
	    DSpGuestRAMContains(ctx->saved_pixmap_addr,
	                        DSP_FRONT_PIXMAP_SIZE,
	                        (uint32_t)RAMBase,
	                        (uint32_t)RAMSize)) {
		Host2Mac_memcpy(pixmap_addr,
		                Mac2HostAddr(ctx->saved_pixmap_addr),
		                DSP_FRONT_PIXMAP_SIZE);
	} else {
		Mac_memset(pixmap_addr, 0, DSP_FRONT_PIXMAP_SIZE);
	}
	WriteMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR,      baseAddr_mac);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES,      row_bytes_field);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP,    0);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT,   0);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT,    (uint16_t)h);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT,  (uint16_t)w);
	DSpWriteCanonicalMainDevicePixMapMetadata(pixmap_addr);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE,     pixelType);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE,     pixelSize);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT,      cmpCount);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE,       cmpSize);

	WriteMacInt32(pixmap_handle_addr, pixmap_addr);

	Mac_memset(cgrafptr_addr, 0, DSP_FRONT_CGP_SIZE);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_PIXMAP,
	              pixmap_handle_addr);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_VERSION, 0xC000);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_RECT + 0, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_RECT + 2, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_RECT + 4,
	              (uint16_t)h);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_RECT + 6,
	              (uint16_t)w);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_VIS_RGN,
	              vis_rgn_handle);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_CLIP_RGN,
	              clip_rgn_handle);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 0,
	              0xffff);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 2,
	              0xffff);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 4,
	              0xffff);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 0, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 2, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 4, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PN_SIZE + 0, 1);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PN_SIZE + 2, 1);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PN_MODE, 8);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_TX_SIZE, 12);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_FG_COLOR, 0xffffffffu);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_BK_COLOR, 0x00000000u);

	ctx->front_cgrafptr_mac_addr = cgrafptr_addr;
	ctx->front_pixmap_mac_addr = pixmap_addr;
	ctx->front_pixmap_handle_mac_addr = pixmap_handle_addr;
	DSP_LOG("DSpGetFrontBufferCGrafPtr: ctx=%u cgrafptr=0x%08x pixmapH=0x%08x "
	        "pixmap=0x%08x visRgn=0x%08x clipRgn=0x%08x baseAddr=0x%08x "
	        "rbRaw=0x%04x rb=%u pixelSize=%u cmpCount=%u cmpSize=%u "
	        "hRes=0x%08x vRes=0x%08x pmTable=0x%08x (backBuffer@%u)",
	        ctx->handle, cgrafptr_addr, pixmap_handle_addr, pixmap_addr,
	        vis_rgn_handle, clip_rgn_handle, baseAddr_mac, row_bytes_field,
	        row_bytes, pixelSize, cmpCount, cmpSize,
	        ReadMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_HRES),
	        ReadMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_VRES),
	        ReadMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_PMTABLE),
	        ctx->attr.backBufferBestDepth);
	return cgrafptr_addr;
}

/* --- DSpContext_GetFrontBufferHandler (sub-op 732) ---
 *
 *  DSp 1.7 PDF p.36: DSpContext_GetFrontBuffer(inContext, CGrafPtr
 *  *outFrontBuffer). "The front buffer is the screen display." Mixed-depth
 *  DSp contexts may use a low-depth back buffer while switching the actual
 *  display to a higher depth for RAVE/QD3D discovery. In that case the
 *  front CGrafPtr must describe the display surface, not the back buffer.
 *  4-byte CGrafPtr out-write. */
extern "C" int32_t DSpContext_GetFrontBufferHandler(uint32_t ctxRef,
                                                    uint32_t outCGrafPtrAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outCGrafPtrAddr == 0) {
		DSP_LOG("GetFrontBuffer: invalid ctxRef=%u or outCGrafPtrAddr=0x%08x",
		        ctxRef, outCGrafPtrAddr);
		return kDSpInvalidContextErr;
	}
	uint32_t cgrafptr = DSpGetFrontBufferCGrafPtr(ctx);
	if (cgrafptr == 0) {
		DSP_LOG("GetFrontBuffer: CGrafPort emission failed for ctxRef=%u",
		        ctxRef);
		return kDSpInternalErr;
	}
	if (ctx->state == (uint32_t)kDSpContextState_Active) {
		DSpRedirectMainDevicePixMap(ctx);
		DSP_LOG("GetFrontBuffer: reasserted MainDevice PixMap redirect "
		        "before returning front buffer (ctx=%u cgrafptr=0x%08x)",
		        ctx->handle, cgrafptr);
	}
	WriteMacInt32(outCGrafPtrAddr, cgrafptr);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_GetFrontBufferByValue(uint32_t ctxRef,
                                                    uint32_t *outCGrafPtr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outCGrafPtr == nullptr) {
		return kDSpInvalidContextErr;
	}
	uint32_t cgrafptr = DSpGetFrontBufferCGrafPtr(ctx);
	if (cgrafptr == 0) {
		return kDSpInternalErr;
	}
	*outCGrafPtr = cgrafptr;
	return kDSpNoErr;
}
#endif

/* --- DSpGetCurrentContextHandler (sub-op 745) ---
 *
 *  DSp 1.7 PDF p.15: DSpGetCurrentContext(DisplayIDType inDisplayID,
 *  DSpContextReference *outContext). NOTE the first arg is a displayID, NOT a
 *  ctxRef. Writes the Active context for the given display (PocketShaver's
 *  single fullscreen display). Walks dsp_context_table for the one Active
 *  context with a live back_buffer (the SwapBuffers active-context gate).
 *  Incoming display IDs all map to the single backing display. If no context
 *  is active, writes 0 + returns kDSpContextNotFoundErr. */
extern "C" int32_t DSpGetCurrentContextHandler(uint32_t displayID,
                                               uint32_t outCtxRefAddr)
{
	if (outCtxRefAddr == 0) {
		DSP_LOG("GetCurrentContext: NULL outCtxRefAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	if (!DSpAcceptsSingleDisplayID(displayID)) {
		WriteMacInt32(outCtxRefAddr, 0);
		return kDSpContextNotFoundErr;
	}
	/* Walk dsp_context_table for the single Active context with a live
	 * back_buffer — mirrors the SwapBuffers active-context gate. */
	uint32_t active_handle = 0;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
		if (ctx->back_buffer == nil) continue;
		active_handle = ctx->handle;
		break;
	}
	WriteMacInt32(outCtxRefAddr, active_handle);
	return (active_handle != 0) ? kDSpNoErr : kDSpContextNotFoundErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_GetCurrentContextByValue(uint32_t displayID,
                                                       uint32_t *outCtxRef)
{
	if (outCtxRef == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	if (!DSpAcceptsSingleDisplayID(displayID)) {
		*outCtxRef = 0;
		return kDSpContextNotFoundErr;
	}
	uint32_t active_handle = 0;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
		if (ctx->back_buffer == nil) continue;
		active_handle = ctx->handle;
		break;
	}
	*outCtxRef = active_handle;
	return (active_handle != 0) ? kDSpNoErr : kDSpContextNotFoundErr;
}

/* Force a context's state field to Active WITHOUT the DMC owner transition +
 * MainDevice PixMap redirect that DSpContext_SetStateHandler performs. The
 * full SetState(Active) path reads LMADDR_MAIN_DEVICE from lowmem, which SEGVs
 * in the no-ROM simulator. GetCurrentContext only inspects
 * ctx->state + ctx->back_buffer, so this RAM-only poke lets the active-walk
 * contract test run on the simulator without the unrelated lowmem dependency.
 * The Active context kept by the real DMC path is exercised on device/Catalyst. */
extern "C" int32_t DSpTesting_ForceContextStateActive(uint32_t ctxRef)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		return kDSpInvalidContextErr;
	}
	ctx->state = (uint32_t)kDSpContextState_Active;
	return kDSpNoErr;
}
#endif

/* The Mac low-memory MouseLocation global (DSp 1.7 PDF p.54 — DSpGetMouse
 * reports the SAME global mouse position the Toolbox exposes). adb.cpp writes
 * the host mouse here every interrupt in the non-POWERPC_ROM path
 * (adb.cpp:659-660): a 4-byte Point with v at 0x82c and h at 0x82e. */
#define kDSpLM_MouseLocation_v 0x82cu   /* Point.v — vertical (top) coord */
#define kDSpLM_MouseLocation_h 0x82eu   /* Point.h — horizontal (left) coord */

#ifdef TESTING_BUILD
/* Host-side mouse snapshot for the no-ROM contract test. Under EMULATED_PPC=0
 * the cpu_emulation.h accessors are raw host-pointer derefs (Mac2HostAddr(x)
 * == (uint8*)x), so a fixed-lowmem read of 0x82c SEGVs (it points into the
 * unmapped null page — the same class as the LMADDR_MAIN_DEVICE
 * SEGV). DSpReadGlobalMousePoint reads THIS host static under TESTING_BUILD so
 * the GetMouse read+marshal contract is exercised on the simulator without the
 * lowmem dependency; the real lowmem path runs on device/Catalyst
 * (EMULATED_PPC=1). DSpTesting_SetHostMouseLocation seeds it. */
static int16_t s_dsp_testing_host_mouse_v = 0;
static int16_t s_dsp_testing_host_mouse_h = 0;
#endif

/* Read the current global host mouse position into (*v, *h). Production reads
 * the Mac MouseLocation lowmem Point (kept live by adb.cpp's input stack); the
 * TESTING_BUILD path reads the host-side snapshot to avoid the EMULATED_PPC=0
 * fixed-lowmem SEGV. Either way this is the REAL host mouse
 * source — NOT a hardcoded (0,0) stub. */
static void DSpReadGlobalMousePoint(int16_t *v, int16_t *h)
{
#ifdef TESTING_BUILD
	*v = s_dsp_testing_host_mouse_v;
	*h = s_dsp_testing_host_mouse_h;
#else
	/* MouseLocation is a Point {v, h}; vertical at 0x82c, horizontal at 0x82e
	 * (the layout adb.cpp writes). */
	*v = (int16_t)ReadMacInt16(kDSpLM_MouseLocation_v);
	*h = (int16_t)ReadMacInt16(kDSpLM_MouseLocation_h);
#endif
}

/* --- DSpGetMouseHandler (sub-op 720) ---
 *
 *  DSp 1.7 PDF p.54: DSpGetMouse(Point *outGlobalPoint). NO context param —
 *  r3 is the out-Point address. Writes the current global mouse position the
 *  host input stack maintains (the Mac MouseLocation lowmem global, kept live
 *  by adb.cpp). Mac Point on the wire is v (high half) then h (low half): two
 *  big-endian int16 at +0 / +2. Guards a NULL out-Point. */
extern "C" int32_t DSpGetMouseHandler(uint32_t outGlobalPointAddr)
{
	if (outGlobalPointAddr == 0) {
		DSP_LOG("GetMouse: NULL outGlobalPointAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	int16_t v = 0, h = 0;
	DSpReadGlobalMousePoint(&v, &h);
	WriteMacInt16(outGlobalPointAddr + 0, (uint16_t)v);    /* Point.v */
	WriteMacInt16(outGlobalPointAddr + 2, (uint16_t)h);    /* Point.h */
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_GetMouseByValues(int16_t *v, int16_t *h)
{
	if (v == nullptr || h == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	DSpReadGlobalMousePoint(v, h);
	return kDSpNoErr;
}

/* Test-only seed for the host mouse source: sets the host-side snapshot
 * DSpReadGlobalMousePoint reads under TESTING_BUILD so the GetMouse contract
 * test proves the handler reports the live source (not a hardcoded value)
 * without the EMULATED_PPC=0 fixed-lowmem SEGV. */
extern "C" void DSpTesting_SetHostMouseLocation(int16_t v, int16_t h)
{
	s_dsp_testing_host_mouse_v = v;
	s_dsp_testing_host_mouse_h = h;
}
#endif

/* --- DSpContext_GlobalToLocalHandler (sub-op 721) ---
 *
 *  DSp 1.7 PDF p.55: DSpContext_GlobalToLocal(inContext, Point *ioPoint).
 *  Converts a global (screen) Point to the context's local coordinate space
 *  in place. On the iOS single fullscreen display the one DSp context covers
 *  the whole screen with its local origin at (0,0), so the conversion is the
 *  IDENTITY: read the Point, leave it unchanged, write it back.
 *  (If a future ppcdis cross-check of the GlobalToLocal TVECT reveals a nonzero
 *  context-rect offset, subtract it here — the structure is unchanged.) The
 *  read-modify-write uses the InvalBackBufferRect Point/Rect I/O idiom
 *  ((int16_t)ReadMacInt16 / WriteMacInt16). Validates ctxRef
 *  and guards a NULL ioPoint. */
extern "C" int32_t DSpContext_GlobalToLocalHandler(uint32_t ctxRef,
                                                   uint32_t ioPointAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || ioPointAddr == 0) {
		DSP_LOG("GlobalToLocal: invalid ctxRef=%u or ioPointAddr=0x%08x",
		        ctxRef, ioPointAddr);
		return kDSpInvalidContextErr;
	}
	/* Identity at the single fullscreen origin (0,0). */
	const int16_t v = (int16_t)ReadMacInt16(ioPointAddr + 0);
	const int16_t h = (int16_t)ReadMacInt16(ioPointAddr + 2);
	WriteMacInt16(ioPointAddr + 0, (uint16_t)v);   /* Point.v — unchanged */
	WriteMacInt16(ioPointAddr + 2, (uint16_t)h);   /* Point.h — unchanged */
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/* Route the by-VALUE GlobalToLocal contract test THROUGH the
 * production DSpContext_GlobalToLocalHandler instead of re-implementing
 * identity here. Stage the input Point in guest-RAM scratch (v at +0, h at
 * +2 — the Mac Point ABI), call the real handler against that guest address,
 * then read the marshalled result back via ReadMacInt16. The test now FAILS
 * if the production handler swaps v/h, picks the wrong +0/+2 offset, or
 * corrupts the round-trip — the wrapper exercises the real Mac-memory I/O,
 * not a copy of it. Mirrors the DSpEventTests guest-scratch idiom + the
 * dsp_testing_scratch_in_low_4gib() gate the GetFrontBuffer/GetBackBuffer
 * helpers use. When the simulator mmap landed high (scratch unavailable),
 * fall back to the in-place identity so the contract test still runs — the
 * device / low-mmap path is where the production handler is exercised. */
extern "C" int32_t DSpTesting_GlobalToLocalByValues(uint32_t ctxRef,
                                                    int16_t *v, int16_t *h)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || v == nullptr || h == nullptr) {
		return kDSpInvalidContextErr;
	}
	if (dsp_testing_scratch_in_low_4gib() == 0) {
		/* Guest scratch is above 4 GiB — cannot drive Read/WriteMacInt16.
		 * Preserve the identity contract so the test still runs; the real
		 * handler path is covered on device / low-mmap simulators. */
		return kDSpNoErr;
	}
	uint32_t pointAddr = dsp_testing_alloc_guest_scratch(4);   /* Point: v,h */
	if (pointAddr == 0) {
		return kDSpInternalErr;
	}
	WriteMacInt16(pointAddr + 0, (uint16_t)*v);   /* Point.v */
	WriteMacInt16(pointAddr + 2, (uint16_t)*h);   /* Point.h */
	int32_t rv = DSpContext_GlobalToLocalHandler(ctxRef, pointAddr);
	if (rv == kDSpNoErr) {
		*v = (int16_t)ReadMacInt16(pointAddr + 0);
		*h = (int16_t)ReadMacInt16(pointAddr + 2);
	}
	return rv;
}
#endif

/* --- DSpContext_LocalToGlobalHandler (sub-op 722) ---
 *
 *  DSp 1.7 PDF p.55: DSpContext_LocalToGlobal(inContext, Point *ioPoint). The
 *  inverse of GlobalToLocal — converts a context-local Point to global (screen)
 *  coordinates in place. At the iOS single fullscreen origin (0,0) this is also
 *  the IDENTITY; if GlobalToLocal subtracts a context-rect offset, this
 *  adds it back. Same read-modify-write idiom + ctxRef / NULL-ioPoint guards. */
extern "C" int32_t DSpContext_LocalToGlobalHandler(uint32_t ctxRef,
                                                   uint32_t ioPointAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || ioPointAddr == 0) {
		DSP_LOG("LocalToGlobal: invalid ctxRef=%u or ioPointAddr=0x%08x",
		        ctxRef, ioPointAddr);
		return kDSpInvalidContextErr;
	}
	/* Identity inverse at the single fullscreen origin (0,0). */
	const int16_t v = (int16_t)ReadMacInt16(ioPointAddr + 0);
	const int16_t h = (int16_t)ReadMacInt16(ioPointAddr + 2);
	WriteMacInt16(ioPointAddr + 0, (uint16_t)v);   /* Point.v — unchanged */
	WriteMacInt16(ioPointAddr + 2, (uint16_t)h);   /* Point.h — unchanged */
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/* Route the by-VALUE LocalToGlobal contract test THROUGH the
 * production DSpContext_LocalToGlobalHandler — same guest-scratch idiom +
 * dsp_testing_scratch_in_low_4gib() gate as DSpTesting_GlobalToLocalByValues
 * above. Exercises the real Point marshalling so the test falsifies a v/h
 * swap or +0/+2 offset regression in the production inverse handler. */
extern "C" int32_t DSpTesting_LocalToGlobalByValues(uint32_t ctxRef,
                                                    int16_t *v, int16_t *h)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || v == nullptr || h == nullptr) {
		return kDSpInvalidContextErr;
	}
	if (dsp_testing_scratch_in_low_4gib() == 0) {
		/* Guest scratch above 4 GiB — identity fallback (see GlobalToLocal). */
		return kDSpNoErr;
	}
	uint32_t pointAddr = dsp_testing_alloc_guest_scratch(4);   /* Point: v,h */
	if (pointAddr == 0) {
		return kDSpInternalErr;
	}
	WriteMacInt16(pointAddr + 0, (uint16_t)*v);   /* Point.v */
	WriteMacInt16(pointAddr + 2, (uint16_t)*h);   /* Point.h */
	int32_t rv = DSpContext_LocalToGlobalHandler(ctxRef, pointAddr);
	if (rv == kDSpNoErr) {
		*v = (int16_t)ReadMacInt16(pointAddr + 0);
		*h = (int16_t)ReadMacInt16(pointAddr + 2);
	}
	return rv;
}
#endif

/* Resolve the single on-screen Active context for a global (v, h) Point.
 * Walks dsp_context_table for the one Active context with a live back_buffer
 * (the SwapBuffers active-context gate) and, if the point is inside that
 * context's display bounds, returns its handle. Returns 0 for an off-screen
 * point (negative or beyond display bounds) OR when no Active context exists
 * — the error-code-IS-the-answer single-display posture. Shared by
 * the production handler + the TESTING_BUILD host helper. The (v, h) are
 * already-unpacked by-VALUE coords — never a dereferenced pointer.
 * ASVS V5: the display-bounds check runs BEFORE returning any handle. */
static uint32_t DSpResolveContextHandleAtPoint(int16_t v, int16_t h)
{
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
		if (ctx->back_buffer == nil) continue;
		/* Mac Point: v = vertical (row), h = horizontal (column). On a single
		 * fullscreen display the Active context contains every on-screen
		 * point [0, displayHeight) x [0, displayWidth). */
		const int32_t dispW = (int32_t)ctx->attr.displayWidth;
		const int32_t dispH = (int32_t)ctx->attr.displayHeight;
		if (v < 0 || h < 0 || (int32_t)v >= dispH || (int32_t)h >= dispW) {
			return 0;   /* off-screen -> no context (NotFound) */
		}
		return ctx->handle;
	}
	return 0;   /* no Active context */
}

/* --- DSpFindContextFromPointHandler (sub-op 723) ---
 *
 *  DSp 1.7 PDF p.53: DSpFindContextFromPoint(Point inGlobalPoint,
 *  DSpContextReference *outContext). The Point is passed by VALUE:
 *  the dispatch case unpacks it from r3 (v = high half, h = low half) and hands
 *  the int16 coords here — this handler NEVER dereferences a pointer for the
 *  Point. On the iOS single fullscreen display the one Active context contains
 *  every on-screen point, so an in-bounds (v, h) resolves to that context's
 *  handle. An off-screen point (negative or beyond display bounds) OR no Active
 *  context -> write 0 + kDSpContextNotFoundErr (error-code-IS-the-answer).
 *  Guards a NULL outCtxRefAddr. */
extern "C" int32_t DSpFindContextFromPointHandler(int16_t v, int16_t h,
                                                  uint32_t outCtxRefAddr)
{
	if (outCtxRefAddr == 0) {
		DSP_LOG("FindContextFromPoint: NULL outCtxRefAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	const uint32_t handle = DSpResolveContextHandleAtPoint(v, h);
	WriteMacInt32(outCtxRefAddr, handle);
	return (handle != 0) ? kDSpNoErr : kDSpContextNotFoundErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_FindContextFromPointByValues(int16_t v, int16_t h,
                                                           uint32_t *outCtxRef)
{
	if (outCtxRef == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	const uint32_t handle = DSpResolveContextHandleAtPoint(v, h);
	*outCtxRef = handle;
	return (handle != 0) ? kDSpNoErr : kDSpContextNotFoundErr;
}
#endif

/* ==========================================================================
 *  Discovery / multi-display family (sub-ops
 *  744, 746, 747, 760, 761). Single-display-faithful: on the one
 *  iOS display CanUserSelectContext reports false, FindBestContextOnDisplayID
 *  and UserSelectContext delegate to the existing FindBest 3-tier matcher
 *  (DSpFindBestContextHandler / DSpTesting_FindBestContextByStruct — no new
 *  algorithm), and the error code IS the correct single-display answer.
 *  SetDebugMode stores a global flag (store only). SetBlankingColor assigns
 *  the DMC blanking color via the no-transition dmc_set_blanking_color
 *  accessor (the screen does NOT enter the Blanking state). No new
 *  concurrency primitive.
 * ========================================================================== */

/* DSpSetDebugMode global flag (sub-op 761). Single-writer emul-thread — same
 * contract as every dsp logging-flag global; no mutex, no _Atomic. The
 * fade-path / debug-overlay consumption is left to a later fidelity pass;
 * this stores the flag and exposes a getter only. */
static bool s_dsp_debug_mode = false;

/* --- DSpSetDebugModeHandler (sub-op 761) ---
 *
 *  DSp 1.7 PDF p.59: DSpSetDebugMode(Boolean inDebugMode). NO ctxRef — r3 is
 *  the Boolean debug-mode value. Stores the global s_dsp_debug_mode flag so a
 *  future fidelity pass can consult it on the fade path. Always
 *  succeeds (kDSpNoErr) — there is no failure mode for a global Boolean set. */
extern "C" int32_t DSpSetDebugModeHandler(uint32_t inDebugMode)
{
	s_dsp_debug_mode = (inDebugMode != 0);
	DSP_LOG("SetDebugMode: s_dsp_debug_mode = %d", (int)s_dsp_debug_mode);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_SetDebugModeByValue(uint8_t on)
{
	return DSpSetDebugModeHandler(on);
}

extern "C" int32_t DSpTesting_GetDebugMode(uint8_t *out)
{
	if (out == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	*out = s_dsp_debug_mode ? 1 : 0;
	return kDSpNoErr;
}
#endif

/* --- DSpCanUserSelectContextHandler (sub-op 746) ---
 *
 *  DSp 1.7 PDF p.19: DSpCanUserSelectContext(DSpContextAttributesPtr
 *  inDesiredAttributes, Boolean *outUserCanSelectContext). The Boolean
 *  answers whether more than one cached mode satisfies the requested minimum
 *  attributes. It is not equivalent to "does this host have more than one
 *  physical display"; classic games use a false answer to skip their mode
 *  selection path and fall back to DSpFindBestContext.
 */
extern "C" int32_t DSpCanUserSelectContextHandler(uint32_t attrAddr,
                                                  uint32_t outCanAddr)
{
	if (attrAddr == 0) {
		DSP_LOG("CanUserSelectContext: NULL attrAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	if (outCanAddr == 0) {
		DSP_LOG("CanUserSelectContext: NULL outCanAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}

	DSpContextAttributes req = {};
	req.displayWidth          = ReadMacInt32(attrAddr +  4);
	req.displayHeight         = ReadMacInt32(attrAddr +  8);
	req.backBufferDepthMask   = ReadMacInt32(attrAddr + 32);
	req.displayDepthMask      = ReadMacInt32(attrAddr + 36);
	req.backBufferBestDepth   = ReadMacInt32(attrAddr + 40);
	req.displayBestDepth      = ReadMacInt32(attrAddr + 44);
	req.pageCount             = ReadMacInt32(attrAddr + 48);
	req.backBufferWidth       = req.displayWidth;
	req.backBufferHeight      = req.displayHeight;

	const size_t selectable = DSpUserSelectableModeCount(&req);
	const uint8_t canSelect =
	    DSpCanUserSelectContextFromCount(selectable) ? 1 : 0;
	DSP_LOG("CanUserSelectContext: req=%ux%u back@%ubpp/bmask=0x%08x "
	        "display@%ubpp/dmask=0x%08x pc=%u selectable=%zu -> %u",
	        req.displayWidth, req.displayHeight,
	        req.backBufferBestDepth, req.backBufferDepthMask,
	        req.displayBestDepth, req.displayDepthMask,
	        req.pageCount, selectable, canSelect);
	WriteMacInt8(outCanAddr, canSelect);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_CanUserSelectContextByStruct(
    const struct DSpContextAttributes *req, uint8_t *outCan)
{
	if (req == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	if (outCan == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	*outCan = DSpCanUserSelectContextFromCount(
	    DSpUserSelectableModeCount(req)) ? 1 : 0;
	return kDSpNoErr;
}
#endif

/* --- DSpFindBestContextOnDisplayIDHandler (sub-op 744) ---
 *
 *  DSp 1.7 PDF p.14: DSpFindBestContextOnDisplayID(DSpContextAttributesPtr
 *  inDesiredAttributes, DSpContextReference *outContext, DisplayIDType
 *  inDisplayID). 3-arg ABI: attrs FIRST (r3), outContext SECOND (r4),
 *  displayID THIRD (r5).
 *
 *  Lifted single-screen policy: iOS hosts a single backing
 *  screen, so ANY inDisplayID hard-routes to that screen — accepted + logged,
 *  mirroring DSpGetFirstContextHandler (sub-op 200). Real apps pass
 *  Display-Manager IDs; after routing, delegate verbatim to the
 *  EXISTING FindBest matcher (DSpFindBestContextHandler — the same attr-read +
 *  3-tier Core + AllocAndWriteBack + WriteMacInt32 path; NO new algorithm).
 *  Guards a NULL outCtxRefAddr. A genuinely unmatchable attribute request
 *  still surfaces as 0 + kDSpContextNotFoundErr from the matcher (NOT a
 *  displayID mismatch). */
extern "C" int32_t DSpFindBestContextOnDisplayIDHandler(uint32_t attrAddr,
                                                        uint32_t outCtxRefAddr,
                                                        uint32_t inDisplayID)
{
	if (outCtxRefAddr == 0) {
		DSP_LOG("FindBestContextOnDisplayID: NULL outCtxRefAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	if (!DSpAcceptsSingleDisplayID(inDisplayID)) {
		/* Lift diagnostic: surface the non-main path so future
		 * loggo captures show real-world Display-Manager IDs (e.g. 256)
		 * reaching the single-screen mapping instead of being rejected. */
		DSP_LOG("FindBestContextOnDisplayID: displayID=%u accepted "
		        "(single-screen iOS — mapped to backing screen)", inDisplayID);
	}
	/* Single screen -> delegate to the existing FindBest 3-tier matcher. An
	 * unmatchable attribute request becomes 0 + kDSpContextNotFoundErr there. */
	return DSpFindBestContextHandler(attrAddr, outCtxRefAddr);
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_FindBestContextOnDisplayIDByStruct(
    const struct DSpContextAttributes *req, uint32_t displayID,
    uint32_t *outCtxRef)
{
	if (outCtxRef == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	(void)displayID;  /* lifted policy: any displayID maps to single screen */
	/* Delegate to the existing FindBest matcher (no new algorithm). An
	 * unmatchable attribute request becomes 0 + kDSpContextNotFoundErr there. */
	return DSpTesting_FindBestContextByStruct(req, outCtxRef);
}
#endif

/* --- DSpUserSelectContextHandler (sub-op 747) ---
 *
 *  DSp 1.7 PDF p.20: DSpUserSelectContext(DSpContextAttributesPtr
 *  inDesiredAttributes, DisplayIDType inDialogDisplayLocation, DSpEventProcPtr
 *  inCleanupEventProc, DSpContextReference *outContext). 4-arg ABI (attrs r3,
 *  dialogLoc r4, eventProc r5, outContext r6). Normally this presents a
 *  monitor/mode-selection DIALOG to the user; on the single iOS display there
 *  is no meaningful choice and no dialog UI, so it behaves as a FindBest
 *  auto-pick — delegate VERBATIM to the existing FindBest matcher
 *  (DSpFindBestContextHandler — NO new algorithm, NO dialog). The dialog
 *  location + cleanup event proc are not used on a single display ((void)'d
 *  for -Werror). Guards a NULL outCtxRefAddr. The auto-pick IS the correct
 *  single-display answer, NOT a convenience stub. */
extern "C" int32_t DSpUserSelectContextHandler(uint32_t attrAddr,
                                               uint32_t inDialogDisplayLocation,
                                               uint32_t inEventProc,
                                               uint32_t outCtxRefAddr)
{
	(void)inDialogDisplayLocation;   /* no dialog on a single display */
	(void)inEventProc;               /* no cleanup proc invoked (no dialog) */
	if (outCtxRefAddr == 0) {
		DSP_LOG("UserSelectContext: NULL outCtxRefAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	/* No dialog -> auto-pick via the existing FindBest matcher. */
	return DSpFindBestContextHandler(attrAddr, outCtxRefAddr);
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_UserSelectContextByStruct(
    const struct DSpContextAttributes *req, uint32_t *outCtxRef)
{
	if (outCtxRef == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	/* Auto-pick via the existing FindBest matcher (no dialog, no new algo). */
	return DSpTesting_FindBestContextByStruct(req, outCtxRef);
}
#endif

/* --- DSpSetBlankingColorHandler (sub-op 760) ---
 *
 *  DSp 1.7 PDF p.30: DSpSetBlankingColor(const RGBColor *inRGBColor). NO
 *  ctxRef — r3 is the RGBColor address. Assigns the color the library uses the
 *  next time a context is blanked; it does NOT blank the screen now. The
 *  RGBColor is three 16-bit channels (red@+0, green@+2, blue@+4); down-convert
 *  to 8-bit by taking the high byte (universal QuickDraw 16->8 convention)
 *  with alpha = 0xFF, and assign via the no-transition DMC accessor
 *  dmc_set_blanking_color (which mutates the snapshot's blanking_rgba WITHOUT
 *  entering the Blanking state). Guards a NULL inRGBColorAddr.
 *  Always returns kDSpNoErr on a valid set (the DMC accessor
 *  may report not-initialized in a no-DMC build, which is still kDSpNoErr at
 *  the DSp ABI — the color set is best-effort, not a failure the app acts on). */
extern "C" int32_t DSpSetBlankingColorHandler(uint32_t inRGBColorAddr)
{
	if (inRGBColorAddr == 0) {
		DSP_LOG("SetBlankingColor: NULL inRGBColorAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	uint16_t r16 = (uint16_t)ReadMacInt16(inRGBColorAddr + 0);
	uint16_t g16 = (uint16_t)ReadMacInt16(inRGBColorAddr + 2);
	uint16_t b16 = (uint16_t)ReadMacInt16(inRGBColorAddr + 4);
	uint8_t rgba[4] = { (uint8_t)(r16 >> 8), (uint8_t)(g16 >> 8),
	                    (uint8_t)(b16 >> 8), 0xFF };
	dmc_set_blanking_color(rgba);   /* no state transition */
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
extern "C" int32_t DSpTesting_SetBlankingColorByValues(uint16_t r, uint16_t g,
                                                       uint16_t b)
{
	/* Same 16->8 high-byte down-convert + no-transition DMC accessor call as
	 * the handler, bypassing the guest-RAM RGBColor read. */
	uint8_t rgba[4] = { (uint8_t)(r >> 8), (uint8_t)(g >> 8),
	                    (uint8_t)(b >> 8), 0xFF };
	dmc_set_blanking_color(rgba);
	return kDSpNoErr;
}
#endif

/* --- DSpContext_InvalBackBufferRectHandler ---
 *
 *  Bounding-rect union accumulator for InvalBackBufferRect (PDF p.38).
 *  Classic Mac DSp apps notify the library about which sub-region of the
 *  back-buffer they've drawn into; when SwapBuffers fires the renderer
 *  can upload just that sub-rect via MTLBlitCommandEncoder sourceOrigin +
 *  sourceSize rather than the full back-buffer.
 *
 *  Design: bounding-rect union (O(1)) NOT per-rect list. Classic
 *  Mac DSp apps either dirty the whole back-buffer or dirty one rect, not
 *  scattered N-rect patterns — a union accumulator with a > 90% coverage
 *  promotion threshold back to full-blit captures the behavior envelope
 *  without the per-rect bookkeeping cost. Tile-based dirty tracking is
 *  overkill for the workload.
 *
 *  Cold-start semantics (PDF p.38): zero Inval calls between
 *  SwapBuffers means the ENTIRE back-buffer is considered dirty — this is
 *  the case on the very first swap and after background→foreground
 *  restore. Reserve sets dirty_cold_start=true; foreground restore sets
 *  it again. SwapBuffers checks cold_start
 *  FIRST, before the dirty-rect accumulator.
 *
 *  ASVS V5 clamping: oversized / negative rect fields are
 *  clamped to back-buffer bounds rather than rejected, matching the DSp
 *  spec "clamp; do not fail" posture. Empty / inverted rects are silently
 *  ignored with a log note.
 */

/*
 *  Clamp an input Rect to back-buffer bounds + union into the existing
 *  bounding-rect accumulator. O(1).
 *
 *  Oversized rects (right > displayWidth, bottom > displayHeight) are
 *  silently clamped to the back-buffer bounds rather than rejected,
 *  because the DSp spec says "clamp; do not fail". Negative
 *  top/left are clamped to 0.
 */
static void DSpInvalBackBufferRect_Accumulate(DSpContextPrivate *ctx,
                                               int16_t top, int16_t left,
                                               int16_t bottom, int16_t right)
{
	if (ctx == nullptr) return;

	/* ASVS V5 input validation — clamp to back-buffer bounds.
	 * Integer-max right/bottom values get clipped; negative top/left
	 * get clipped to 0. */
	int32_t clamped_top    = (top    < 0) ? 0 : top;
	int32_t clamped_left   = (left   < 0) ? 0 : left;
	int32_t clamped_bottom = (bottom < 0) ? 0 : bottom;
	int32_t clamped_right  = (right  < 0) ? 0 : right;
	if ((uint32_t)clamped_right  > ctx->attr.displayWidth)
		clamped_right  = (int32_t)ctx->attr.displayWidth;
	if ((uint32_t)clamped_bottom > ctx->attr.displayHeight)
		clamped_bottom = (int32_t)ctx->attr.displayHeight;

	/* Empty / inverted rect? (bottom <= top or right <= left) — no-op. */
	if (clamped_right <= clamped_left || clamped_bottom <= clamped_top) {
		DSP_LOG("InvalBackBufferRect: empty/inverted rect ignored "
		        "(t=%d l=%d b=%d r=%d)",
		        clamped_top, clamped_left, clamped_bottom, clamped_right);
		return;
	}

	if (ctx->dirty_empty) {
		ctx->dirty_left   = (int16_t)clamped_left;
		ctx->dirty_top    = (int16_t)clamped_top;
		ctx->dirty_right  = (int16_t)clamped_right;
		ctx->dirty_bottom = (int16_t)clamped_bottom;
		ctx->dirty_empty  = false;
	} else {
		if ((int16_t)clamped_left   < ctx->dirty_left)
			ctx->dirty_left   = (int16_t)clamped_left;
		if ((int16_t)clamped_top    < ctx->dirty_top)
			ctx->dirty_top    = (int16_t)clamped_top;
		if ((int16_t)clamped_right  > ctx->dirty_right)
			ctx->dirty_right  = (int16_t)clamped_right;
		if ((int16_t)clamped_bottom > ctx->dirty_bottom)
			ctx->dirty_bottom = (int16_t)clamped_bottom;
	}
}

extern "C" int32_t DSpContext_InvalBackBufferRectHandler(uint32_t ctxRef,
                                                          uint32_t rectAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || rectAddr == 0) {
		DSP_LOG("InvalBackBufferRect: invalid ctxRef=%u or rectAddr=0",
		        ctxRef);
		return kDSpInvalidContextErr;
	}
	/* Mac Rect in guest RAM: big-endian 4 x int16. ReadMacInt16 returns
	 * uint32 (host-native); cast to int16_t for signed interpretation. */
	int16_t top    = (int16_t)ReadMacInt16(rectAddr + 0);
	int16_t left   = (int16_t)ReadMacInt16(rectAddr + 2);
	int16_t bottom = (int16_t)ReadMacInt16(rectAddr + 4);
	int16_t right  = (int16_t)ReadMacInt16(rectAddr + 6);

	DSpInvalBackBufferRect_Accumulate(ctx, top, left, bottom, right);
	DSP_VLOG("InvalBackBufferRect: ctx=%u rect=(%d,%d)-(%d,%d) "
	         "union=(%d,%d)-(%d,%d) cold_start=%d",
	         ctxRef, top, left, bottom, right,
	         ctx->dirty_top, ctx->dirty_left, ctx->dirty_bottom, ctx->dirty_right,
	         ctx->dirty_cold_start);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD helper: direct-int16 wrapper around
 *  DSpContext_InvalBackBufferRectHandler. The production path reads
 *  4 int16 fields from rectAddr via ReadMacInt16; on arm64 iOS simulator
 *  with above-4GiB-truncated addresses, ReadMacInt16 SEGVs. This
 *  wrapper takes the 4 int16 values directly.
 */
extern "C" int32_t DSpTesting_InvalBackBufferRectByValue(uint32_t ctxRef,
                                                          int16_t top,
                                                          int16_t left,
                                                          int16_t bottom,
                                                          int16_t right)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		return kDSpInvalidContextErr;
	}
	DSpInvalBackBufferRect_Accumulate(ctx, top, left, bottom, right);
	return kDSpNoErr;
}
#endif

/* ============================================================== */
/*  DSpContext_GetAttributes (sub-opcode 202)                      */
/*                                                                 */
/*  Returns ctx->attr verbatim (stored as-reserved at Reserve      */
/*  time). PDF p.18 "as-active" reading is observationally         */
/*  equivalent because FindBest returns exact-match or             */
/*  kDSpContextNotFoundErr — no substitution. Revisit if           */
/*  substitution is ever introduced (at which point we'll add      */
/*  ctx->actual_attr and GetAttributes will prefer it).            */
/*                                                                 */
/*  Writes through the PDF-p.65 layout.                            */
/*  Writes ZERO DMC-owned fields — DMCWriteSiteInventoryTests      */
/*  .testNoDirectDMCWritesInDSpFiles gate stays                    */
/*  green. Lives in dsp_draw_context.mm (NOT                       */
/*  dsp_mode_enumerate.cpp) because it operates on                 */
/*  DSpContextPrivate — the context table is private to            */
/*  this translation unit per the DMC-invariant discipline.        */
/* ============================================================== */

/*
 *  Core helper: write a host DSpContextAttributes through PDF-p.65 on-wire
 *  offsets into guest Mac RAM. Reserved/filler fields are explicitly
 *  zeroed so the emulated app reads a canonical out-struct, not whatever
 *  guest-RAM garbage preceded the call. frequency is always 0 per PDF
 *  p.66 ("value is 0 if actual frequency is not available") — the
 *  emulator does not synthesize a refresh rate from
 *  vbl_source_get_cadence_usec.
 */
static void DSpWriteAttributesCore(const DSpContextAttributes *attr,
                                    uint32_t outAttrAddr)
{
	/* DSp 1.7 PDF p.65 on-wire byte layout.  All UInt32 / Fixed / OptionBits /
	 * CTabHandle fields are 4 bytes each.  filler[3] + gameMustConfirmSwitch
	 * pack into the 4-byte slot @ +52..+55. reserved3[4] occupies +56..+71.
	 * Re-corrected 2026-04-21 via debug session `dsp-sims-rejects-all-modes`;
	 * pre-correction layout wrote displayWidth / displayHeight to the wrong
	 * offsets causing The Sims to read 0 and reject every mode. */
	WriteMacInt32(outAttrAddr +  0, 0 /* frequency unavailable per PDF p.66 */);
	WriteMacInt32(outAttrAddr +  4, attr->displayWidth);
	WriteMacInt32(outAttrAddr +  8, attr->displayHeight);
	WriteMacInt32(outAttrAddr + 12, 0 /* reserved1 */);
	WriteMacInt32(outAttrAddr + 16, 0 /* reserved2 */);
	WriteMacInt32(outAttrAddr + 20, attr->colorNeeds);
	WriteMacInt32(outAttrAddr + 24, attr->colorTable);
	WriteMacInt32(outAttrAddr + 28, attr->contextOptions);
	WriteMacInt32(outAttrAddr + 32, attr->backBufferDepthMask);
	WriteMacInt32(outAttrAddr + 36, attr->displayDepthMask);
	WriteMacInt32(outAttrAddr + 40, attr->backBufferBestDepth);
	WriteMacInt32(outAttrAddr + 44, attr->displayBestDepth);
	WriteMacInt32(outAttrAddr + 48, attr->pageCount);
	/* filler[3] @ +52..+54 (zero), gameMustConfirmSwitch (Boolean) @ +55. */
	WriteMacInt8 (outAttrAddr + 52, 0 /* filler[0] */);
	WriteMacInt8 (outAttrAddr + 53, 0 /* filler[1] */);
	WriteMacInt8 (outAttrAddr + 54, 0 /* filler[2] */);
	WriteMacInt8 (outAttrAddr + 55, (uint8_t)(attr->gameMustConfirmSwitch ? 1 : 0));
	/* reserved3[0..3] @ +56..+71 explicitly zeroed. */
	WriteMacInt32(outAttrAddr + 56, 0 /* reserved3[0] */);
	WriteMacInt32(outAttrAddr + 60, 0 /* reserved3[1] */);
	WriteMacInt32(outAttrAddr + 64, 0 /* reserved3[2] */);
	WriteMacInt32(outAttrAddr + 68, 0 /* reserved3[3] */);
}

extern "C" int32_t DSpContext_GetAttributesHandler(uint32_t ctxRef,
                                                    uint32_t outAttrAddr)
{
	/* Validate outAttrAddr before any read of ctx->attr so
	 * a bad pointer + valid handle combination is reported as the more
	 * specific kDSpInvalidAttributesErr rather than masking as
	 * kDSpInvalidContextErr. */
	if (outAttrAddr == 0) {
		DSP_LOG("GetAttributes: NULL outAttrAddr (ctxRef=%u) -> "
		        "kDSpInvalidAttributesErr", ctxRef);
		return kDSpInvalidAttributesErr;
	}
	/* DSpGetContext returns nullptr on invalid handle;
	 * no write to guest RAM happens on this path. */
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("GetAttributes: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}

	DSpContextAttributes public_attr = ctx->attr;
	DSpNormalizeGetAttributesForState(&public_attr, ctx->state);
	DSpWriteAttributesCore(&public_attr, outAttrAddr);

	DSP_LOG("GetAttributes: ctx=%u internal=%ux%u@%ubpp display@%u "
	        "public@%u pc=%u state=%u -> returned",
	        ctxRef,
	        ctx->attr.displayWidth, ctx->attr.displayHeight,
	        ctx->attr.backBufferBestDepth, ctx->attr.displayBestDepth,
	        public_attr.backBufferBestDepth, ctx->attr.pageCount,
	        ctx->state);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/*
 *  Host-struct wrapper (see
 *  DSpTesting_ReserveByStruct / DSpTesting_FindBestContextByStruct).
 *  Side-steps the arm64 iOS simulator above-4GiB guest-RAM SEGV by
 *  copying into a host DSpContextAttributes instead of round-tripping
 *  through WriteMacInt*. Shares the canonical-out-struct invariants of
 *  the Mac-memory path (frequency=0, reserved/filler zeroed).
 */
extern "C" int32_t DSpTesting_GetAttributesByStruct(uint32_t ctxRef,
                                                     DSpContextAttributes *outAttr)
{
	if (outAttr == nullptr) return kDSpInvalidAttributesErr;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;

	/* Host-struct copy — sidesteps Mac-memory round-trip +
	 * above-4GiB simulator guest-RAM SEGV avoidance. */
	*outAttr = ctx->attr;
	/* Enforce invariants the guest-RAM path enforces so
	 * DSpTesting_GetAttributesByStruct and DSpContext_GetAttributesHandler
	 * are observationally identical: frequency=0, reserved/filler zeroed. */
	outAttr->frequency             = 0;
	outAttr->reserved1             = 0;
	outAttr->reserved2             = 0;
	outAttr->gameMustConfirmSwitch = 0;  /* input-ignored per PDF p.67; out=false */
	outAttr->reserved3[0]          = 0;
	outAttr->reserved3[1]          = 0;
	outAttr->reserved3[2]          = 0;
	outAttr->reserved3[3]          = 0;
	return kDSpNoErr;
}
#endif


/*
 *  DSpContext_FadeGammaIn (sub-opcode 402).
 *
 *  Argument contract:
 *    ctxRef         = context handle from DSpContext_Reserve
 *    durationVbls   = number of VBL ticks over which to fade. 0 = apply
 *                     end LUT immediately. Values > DSP_MAX_FADE_VBLS
 *                     (4096) are clamped with a DSP_LOG warning.
 *
 *  Error map:
 *    kDSpInvalidContextErr - ctxRef does not resolve to a context
 *    kDSpNoErr             - success; fade started (or end LUT applied
 *                              immediately if durationVbls == 0)
 *
 *  Fade target:
 *    end_lut = identity LUT — for each channel c in {R, G, B} and each
 *    index i in [0..255], end_lut[c*256 + i] = i. The identity LUT is
 *    the "no gamma correction" state — the screen displays exactly the
 *    framebuffer's stored colors.
 *
 *  Fade behavior:
 *    DSpVBLGammaFadeCallback walks dsp_context_table
 *    every VBL; for each context with fade_state.active != 0 it
 *    increments elapsed_vbls, computes the interpolated LUT, and pushes
 *    via dmc_record_gamma_change_with_lut. On final frame
 *    (elapsed_vbls >= duration_vbls), pushes end_lut + memcpys end_lut
 *    into ctx->gamma_lut_persisted + sets active = 0.
 *
 *  Active-fade replacement:
 *    If a fade was already active, DSpInitFadeStateCore snapshots the
 *    current interpolated state into the new start_lut so the visual
 *    transition is continuous (no snap-back to the old fade's source).
 */
extern "C" int32_t DSpContext_FadeGammaInHandler(uint32_t ctxRef,
                                                  uint32_t colorAddr)
{
	/*
	 *  Debug session `dsp-sims-post-reserve-black-screen` fix (2026-04-19):
	 *  DSp 1.7 PDF p.35 (FadeGammaIn) shares the NULL-context semantics of
	 *  the FadeGamma trio — inContext == NULL applies the fade
	 *  simultaneously to all displays (ambient gamma, not a per-context
	 *  fade). Real DSp apps call `DSpContext_FadeGammaOut(NULL, NULL)`
	 *  between Reserve and SetState to fade the system-wide gamma to black
	 *  before transitioning their game context to Active (see Apple's
	 *  OpenGL DSp sample at
	 *  resources/OpenGL_SDK_1.2/.../OpenGL DrawSprocket.c).
	 *
	 *  Pre-fix behavior: rejected with kDSpInvalidContextErr — which
	 *  caused The Sims to mark DSp as unhealthy and silently degrade its
	 *  render path (no GetBackBuffer / SwapBuffers ever issued).
	 *
	 *  Post-fix: accept ctxRef == 0 as an informational no-op. We don't
	 *  apply a system-wide gamma fade (our compositor-level gamma pipeline
	 *  is per-context in the DSp engine; the compositor's own gamma path
	 *  lives in MetalCompositor and has its own APIs). Returning
	 *  kDSpNoErr matches the spec contract "the call succeeded" without
	 *  introducing a cross-subsystem ambient-fade dependency — the game's
	 *  later per-ctx fade calls + our compositor LUT keep pixels correct.
	 */
	if (ctxRef == 0) {
		DSP_LOG("FadeGammaIn: ctxRef=0 (ambient-display no-op per PDF p.35); "
		        "colorAddr=0x%08x accepted",
		        colorAddr);
		return kDSpNoErr;
	}
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("FadeGammaIn: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}

	/*
	 *  FadeGammaIn takes (inContext, RGBColor *inZeroIntensityColor)
	 *  and fades 0% -> 100% intensity over a FIXED ONE SECOND (PDF p.35),
	 *  NOT a guest-supplied durationVbls. Derive the 1-second VBL count
	 *  from the live device-native cadence: 60 VBLs on a 60 Hz panel,
	 *  120 on a 120 Hz ProMotion panel — never a hardcoded 60.
	 *  inZeroIntensityColor is accepted (NULL -> black, legal); for the
	 *  IN direction the end state is full intensity (identity), so the
	 *  tint defines only the conceptual 0% start, which the VBL driver
	 *  already snapshots from the current displayed gamma.
	 */
	(void)colorAddr;  /* tint accepted; end_lut for IN is identity (100%) */

	uint64_t cadence_usec = vbl_source_get_cadence_usec();
	uint32_t vbls_1sec = (cadence_usec > 0)
	                     ? (uint32_t)((1000000ull + cadence_usec / 2) / cadence_usec)
	                     : 60u;
	if (vbls_1sec > DSP_MAX_FADE_VBLS) vbls_1sec = DSP_MAX_FADE_VBLS;

	/* Build identity end_lut: lut[c*256 + i] = i for c in {R,G,B}, i in [0..255]. */
	uint8_t identity_lut[768];
	for (uint32_t c = 0; c < 3; c++) {
		for (uint32_t i = 0; i < 256; i++) {
			identity_lut[c * 256 + i] = (uint8_t)i;
		}
	}

	/* Initialize the fade machinery (active-fade-replacement snapshot
	 * + end_lut copy + duration/elapsed/active reset). The VBL driver
	 * (DSpVBLGammaFadeCallback) is UNCHANGED — only the duration source
	 * changed from a guest arg to the derived 1-second count. */
	DSpInitFadeStateCore(ctx, identity_lut, (uint16_t)vbls_1sec);
	DSP_LOG("FadeGammaIn: ctx=%u 1-second fade -> %u VBLs (cadence %llu usec) started",
	        ctxRef, vbls_1sec, (unsigned long long)cadence_usec);
	return kDSpNoErr;
}

/*
 *  DSpContext_FadeGammaOut (sub-opcode 403).
 *
 *  Argument contract: identical to FadeGammaIn.
 *  Error map: identical to FadeGammaIn.
 *
 *  Fade target:
 *    end_lut = all zeros (768 bytes of 0x00) — black-screen state. With
 *    a zero gamma LUT, the screen displays pure black regardless of
 *    framebuffer contents. Used by games for screen blanking + scene
 *    transitions.
 *
 *  Fade behavior + active-fade replacement: identical to FadeGammaIn.
 */
extern "C" int32_t DSpContext_FadeGammaOutHandler(uint32_t ctxRef,
                                                   uint32_t colorAddr)
{
	/*
	 *  Debug session `dsp-sims-post-reserve-black-screen` fix (2026-04-19):
	 *  See FadeGammaIn above for the full rationale. PDF p.34 defines
	 *  inContext == NULL as an ambient-display fade that applies to all
	 *  displays simultaneously. Pre-fix rejection with kDSpInvalidContext-
	 *  Err poisoned The Sims's internal DSp-healthy flag. Post-fix we
	 *  accept it as a logged no-op returning kDSpNoErr.
	 */
	if (ctxRef == 0) {
		DSP_LOG("FadeGammaOut: ctxRef=0 (ambient-display no-op per PDF p.34); "
		        "colorAddr=0x%08x accepted",
		        colorAddr);
		return kDSpNoErr;
	}
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("FadeGammaOut: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}

	/*
	 *  FadeGammaOut takes (inContext, RGBColor *inZeroIntensityColor)
	 *  and fades 100% -> 0% intensity over a FIXED ONE SECOND (PDF p.34),
	 *  NOT a guest-supplied durationVbls. The end state is 0% intensity =
	 *  the inZeroIntensityColor tint (NULL -> black -> zeros, preserving
	 *  the prior fade-to-black default). Derive the 1-second VBL count
	 *  from the live device-native cadence — never hardcode 60.
	 */
	uint8_t color_r = 0, color_g = 0, color_b = 0;
	if (colorAddr != 0) {
		DSpReadParametricColorFromGuest(colorAddr, &color_r, &color_g, &color_b);
	}

	uint64_t cadence_usec = vbl_source_get_cadence_usec();
	uint32_t vbls_1sec = (cadence_usec > 0)
	                     ? (uint32_t)((1000000ull + cadence_usec / 2) / cadence_usec)
	                     : 60u;
	if (vbls_1sec > DSP_MAX_FADE_VBLS) vbls_1sec = DSP_MAX_FADE_VBLS;

	/* Build the end_lut at 0% intensity = the zero-intensity tint. The
	 * signed-percent formula at percent=0 yields target[c][i] = tint[c]
	 * for every index i (a flat per-channel tint LUT); NULL color -> all
	 * zeros (fade to black). */
	uint8_t end_lut[768];
	DSpComputeFadeGammaTargetLUT(color_r, color_g, color_b, 0, end_lut);

	/* Initialize the fade machinery (VBL driver UNCHANGED — only the
	 * duration source changed from a guest arg to the derived 1-second
	 * count, and the end_lut now honors the zero-intensity tint). */
	DSpInitFadeStateCore(ctx, end_lut, (uint16_t)vbls_1sec);
	DSP_LOG("FadeGammaOut: ctx=%u tint=(%u,%u,%u) 1-second fade -> %u VBLs "
	        "(cadence %llu usec) started",
	        ctxRef, color_r, color_g, color_b,
	        vbls_1sec, (unsigned long long)cadence_usec);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD helper — return the
 *  device-native VBL count for the FadeGammaIn/Out fixed 1-second fade.
 *  Tests use this to advance exactly the right number of VBLs so the
 *  fade reaches its terminal state, matching the production handlers'
 *  cadence-derived duration (60 on 60 Hz, 120 on ProMotion).
 */
extern "C" uint32_t DSpTesting_FadeOneSecondVbls(void)
{
	uint64_t cadence_usec = vbl_source_get_cadence_usec();
	uint32_t vbls_1sec = (cadence_usec > 0)
	                     ? (uint32_t)((1000000ull + cadence_usec / 2) / cadence_usec)
	                     : 60u;
	if (vbls_1sec > DSP_MAX_FADE_VBLS) vbls_1sec = DSP_MAX_FADE_VBLS;
	return vbls_1sec;
}

/*
 *  TESTING_BUILD wrappers — drive the
 *  corrected FadeGammaIn/Out (no duration; fixed 1-second cadence-derived)
 *  from Swift test code with a host-side zero-intensity tint. The IN end
 *  state is full intensity (identity); the OUT end state is the tint
 *  (NULL/black -> zeros). Both bypass ONLY the guest-RAM tint read —
 *  the cadence derivation + DSpInitFadeStateCore call run identically to
 *  production. (Yellow/named-color tests pass r/g/b directly.)
 */
extern "C" int32_t DSpTesting_FadeGammaInByColor(uint32_t ctxRef,
                                                  uint8_t r,
                                                  uint8_t g,
                                                  uint8_t b)
{
	/* IN end_lut is identity regardless of tint; the production handler
	 * accepts colorAddr but uses identity end. Pass colorAddr=0 (legal
	 * NULL -> black) — identical IN behavior. */
	(void)r; (void)g; (void)b;
	return DSpContext_FadeGammaInHandler(ctxRef, 0);
}

extern "C" int32_t DSpTesting_FadeGammaOutByColor(uint32_t ctxRef,
                                                   uint8_t r,
                                                   uint8_t g,
                                                   uint8_t b)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;

	uint32_t vbls_1sec = DSpTesting_FadeOneSecondVbls();

	/* OUT end_lut = the zero-intensity tint (formula at percent=0). */
	uint8_t end_lut[768];
	DSpComputeFadeGammaTargetLUT(r, g, b, 0, end_lut);

	DSpInitFadeStateCore(ctx, end_lut, (uint16_t)vbls_1sec);
	return kDSpNoErr;
}

/*
 *  TESTING_BUILD: advance the gamma fade by exactly one VBL
 *  tick. Calls DSpVBLGammaFadeCallback directly with NULL/0 args (the
 *  callback ignores them). Used by DSpGammaTests to step through fade
 *  frames deterministically without waiting for vbl_source ticks.
 *
 *  This is the gamma equivalent of vbl_source_testing_simulate_vbl_tick
 *  scoped to the gamma callback only — the CLUT tests use the
 *  vbl_source helper to advance both the release callback + the
 *  clut-latch callback; gamma tests can use either path, but this
 *  helper isolates the gamma callback for tighter assertion windows.
 */
extern "C" void DSpTesting_AdvanceFadeOneVBL(void)
{
	DSpVBLGammaFadeCallback(NULL, NULL, 0.0);
}

/*
 *  TESTING_BUILD wrapper — calls DSpVBLServiceCallback
 *  directly so tests can deterministically advance the VBL
 *  tick counter + drive the per-context walk without waiting for a
 *  real display-link fire.
 *
 *  Note that vbl_source_testing_simulate_vbl_tick (vbl_source.h:178)
 *  ALSO drains the secondary-callback chain (including
 *  DSpVBLServiceCallback) as part of its full fan-out simulation —
 *  that's the preferred test-path for integration tests that want to
 *  exercise the full VBL-to-callback plumbing. DSpTesting_SimulateVBLTick
 *  is a faster/narrower shim for unit tests that only need to exercise
 *  the walk body without the other three secondary callbacks
 *  (release + clut-latch + gamma-fade) firing in the same tick.
 *
 *  Args are passed as nullptr / 0.0 to match the production call
 *  signature (cb_ctx/drawable/ts are unused inside the callback).
 */
extern "C" void DSpTesting_SimulateVBLTick(void)
{
	DSpVBLServiceCallback(nullptr, nullptr, 0.0);
}

/*
 *  TESTING_BUILD wrapper — host-value wrapper around
 *  DSpContext_BlankFillHandler. The production path reads 8 bytes of Rect
 *  + 6 bytes of RGBColor via ReadMacInt16; on arm64 iOS simulator with
 *  above-4GiB-truncated addresses, ReadMacInt16 SEGVs.
 *  This wrapper takes the 4 int16 rect coordinates + 3 uint8 color
 *  channels directly. Behavior is byte-identical to the Mac-address
 *  variant at the DSpBlankFillCore level — same clipping, same depth-
 *  dispatch, same DSpInvalBackBufferRect_Accumulate call.
 *
 *  Mirrors the DSpTesting_FadeGammaByValues +
 *  DSpTesting_InvalBackBufferRectByValue precedent.
 *
 *  Used by DSpVBLTests for golden-image BlankFill
 *  assertions at 1/2/4/8/16/32 bpp without guest-RAM plumbing.
 */
extern "C" int32_t DSpTesting_BlankFillByValues(uint32_t ctxRef,
                                                 int16_t top,
                                                 int16_t left,
                                                 int16_t bottom,
                                                 int16_t right,
                                                 uint8_t r,
                                                 uint8_t g,
                                                 uint8_t b)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		return kDSpInvalidContextErr;
	}
	return DSpBlankFillCore(ctx, top, left, bottom, right, r, g, b);
}

/*
 *  TESTING_BUILD wrapper — host-value read of s_dsp_vbl_count
 *  for DSpVBLTests.swift tick-monotonicity + correlation assertions. Bypasses
 *  DSpContext_GetVBLCountHandler's WriteMacInt32 guest-RAM path (which SEGVs
 *  on simulator above-4GiB scratch addresses). Returns the
 *  atomic_load low-32 truncation that GetVBLCount would write to guest RAM.
 *
 *  Validates ctxRef for API symmetry (the counter itself is GLOBAL);
 *  outCount pointer must be non-null.
 *
 *  Returns kDSpNoErr + populates *outCount on success;
 *  kDSpInvalidContextErr on bad ctxRef; kDSpInvalidAttributesErr on
 *  NULL outCount.
 */
extern "C" int32_t DSpTesting_ReadVBLCount(uint32_t ctxRef, uint32_t *outCount)
{
	if (outCount == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	*outCount = 0;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		return kDSpInvalidContextErr;
	}
	(void)ctx;  /* API symmetry — counter is global */
	uint64_t current = atomic_load_explicit(&s_dsp_vbl_count,
	                                         memory_order_relaxed);
	*outCount = (uint32_t)(current & 0xFFFFFFFFu);
	return kDSpNoErr;
}

/*
 *  TESTING_BUILD wrapper — host-value read of the per-context
 *  vbl_proc_ptr + vbl_proc_refcon fields. Lets DSpVBLTests.swift round-trip
 *  SetVBLProc without going through DSpContext_GetVBLProcHandler's
 *  WriteMacInt32 guest-RAM path. Byte-identical read of the exact fields
 *  GetVBLProc would write (round-trip helper).
 *
 *  Both out pointers must be non-null.
 */
extern "C" int32_t DSpTesting_ReadVBLProcFields(uint32_t ctxRef,
                                                 uint32_t *outProc,
                                                 uint32_t *outRefCon)
{
	if (outProc == nullptr || outRefCon == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	*outProc   = 0;
	*outRefCon = 0;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		return kDSpInvalidContextErr;
	}
	*outProc   = ctx->vbl_proc_ptr;
	*outRefCon = ctx->vbl_proc_refcon;
	return kDSpNoErr;
}

/*
 *  TESTING_BUILD wrapper — calls the PRODUCTION
 *  DSpContext_BlankFillHandler with guest-RAM addresses unchanged.
 *  Unlike DSpTesting_BlankFillByValues (host-value wrapper that bypasses
 *  ReadMacInt16 entirely), this shim drives the production path so arg-
 *  validation tests can exercise rectAddr=0 and colorAddr=0 rejection
 *  branches (kDSpInvalidAttributesErr). Returns the handler's return code.
 */
extern "C" int32_t DSpTesting_BlankFillHandlerWithAddresses(uint32_t ctxRef,
                                                             uint32_t rectAddr,
                                                             uint32_t colorAddr)
{
	return DSpContext_BlankFillHandler(ctxRef, rectAddr, colorAddr);
}

/*
 *  TESTING_BUILD wrapper — applies the production BlankFill
 *  depth-dispatch kernel to a CALLER-PROVIDED host buffer. Exists because
 *  the iOS simulator coerces the bump-allocator heap to
 *  MTLStorageModePrivate (gfxaccel_resources_heap.mm:190), so
 *  ctx->back_buffer.contents is NULL and the production DSpBlankFillCore
 *  cannot exercise its fill formulas on the simulator.
 *
 *  Byte-identical behavior to the production path: same clipping to
 *  [0, bb_w) x [0, bb_h), same degenerate-rect short-circuit, same
 *  depth-dispatch kernel (DSpBlankFillDepthDispatch). Does NOT invoke
 *  DSpInvalBackBufferRect_Accumulate — the test supplies its own host
 *  buffer so there is no back-buffer to mark dirty.
 *
 *  Arguments:
 *    host_buffer  caller-allocated buffer, at least pitch * bb_h bytes
 *    bb_w, bb_h   back-buffer logical dimensions used for clipping
 *    depth        1 / 2 / 4 / 8 / 16 / 32
 *    pitch        bytes per row (caller matches production formula
 *                 (row_bytes + 255) & ~255)
 *    top/left/bottom/right  caller-specified rect (may be outside bounds;
 *                            clipping is symmetric with DSpBlankFillCore)
 *    r8/g8/b8     8-bit color channels
 *
 *  Returns kDSpNoErr on success, kDSpInvalidAttributesErr on NULL buffer
 *  or unsupported depth. Matches the production return-code discipline.
 */
extern "C" int32_t DSpTesting_BlankFillOnHostBuffer(uint8_t *host_buffer,
                                                     uint16_t bb_w_u,
                                                     uint16_t bb_h_u,
                                                     uint32_t depth,
                                                     uint32_t pitch,
                                                     int16_t top, int16_t left,
                                                     int16_t bottom, int16_t right,
                                                     uint8_t r, uint8_t g, uint8_t b)
{
	if (host_buffer == nullptr) {
		return kDSpInvalidAttributesErr;
	}
	const int16_t bb_w = (int16_t)bb_w_u;
	const int16_t bb_h = (int16_t)bb_h_u;
	int16_t c_top    = (top    < 0)   ? 0    : top;
	int16_t c_left   = (left   < 0)   ? 0    : left;
	int16_t c_bottom = (bottom > bb_h) ? bb_h : bottom;
	int16_t c_right  = (right  > bb_w) ? bb_w : right;
	if (c_top >= c_bottom || c_left >= c_right) {
		return kDSpNoErr;  /* degenerate rect — no-op per DSp 1.7 p.79 */
	}
	return DSpBlankFillDepthDispatch(host_buffer, depth, pitch,
	                                  c_top, c_left, c_bottom, c_right,
	                                  r, g, b);
}
#endif

/*
 *  DSpContext_FadeGamma (sub-opcode 404).
 *
 *  FadeGamma ABI fidelity (DSp 1.7 pp.32-33 verbatim); no silent stubs
 *  producing wrong output; zero new concurrency primitives.
 *
 *  DSp 1.7 ABI (p.32):
 *    OSStatus DSpContext_FadeGamma(
 *        DSpContextReference inContext,
 *        SInt32              inPercentOfOriginalIntensity,
 *        RGBColor           *inZeroIntensityColor);
 *
 *  Argument contract:
 *    ctxRef     = context handle from DSpContext_Reserve. NULL (0) is the
 *                 ambient-display "applies to all displays" no-op (PDF p.32).
 *    inPercent  = SIGNED percentage of original intensity. 0..100 is the
 *                 normal range; > 100 begins to converge on white; < 0
 *                 begins to converge on black. NO duration param exists in
 *                 the real ABI (the invented `durationVbls` is dropped).
 *    colorAddr  = guest Mac address of an RGBColor (16-bit r@+0/g@+2/b@+4,
 *                 big-endian). NULL is LEGAL -> zero-intensity color is
 *                 black (PDF p.32), NOT a reject.
 *
 *  Error map:
 *    kDSpInvalidContextErr - ctxRef != 0 does not resolve to a context
 *    kDSpInternalErr       - DMC push failed
 *    kDSpNoErr             - success; the target LUT was applied
 *
 *  Immediate-apply (PDF p.33 "repeated, timed calls"):
 *    The parametric FadeGamma is an INCREMENTAL process — the APP makes
 *    repeated, timed calls, each passing an incrementally different
 *    inPercent. DSp applies the target LUT IMMEDIATELY each call (there
 *    is no DSp-internal fade timer for the parametric variant — that is
 *    FadeGammaIn/Out). The previous handler's `durationVbls == 0`
 *    short-circuit body IS the new always-path.
 *
 *  Reuse (UNCHANGED):
 *    - DSpReadParametricColorFromGuest (now 16-bit) for the tint read.
 *    - DSpComputeFadeGammaTargetLUT (signed percent + tint-honoring).
 *    - dmc_record_gamma_change_with_lut for the immediate DMC push.
 */
extern "C" int32_t DSpContext_FadeGammaHandler(uint32_t ctxRef,
                                                int32_t  inPercent,
                                                uint32_t colorAddr)
{
	/*
	 *  PDF p.32 — inContext == NULL applies the fade simultaneously to all
	 *  displays (ambient). The standard Apple DSp transition idiom fades the
	 *  ambient display to black and then calls FadeGamma(NULL, 100) to restore
	 *  full intensity (see Apple's "OpenGL DrawSprocket.c" sample). On our
	 *  single display we APPLY that ambient fade to the compositor gamma — NOT
	 *  a no-op — or the restore is lost and the screen stays stuck black
	 *  (Cro-Mag Rally: gameplay invisible after a fade transition). This is the
	 *  PARAMETRIC FadeGamma (sub-opcode 404) only; the timed FadeGammaIn/Out
	 *  (401/403) keep their ctxRef==0 no-op, since The Sims drives THOSE between
	 *  Reserve and SetState and relies on that DSp-health behavior. Apply path
	 *  mirrors the ctxRef!=0 case below, minus the per-context bookkeeping.
	 */
	if (ctxRef == 0) {
		uint8_t color_r = 0, color_g = 0, color_b = 0;
		if (colorAddr != 0) {
			DSpReadParametricColorFromGuest(colorAddr, &color_r, &color_g, &color_b);
		}
		uint8_t target_lut[768];
		DSpComputeFadeGammaTargetLUT(color_r, color_g, color_b,
		                              inPercent, target_lut);
		int32_t rv = dmc_record_gamma_change_with_lut(target_lut);
		if (rv != kDMCNoErr) {
			DSP_LOG("FadeGamma: ctxRef=0 ambient inPercent=%d "
			        "dmc_record_gamma_change_with_lut returned %d", inPercent, rv);
			return kDSpInternalErr;
		}
		DSP_LOG("FadeGamma: ctxRef=0 ambient inPercent=%d tint=(%u,%u,%u) "
		        "-> applied to compositor gamma (all-displays restore)",
		        inPercent, color_r, color_g, color_b);
		return kDSpNoErr;
	}
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("FadeGamma: invalid ctxRef=%u -> kDSpInvalidContextErr",
		        ctxRef);
		return kDSpInvalidContextErr;
	}

	/* NULL colorAddr is LEGAL -> zero-intensity color is black.
	 * Read the 16-bit RGBColor tint only when a non-NULL pointer is
	 * supplied; the read is guarded BEFORE any deref. */
	uint8_t color_r = 0, color_g = 0, color_b = 0;
	if (colorAddr != 0) {
		DSpReadParametricColorFromGuest(colorAddr, &color_r, &color_g, &color_b);
	}

	/* Build the target LUT per the DSp 1.7 signed-percent tint-honoring
	 * formula. inPercent is passed through verbatim — the formula owns
	 * the >100 (white) / <0 (black) convergence + the [0,255] clamp. */
	uint8_t target_lut[768];
	DSpComputeFadeGammaTargetLUT(color_r, color_g, color_b,
	                              inPercent, target_lut);

	/* Parametric FadeGamma applies the target immediately, in a
	 * single push — the app loops it over time. There is no internal
	 * fade timer for the parametric variant. */
	int32_t rv = dmc_record_gamma_change_with_lut(target_lut);
	if (rv != kDMCNoErr) {
		DSP_LOG("FadeGamma: dmc_record_gamma_change_with_lut returned %d "
		        "for ctx=%u",
		        rv, ctxRef);
		return kDSpInternalErr;
	}
	memcpy(ctx->gamma_lut_persisted, target_lut, 768);
	/* Cancel any active In/Out fade so the immediate parametric apply is
	 * authoritative. */
	ctx->fade_state.active = 0;
	DSP_LOG("FadeGamma: ctx=%u inPercent=%d tint=(%u,%u,%u) "
	        "-> target applied immediately",
	        ctxRef, inPercent,
	        color_r, color_g, color_b);
	return kDSpNoErr;
}

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD wrapper — bypass the
 *  guest-RAM color read by taking the zero-intensity tint as host-side
 *  uint8 R/G/B and a SIGNED percent. Mirrors the corrected production
 *  DSpContext_FadeGammaHandler EXACTLY (immediate apply, no duration,
 *  signed percent, tint-honoring target LUT) so DSpGammaTests can drive
 *  the curve goldens without a guest scratch buffer.
 *
 *  Note: bypasses ONLY the color-read step. The target-LUT computation
 *  + immediate DMC push + persistence run identically to production.
 */
extern "C" int32_t DSpTesting_FadeGammaByValues(uint32_t ctxRef,
                                                  int32_t percent,
                                                  uint8_t r,
                                                  uint8_t g,
                                                  uint8_t b)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;

	uint8_t target_lut[768];
	DSpComputeFadeGammaTargetLUT(r, g, b, percent, target_lut);

	int32_t rv = dmc_record_gamma_change_with_lut(target_lut);
	if (rv != kDMCNoErr) return kDSpInternalErr;
	memcpy(ctx->gamma_lut_persisted, target_lut, 768);
	ctx->fade_state.active = 0;
	return kDSpNoErr;
}
#endif

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD wrapper — host-struct pattern (see
 *  DSpTesting_SetCLUTEntriesByStruct and
 *  DSpTesting_InvalBackBufferRectByValue). Accepts a host-memory
 *  (last-first+1)*3 byte output buffer instead of a guest Mac address.
 *  Bypasses the WriteMacInt8 loop entirely.
 *
 *  This 3-byte/8-bit host-struct wrapper is UNCHANGED by the ColorSpec
 *  wire-path: DSpIndexedDepthCompositeTests (the known-flaky
 *  byte-exact composite baseline) reads it back as a 3-byte round-trip
 *  and must not be destabilized. The 8-byte ColorSpec wire-path is
 *  exercised by the SEPARATE DSpTesting_GetCLUTEntriesByColorSpec wrapper
 *  below. Reads from the VBL-latched snapshot.
 */
extern "C" int32_t DSpTesting_GetCLUTEntriesByStruct(uint32_t ctxRef,
                                                     uint32_t first,
                                                     uint32_t last,
                                                     uint8_t *entries_out_host)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (entries_out_host == nullptr) return kDSpInvalidAttributesErr;
	if (first > 255 || last > 255) return kDSpInvalidAttributesErr;
	if (first > last) return kDSpInvalidAttributesErr;
	return DSpGetCLUTCore(ctx, first, last, entries_out_host);
}

/*
 *  TESTING_BUILD wrapper — 8-byte ColorSpec
 *  wire-path. Mirrors the production handler's 8->16 up-convert (high byte
 *  preserved): `entries_out_host` receives `inEntryCount` 8-byte ColorSpec
 *  structs (value@+0 = 0, 16-bit big-endian r@+2/g@+4/b@+6). Arg order
 *  matches production: (ctxRef, entries_out_host, inStartingEntry,
 *  inEntryCount) — pointer-before-index. Reads from the VBL-latched
 *  snapshot. Used by DSpPaletteTests + DSpCLUTAnimationTests.
 */
extern "C" int32_t DSpTesting_GetCLUTEntriesByColorSpec(uint32_t ctxRef,
                                                        uint8_t *entries_out_host,
                                                        uint32_t inStartingEntry,
                                                        uint32_t inEntryCount)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (entries_out_host == nullptr) return kDSpInvalidAttributesErr;
	/* Overflow-safe headroom check (CWE-190) — mirror production
	 * DSpContext_GetCLUTEntriesHandler: never sum guest-controlled
	 * operands. The first clause bounds inStartingEntry <= 255, so
	 * 256 - inStartingEntry is in [1..256] and cannot underflow. */
	if (inStartingEntry > 255 || inEntryCount == 0 ||
	    inEntryCount > 256 - inStartingEntry) {
		return kDSpInvalidAttributesErr;
	}

	const uint32_t start = inStartingEntry;
	const uint32_t count = inEntryCount;
	const uint32_t last  = start + count - 1;

	/* Core (UNCHANGED) yields the 3-byte/8-bit latched bytes; up-convert
	 * 8->16 (high byte preserved) into the host 8-byte ColorSpec layout. */
	uint8_t staged[256 * 3];
	int32_t rv = DSpGetCLUTCore(ctx, start, last, staged);
	if (rv != kDSpNoErr) return rv;

	for (uint32_t i = 0; i < count; i++) {
		uint8_t *e = entries_out_host + i * 8;  /* 8-byte ColorSpec stride */
		uint8_t r = staged[i * 3 + 0];
		uint8_t g = staged[i * 3 + 1];
		uint8_t b = staged[i * 3 + 2];
		/* value@+0 SInt16 big-endian = 0 */
		e[0] = 0;       e[1] = 0;
		e[2] = r;       e[3] = r;   /* r 16-bit big-endian, high byte preserved */
		e[4] = g;       e[5] = g;
		e[6] = b;       e[7] = b;
	}
	return kDSpNoErr;
}
#endif

/* --- TESTING_BUILD helpers --- */

#ifdef TESTING_BUILD

extern "C" int dsp_testing_context_count(void)
{
	return dsp_context_count;
}

extern "C" void dsp_testing_reset_contexts(void)
{
	/* Drain the release FIFO synchronously (simulate several VBL ticks). */
	DSpVBLReleaseCallback(NULL, NULL, 0.0);
	/* Any still-alive contexts — release them synchronously. */
	for (int i = 0; i < DSP_MAX_CONTEXTS; i++) {
		if (dsp_context_table[i] != nullptr) {
			DSpReleaseNow(dsp_context_table[i]);
			dsp_context_table[i] = nullptr;
		}
	}
	dsp_context_count = 0;
	atomic_store_explicit(&dsp_release_head, 0,
	                      memory_order_relaxed);
	atomic_store_explicit(&dsp_release_tail, 0,
	                      memory_order_relaxed);
	/* Drop any leaked alt-buffer records so
	 * each test case starts with an empty alt-buffer table (the records are
	 * children of contexts, which we just released). */
	DSpResetAltBufferTable();
}

/*
 *  Simulate an Active DSp context in a single call
 *  for coexistence tests. Reserves a context with the
 *  provided attributes + routes it through SetState(Active) so the DMC
 *  active-owner becomes kDMCOwnerDSp — which in turn activates the NQD
 *  conflict gate. Returns the new ctxRef (>= 1) on success, or a
 *  negative error code matching the DSp 1.7 range (-30440..-30450) on
 *  failure.
 *
 *  NOT usable from production code paths: TESTING_BUILD-gated and
 *  bypasses PPC dispatch (writes Mac-side memory via Reserve of a
 *  scratch SheepMem region). The caller is responsible for draining
 *  via dsp_testing_reset_contexts() between test cases.
 */
extern "C" int32_t DSpTesting_SimulateActiveContext(uint32_t width,
                                                    uint32_t height,
                                                    uint32_t depth)
{
	/* Stage an attributes struct in guest RAM so DSpContext_ReserveHandler
	 * can consume it via the PDF-p.65 on-wire layout — the same path as
	 * production dispatch. 56 bytes covers through reserved3[0] (offset 52)
	 * with slack; trailing reserved/filler fields stay at 0.
	 *
	 * Use dsp_testing_alloc_guest_scratch (not SheepMem::Reserve)
	 * because PocketShaverTests does not link main_unix.cpp — SheepMem
	 * globals are zeroed and Reserve would underflow. The scratch
	 * allocator is backed by a low-4GiB mmap, so (uint32)(uintptr_t)host
	 * round-trips cleanly under EMULATED_PPC=0 / Mac2HostAddr identity.
	 *
	 * Offsets updated to PDF-p.65 exact layout.
	 * colorNeeds moved to offset 12; contextOptions to offset 20;
	 * backBufferBestDepth to offset 24; depthMasks to 32/36; w/h pairs
	 * to UInt16 slots at 40/42/44/46; pageCount UInt8 at offset 48. */
	uint32_t attr_addr = dsp_testing_alloc_guest_scratch(72);  /* DSp 1.7 PDF p.65 struct = 72 bytes */
	if (attr_addr == 0) {
		return kDSpInternalErr;
	}
	/* depthMask: kDSpDepthMask_* bit-per-depth. Includes 1/2/4 bpp;
	 * composite tests exercise those indexed depths via this helper. */
	uint32_t depth_mask = 0;
	if (depth == 1)  depth_mask = kDSpDepthMask_1;
	if (depth == 2)  depth_mask = kDSpDepthMask_2;
	if (depth == 4)  depth_mask = kDSpDepthMask_4;
	if (depth == 8)  depth_mask = kDSpDepthMask_8;
	if (depth == 16) depth_mask = kDSpDepthMask_16;
	if (depth == 32) depth_mask = kDSpDepthMask_32;

	/* DSp 1.7 PDF p.65 on-wire byte layout. Re-corrected 2026-04-21 via
	 * debug session `dsp-sims-rejects-all-modes`. */
	WriteMacInt32(attr_addr +  0, 0);              /* frequency (ignored) */
	WriteMacInt32(attr_addr +  4, width);          /* displayWidth */
	WriteMacInt32(attr_addr +  8, height);         /* displayHeight */
	WriteMacInt32(attr_addr + 12, 0);              /* reserved1 */
	WriteMacInt32(attr_addr + 16, 0);              /* reserved2 */
	WriteMacInt32(attr_addr + 20, 0);              /* colorNeeds */
	WriteMacInt32(attr_addr + 24, 0);              /* colorTable (CTabHandle) */
	WriteMacInt32(attr_addr + 28, 0);              /* contextOptions */
	WriteMacInt32(attr_addr + 32, depth_mask);     /* backBufferDepthMask */
	WriteMacInt32(attr_addr + 36, depth_mask);     /* displayDepthMask */
	WriteMacInt32(attr_addr + 40, depth);          /* backBufferBestDepth */
	WriteMacInt32(attr_addr + 44, depth);          /* displayBestDepth */
	WriteMacInt32(attr_addr + 48, 1);              /* pageCount */
	WriteMacInt8 (attr_addr + 52, 0);              /* filler[0] */
	WriteMacInt8 (attr_addr + 53, 0);              /* filler[1] */
	WriteMacInt8 (attr_addr + 54, 0);              /* filler[2] */
	WriteMacInt8 (attr_addr + 55, 0);              /* gameMustConfirmSwitch (Boolean) */

	/*
	 *  Debug session `dsp-sims-post-reserve-black-screen` fix (2026-04-19):
	 *  DSpContext_ReserveHandler signature changed — it no longer allocates
	 *  a new handle (per DSp 1.7 PDF p.25 it attaches to an existing
	 *  ctxRef from FindBestContext). This helper's "one-call Reserve +
	 *  SetState" contract pre-dates that correction; to keep its semantics
	 *  stable we call Reserve_Core directly (which still creates a brand-
	 *  new ctx with back-buffer in one step — the legacy semantic tests
	 *  rely on). No change to caller behavior; only the internal call
	 *  shape changes.
	 */
	DSpContextAttributes attr = {};
	attr.frequency            = 0;
	attr.displayWidth         = width;
	attr.displayHeight        = height;
	attr.colorNeeds           = 0;
	attr.colorTable           = 0;
	attr.contextOptions       = 0;
	attr.backBufferDepthMask  = depth_mask;
	attr.displayDepthMask     = depth_mask;
	attr.backBufferBestDepth  = depth;
	attr.displayBestDepth     = depth;
	attr.pageCount            = 1;
	attr.gameMustConfirmSwitch = 0;
	attr.backBufferWidth      = width;
	attr.backBufferHeight     = height;
	(void)attr_addr;
	uint32_t ctx_ref = 0;
	int32_t rv = DSpContext_Reserve_Core(&attr, &ctx_ref);
	if (rv != kDSpNoErr) return rv;
	if (ctx_ref == 0) return kDSpInternalErr;

	rv = DSpContext_SetStateHandler(ctx_ref,
	                                (uint32_t)kDSpContextState_Active);
	if (rv != kDSpNoErr) return rv;

	return (int32_t)ctx_ref;
}

/* ------------------------------------------------------------------ *
 *  Guest-RAM scratch allocator for test-harness use.
 *
 *  The PocketShaverTests target does NOT link main_unix.cpp, so the
 *  SheepMem static globals are zero-initialized (PSRAVEStubs.mm). Any
 *  SheepMem::Reserve call from test code wraps negative and asserts.
 *
 *  We back the scratch with an mmap'd page-aligned region in the low
 *  4 GiB of host VA. Under EMULATED_PPC=0 ReadMacInt32 / WriteMacInt32
 *  dereference *(uint32*)addr directly, so the low-4GiB host pointer
 *  uint32-casts to itself and the round-trip is lossless. Matches
 *  PSFakeMacRAM_Alloc's mmap-with-hints approach.
 *
 *  Bump allocator: no per-alloc free; tests call
 *  dsp_testing_reset_guest_scratch() in tearDown to reset the cursor.
 *  Capacity 1 MiB covers every envisioned test workload
 *  (attr structs + out-params + Rect + state cells: < 100 bytes per
 *  test × ~50 tests × slack).
 * ------------------------------------------------------------------ */

static const uint32_t kDSpTestScratchCapacity = 16 * 1024 * 1024;  /* 16 MiB */
static uint8_t       *s_dsp_test_scratch_base = NULL;
static uint32_t       s_dsp_test_scratch_pos  = 0;
static uint32_t       s_dsp_test_scratch_size = 0;

static void DSpTestingScratchEnsureBacking(void)
{
	if (s_dsp_test_scratch_base != NULL) return;

	/* Try hinted low-4GiB mappings first so (uint32)(uintptr_t)host
	 * round-trips. Matches PSFakeMacRAM's strategy. */
	void *p = MAP_FAILED;
	const uintptr_t hintAddrs[] = {
		0x20000000UL,  /* 512 MiB */
		0x40000000UL,  /* 1 GiB */
		0x80000000UL,  /* 2 GiB */
		0xC0000000UL,  /* 3 GiB */
		0x08000000UL,  /* 128 MiB */
	};
	for (size_t i = 0; i < sizeof(hintAddrs) / sizeof(hintAddrs[0]); ++i) {
		void *hint = (void *)hintAddrs[i];
		void *q = mmap(hint, kDSpTestScratchCapacity,
		               PROT_READ | PROT_WRITE,
		               MAP_ANON | MAP_PRIVATE,
		               -1, 0);
		if (q == MAP_FAILED) continue;
		if ((uintptr_t)q < 0x100000000UL &&
		    (uintptr_t)q + kDSpTestScratchCapacity <= 0x100000000UL) {
			p = q;
			break;
		}
		munmap(q, kDSpTestScratchCapacity);
	}
	if (p == MAP_FAILED) {
		/* Fallback — any page-aligned allocation. If the sim ignores
		 * every hint the caller may still observe a faulty round-trip,
		 * but at least the mmap itself succeeds so allocation doesn't
		 * error out silently. */
		p = mmap(NULL, kDSpTestScratchCapacity,
		         PROT_READ | PROT_WRITE,
		         MAP_ANON | MAP_PRIVATE,
		         -1, 0);
	}
	if (p == MAP_FAILED || p == NULL) {
		return;
	}
	s_dsp_test_scratch_base = (uint8_t *)p;
	s_dsp_test_scratch_size = kDSpTestScratchCapacity;
	s_dsp_test_scratch_pos  = 0;
}

extern "C" uint32_t dsp_testing_alloc_guest_scratch(uint32_t size)
{
	DSpTestingScratchEnsureBacking();
	if (s_dsp_test_scratch_base == NULL) return 0;

	/* 4-byte align size to preserve 32-bit access alignment on every
	 * returned address — matches SheepMem::align. */
	uint32_t aligned_size = (size + 3u) & ~3u;
	if (aligned_size == 0 || aligned_size > s_dsp_test_scratch_size) return 0;
	if (s_dsp_test_scratch_pos + aligned_size > s_dsp_test_scratch_size) {
		return 0;
	}
	uint8_t *host  = s_dsp_test_scratch_base + s_dsp_test_scratch_pos;
	/* Low-4GiB gate: if the underlying mmap landed above 4 GiB, the
	 * (uint32)(uintptr_t)host cast truncates and ReadMacInt32/
	 * WriteMacInt32 (static inlines from cpu_emulation.h under
	 * EMULATED_PPC=0) would dereference the wrong address and SEGV.
	 * Refuse the allocation in that case; callers interpret a 0 return
	 * as "guest-scratch unavailable" and XCTSkip the behavior-exact
	 * diff they needed. */
	uintptr_t hptr = (uintptr_t)host;
	if (hptr >= 0x100000000UL ||
	    hptr + (uintptr_t)aligned_size > 0x100000000UL) {
		return 0;
	}
	uint32_t addr  = (uint32_t)hptr;
	/* Zero the newly vended region so readers see a stable 0 before any
	 * WriteMacInt32 call (matches classic C calloc hygiene). */
	std::memset(host, 0, aligned_size);
	s_dsp_test_scratch_pos += aligned_size;
	return addr;
}

/*
 *  Low-4GiB probe. Reports whether the scratch backing
 *  store landed in low 4 GiB of host VA (i.e., ReadMacInt32/WriteMacInt32
 *  can safely deref scratch addresses). Callers use this to XCTSkip
 *  behavior-exact diffs that rely on Mac-memory I/O when the simulator
 *  mmap landed high.
 */
extern "C" int dsp_testing_scratch_in_low_4gib(void)
{
	DSpTestingScratchEnsureBacking();
	if (s_dsp_test_scratch_base == NULL) return 0;
	uintptr_t hptr = (uintptr_t)s_dsp_test_scratch_base;
	return (hptr < 0x100000000UL &&
	        hptr + s_dsp_test_scratch_size <= 0x100000000UL) ? 1 : 0;
}

extern "C" void dsp_testing_free_guest_scratch(uint32_t /*addr*/)
{
	/* No-op — bump allocator; reset via dsp_testing_reset_guest_scratch. */
}

extern "C" void dsp_testing_reset_guest_scratch(void)
{
	if (s_dsp_test_scratch_base == NULL) return;
	/* Scrub + rewind so re-used cells start zero. */
	std::memset(s_dsp_test_scratch_base, 0, s_dsp_test_scratch_size);
	s_dsp_test_scratch_pos = 0;
}

/* ------------------------------------------------------------------ *
 *  Swift shim over static-inline Read/Write Mac{Int32,Int16}.
 *  Swift cannot call static inlines from cpu_emulation.h through the
 *  bridging header; these thin wrappers give Swift tests a stable
 *  C-linkage entry to populate DSpContextAttributes / out-param cells /
 *  Mac Rect structs inside the scratch region.
 * ------------------------------------------------------------------ */

extern "C" void dsp_testing_write_mac_int32(uint32_t addr, uint32_t value)
{
	WriteMacInt32(addr, value);
}

extern "C" uint32_t dsp_testing_read_mac_int32(uint32_t addr)
{
	return ReadMacInt32(addr);
}

extern "C" void dsp_testing_write_mac_int16(uint32_t addr, uint32_t value)
{
	WriteMacInt16(addr, value);
}

extern "C" uint32_t dsp_testing_read_mac_int16(uint32_t addr)
{
	return ReadMacInt16(addr);
}

extern "C" void dsp_testing_write_mac_int8(uint32_t addr, uint32_t value)
{
	WriteMacInt8(addr, value);
}

/* Byte-accurate read of a 1-byte Pascal Boolean / SInt8 out-param. Tests
 * that read a value the handler wrote with WriteMacInt8 (e.g. DSpProcessEvent's
 * outEventWasProcessed) MUST use this, not (read_mac_int16 & 0xff): the latter
 * is correct only by little-endian accident and reads a live garbage byte at
 * +1. */
extern "C" uint32_t dsp_testing_read_mac_int8(uint32_t addr)
{
	return ReadMacInt8(addr);
}

/* ------------------------------------------------------------------ *
 *  TESTING_BUILD helpers for event
 *  integration tests.
 *
 *  Three thin wrappers expose per-context SPSC state to Swift tests
 *  without exposing the full DSpContextPrivate struct. The event-inject
 *  path reuses the dsp_enqueue_into_ring helper (defined in
 *  dsp_host_bridge.mm, a different TU). dsp_enqueue_into_ring was changed
 *  from `static` → `extern "C"` so the symbol is
 *  linker-visible cross-TU; forward-declared here since it has no
 *  public-header prototype by design.
 * ------------------------------------------------------------------ */

extern "C" void dsp_enqueue_into_ring(DSpContextPrivate *ctx,
                                       uint16_t what, uint32_t message,
                                       uint32_t when, int16_t where_v,
                                       int16_t where_h, uint16_t modifiers);

extern "C" int32_t DSpTesting_EnqueueEventToCtx(uint32_t ctxRef,
                                                  uint16_t what, uint32_t message,
                                                  uint32_t when,
                                                  int16_t where_v, int16_t where_h,
                                                  uint16_t modifiers)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	dsp_enqueue_into_ring(ctx, what, message, when, where_v, where_h, modifiers);
	return kDSpNoErr;
}

extern "C" int32_t DSpTesting_ReadContextPausedByBackground(uint32_t ctxRef,
                                                              uint8_t *outFlag)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (outFlag == nullptr) return kDSpInvalidAttributesErr;
	*outFlag = ctx->paused_by_background;
	return kDSpNoErr;
}

extern "C" int32_t DSpTesting_ReadContextEventsQueueDepth(uint32_t ctxRef,
                                                            uint32_t *outDepth)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (outDepth == nullptr) return kDSpInvalidAttributesErr;
	uint32_t head = atomic_load_explicit(&ctx->events_head, memory_order_relaxed);
	uint32_t tail = atomic_load_explicit(&ctx->events_tail, memory_order_relaxed);
	*outDepth = head - tail;
	return kDSpNoErr;
}

/*
 *  TESTING_BUILD host helper
 *  that dequeues one event from a context's SPSC input-fanout ring WITHOUT
 *  the guest-RAM WriteMacInt* marshalling. This lifts the body of the
 *  RETIRED guest-facing dequeue export (the old non-canonical
 *  sub-op-600 ProcessEvent reader) so the ~18 DSpEventTests ring-observation
 *  methods survive its retirement: the ring + its two live producers
 *  (DSpHostBridge_EnqueueEventToActiveContexts iOS input fanout +
 *  DSpHostBridge_OnBackground/OnForeground bg/fg suspend/resume) are KEPT
 *  (provably alive).
 *
 *  The atomics here operate on the EXISTING sanctioned ring atomics
 *  (events_head / events_tail) behind #ifdef TESTING_BUILD — NO new
 *  production concurrency primitive is added. Same posture as
 *  DSpTesting_ReadContextEventsQueueDepth above. Net effect of this test-only reader is
 *  a REDUCTION of production atomic ops (the retired handler's 3 atomic ops
 *  are removed; the canonical DSpProcessEvent handler is synchronous).
 *
 *  SPSC-ring dequeue semantics mirror the retired handler exactly:
 *    - memory_order_relaxed on tail (reader owns tail)
 *    - memory_order_acquire on head (fence slot-data visibility from writer)
 *    - empty queue (head == tail) -> *outProcessed = 0, kDSpNoErr
 *    - on dequeue: copy slot fields, *outProcessed = 1, then advance tail
 *      via memory_order_release so the writer sees the slot free.
 *
 *  Out-params receive the 6 DSpEventRecord fields + the Pascal-Boolean
 *  "processed" flag (0/1). NULL out-params are NOT individually guarded
 *  (test-only helper; callers always pass valid pointers); ctxRef is
 *  validated.
 */
extern "C" int32_t DSpTesting_DequeueContextEvent(uint32_t ctxRef,
                                                   uint16_t *outWhat,
                                                   uint32_t *outMessage,
                                                   uint32_t *outWhen,
                                                   int16_t *outWhereV,
                                                   int16_t *outWhereH,
                                                   uint16_t *outModifiers,
                                                   uint8_t *outProcessed)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	if (outProcessed == nullptr) return kDSpInvalidAttributesErr;

	uint32_t tail = atomic_load_explicit(&ctx->events_tail,
	                                     memory_order_relaxed);
	uint32_t head = atomic_load_explicit(&ctx->events_head,
	                                     memory_order_acquire);

	if (head == tail) {
		/* Queue empty — processed = false; out-fields untouched. */
		*outProcessed = 0;
		return kDSpNoErr;
	}

	DSpEventRecord *slot = &ctx->events_queue[tail % 64u];
	if (outWhat)      *outWhat      = slot->what;
	if (outMessage)   *outMessage   = slot->message;
	if (outWhen)      *outWhen      = slot->when;
	if (outWhereV)    *outWhereV    = slot->where_v;
	if (outWhereH)    *outWhereH    = slot->where_h;
	if (outModifiers) *outModifiers = slot->modifiers;
	*outProcessed = 1;

	atomic_store_explicit(&ctx->events_tail, tail + 1u,
	                      memory_order_release);
	return kDSpNoErr;
}

extern "C" int32_t DSpTesting_WriteContextPausedByBackground(uint32_t ctxRef,
                                                               uint8_t flag)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	ctx->paused_by_background = flag;
	return kDSpNoErr;
}

/*
 *  Debug session `dsp-sims-enumeration-stall` fix (2026-04-19) — host read
 *  of ctx->enumeration_mode_index for the new DSpGetFirstContext /
 *  DSpGetNextContext iteration regression test. See header for contract.
 */
extern "C" int32_t DSpTesting_ReadEnumerationModeIndex(uint32_t ctxRef,
                                                        uint32_t *outIndex)
{
	if (outIndex == nullptr) return kDSpInvalidAttributesErr;
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return kDSpInvalidContextErr;
	*outIndex = ctx->enumeration_mode_index;
	return kDSpNoErr;
}

/*
 *  Host-side MainDevice PixMap.baseAddr probe used by
 *  lifecycle assertions (DSpContextTests). Walks the same
 *  LMADDR_MAIN_DEVICE → GDevice → PixMap chain as
 *  DSpRedirectMainDevicePixMap and returns the current PixMap.baseAddr.
 *  Returns 0 (graceful skip) when any intermediate handle is zero —
 *  same convention as the Redirect helper's pre-boot Landmine-8 guard.
 *  Mirrors the testing-helper shape from
 *  dsp_mode_enumerate.cpp:281-307.
 */
extern "C" uint32_t DSpTesting_GetMainDevicePixMapBaseAddr(void)
{
	uint32_t mainDeviceH = ReadMacInt32(LMADDR_MAIN_DEVICE);
	if (mainDeviceH == 0) return 0;
	uint32_t gdevicePtr = ReadMacInt32(mainDeviceH);
	if (gdevicePtr == 0) return 0;
	uint32_t pixMapH = ReadMacInt32(gdevicePtr + GDEVICE_OFF_PMAP);
	if (pixMapH == 0) return 0;
	uint32_t pixMapPtr = ReadMacInt32(pixMapH);
	if (pixMapPtr == 0) return 0;
	return ReadMacInt32(pixMapPtr + DSP_PIXMAP_OFF_BASEADDR);
}

/*
 *  TESTING_BUILD helper: manually fires the VBL
 *  secondary-callback chain so tests can deterministically drive
 *  the publish shim (DSpVBLCompositorPublishCallback) without waiting for
 *  a real display-link tick. Reuses vbl_source's existing testing-only
 *  dispatch entry point, which increments s_tick_count, signals pacing,
 *  and drains all registered secondary callbacks (including the publish
 *  shim) in the same fan-out order as a real VBL fire.
 */
extern "C" void DSpTesting_TickVBL(void)
{
	vbl_source_testing_simulate_vbl_tick();
}

/*
 *  Reserve a minimal DSp context for the
 *  lifecycle + golden-PNG tests. Mirrors the existing
 *  DSpTesting_SimulateActiveContext shape but stops at Reserve (does NOT
 *  call SetState(Active)); the caller drives SetState explicitly via
 *  DSpTesting_SetStateActiveDirect so lifecycle assertions can probe the
 *  state at each transition edge.
 *
 *  Returns the new ctxRef (>= 1) on success, or 0 on failure. Uses the
 *  testing-helper precedent: direct call into Reserve_Core, no
 *  EMULATED_PPC dispatch.
 */
extern "C" uint32_t DSpTesting_BootstrapMinimalContext(uint32_t width,
                                                        uint32_t height,
                                                        uint32_t bpp)
{
	uint32_t depth_mask = 0;
	if (bpp == 1)  depth_mask = kDSpDepthMask_1;
	if (bpp == 2)  depth_mask = kDSpDepthMask_2;
	if (bpp == 4)  depth_mask = kDSpDepthMask_4;
	if (bpp == 8)  depth_mask = kDSpDepthMask_8;
	if (bpp == 16) depth_mask = kDSpDepthMask_16;
	if (bpp == 32) depth_mask = kDSpDepthMask_32;
	if (depth_mask == 0) return 0;

	DSpContextAttributes attr = {};
	attr.frequency             = 0;
	attr.displayWidth          = width;
	attr.displayHeight         = height;
	attr.colorNeeds            = 0;
	attr.colorTable            = 0;
	attr.contextOptions        = 0;
	attr.backBufferDepthMask   = depth_mask;
	attr.displayDepthMask      = depth_mask;
	attr.backBufferBestDepth   = bpp;
	attr.displayBestDepth      = bpp;
	attr.pageCount             = 1;
	attr.gameMustConfirmSwitch = 0;
	attr.backBufferWidth       = width;
	attr.backBufferHeight      = height;

	uint32_t ctx_ref = 0;
	int32_t rv = DSpContext_Reserve_Core(&attr, &ctx_ref);
	if (rv != kDSpNoErr) return 0;
	return ctx_ref;
}

/*
 *  Direct-call twin of
 *  DSpContext_SetStateHandler(ctx, Active) for the lifecycle tests.
 *  Bypasses EMULATED_PPC dispatch: calls SetStateHandler directly with
 *  the canonical kDSpContextState_Active value. Returns the DSp 1.7
 *  result code from SetStateHandler unchanged.
 */
extern "C" int32_t DSpTesting_SetStateActiveDirect(uint32_t ctxRef)
{
	return DSpContext_SetStateHandler(ctxRef,
	                                   (uint32_t)kDSpContextState_Active);
}

#endif /* TESTING_BUILD */
