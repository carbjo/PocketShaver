/*
 *  dsp_draw_context.mm - DSp per-context state table, Reserve/Release
 *                         lifecycle, and VBL-bounded release FIFO.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Also holds the GetBackBuffer/SwapBuffers/SetState/GetState/
 *  InvalBackBufferRect handler bodies.
 */

#import <Metal/Metal.h>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "dsp_engine.h"
#include "dsp_event_record.h"
#include "dsp_draw_context.h"
#include "dsp_mode_enumerate.h"
#include "dsp_user_select_policy.h"
#include "dsp_context_private.h"
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
#include "dsp_pixmap_offsets.h"
#include "dsp_back_buffer_range.h"
#include "dsp_metal_renderer.h"
#include "gfxaccel_threading_policy.h"
#include "gfxaccel_resources.h"
#include "gfxaccel_resources_heap.h"
#include "dsp_alt_buffer.h"
#include "dsp_clut_gamma.h"
#include "nqd_accel.h"
#include "metal_compositor.h"
#include "metal_device_shared.h"
#include "display_mode_controller.h"
#include "dsp_engine_internal.h"
#include "vbl_source.h"

#include <cstring>
#include <cassert>
#include <stdatomic.h>
#include <unistd.h>


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
	ctx->front_staging_row_bytes = 0;
	ctx->front_staging_height = 0;
	ctx->front_staging_present_state = {};
}

/* Called when the "any DSp context Active?" predicate changes. */
extern "C" void DSpHostBridge_SetActiveFullscreen(bool active);
extern "C" bool DSpHostBridge_GetActiveFullscreen(void);

/* MainDevice PixMap redirect/restore, defined near
 * DSpContext_SetStateHandler; the release and bg/fg paths below need them. */
extern "C" void DSpRedirectMainDevicePixMap(DSpContextPrivate *ctx);
static bool DSpPixMapLooksLikeContextRedirect(DSpContextPrivate *ctx,
                                              uint32_t pixMapPtr);
extern "C" void DSpRestoreMainDevicePixMap(DSpContextPrivate *ctx);

/* GetBackBuffer underlay restore (DSp PDF p.51 "clean a back buffer").
 * Defined in the AltBuffer section below. */
static void DSpRestoreBackBufferFromUnderlay(DSpContextPrivate *ctx);
static void DSpSaveUnderlayRestoreRegion(DSpContextPrivate *ctx);

/* Canonical definition is in dsp_draw_context.h; this is a fallback. */
#ifndef DSP_MAX_CONTEXTS
#define DSP_MAX_CONTEXTS             8
#endif
#define DSP_RELEASE_QUEUE_CAPACITY  16   /* full FIFO falls back to immediate release */

/* Upper bound on fade duration so ctx->fade_state.elapsed_vbls (uint16_t)
 * cannot overflow. ~68 s at 60 Hz. DSp 1.7 sets no limit; longer requests
 * are clamped with a log warning. */
#define DSP_MAX_FADE_VBLS 4096

/* --- Context table (1-based handles; slot 0 reserved) --- */

static DSpContextPrivate *dsp_context_table[DSP_MAX_CONTEXTS] = {};
static int                dsp_context_count                   = 0;
/* Last context to publish a displayed fade; zero denotes an ambient fade. */
static uint32_t           s_dsp_gamma_context                  = 0;

/* VBL tick counter. DSpVBLServiceCallback increments it on the emul thread
 * and passes it as the vblCount argument (r5) to user VBLProcs. Stored as
 * 64 bits, truncated to the DSp 1.7 UInt32 at the call site (spec p.81). */
static _Atomic uint64_t s_dsp_vbl_count = 0;

extern "C" DSpContextPrivate *DSpGetContext(uint32_t handle)
{
	if (handle == 0 || handle > DSP_MAX_CONTEXTS) return nullptr;
	return dsp_context_table[handle - 1];
}

/* C accessor for dsp_mode_enumerate.cpp, which cannot see the
 * DSpContextPrivate layout. */
extern "C" uint32_t DSpGetContextEnumerationIndex(uint32_t ctxRef)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) return DSP_ENUMERATION_INDEX_NONE;
	return ctx->enumeration_mode_index;
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
		/* Handles are slot indices and can be reused immediately. A queued
		 * switch must not follow this slot into an unrelated replacement. */
		for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; ++i) {
			DSpContextPrivate *parent = dsp_context_table[i];
			if (parent != nullptr && parent->queued_child == handle)
				parent->queued_child = 0;
		}
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
static _Atomic uint32_t   dsp_release_head = 0;  /* producer writes */
static _Atomic uint32_t   dsp_release_tail = 0;  /* VBL drain writes */

/* Set while DSpDrainLifecycleSync drains. On the background edge,
 * gfxaccel_handle_background_enter has already waited for an empty command
 * buffer on the shared queue, so all GPU work touching the DSp heap is done.
 * Resets from that drain may skip the GPU-completion latch; deferring would
 * hang because the paused VBL source never retries. The foreground edge has
 * the same guarantee: VBL stayed paused and back buffers were already
 * released. Emul thread only. */
static bool dsp_lifecycle_gpu_drained = false;

static void DSpResetHeapIfIdle(const char *reason)
{
	uint32_t live = gfxaccel_resources_heap_live_allocation_count(kHeapEngineDSp);
	if (live != 0) {
		return;
	}
	/* gfxaccel_resources_heap_reset defers while a noted command buffer
	 * (SwapBuffers / VBL-publish present) is in flight; the VBL release
	 * drain retries every tick. */
	uint64_t reclaimed = dsp_lifecycle_gpu_drained
	    ? gfxaccel_resources_heap_reset_gpu_idle(kHeapEngineDSp)
	    : gfxaccel_resources_heap_reset(kHeapEngineDSp);
	if (reclaimed > 0) {
		DSP_LOG("DSp heap reset after %s reclaimed %llu bytes",
		        reason ? reason : "release",
		        (unsigned long long)reclaimed);
	}
}

static void DSpReleaseNow(DSpContextPrivate *ctx)
{
	DSpRestoreMainDevicePixMap(ctx);  /* Drop the PixMap redirect before back_buffer goes away. */
	/* Clear the owner tag before the buffer goes away. */
	if (ctx->back_buffer != nil) {
		gfxaccel_resources_clear_buffer_owner(
		    (__bridge void *)ctx->back_buffer);
		gfxaccel_resources_heap_note_allocation_released(kHeapEngineDSp);
	}
	/* Release the texture view before its buffer; some iOS Metal drivers
	 * depend on that order. */
	ctx->back_texture = nil;
	ctx->back_buffer  = nil;
	DSpReleaseBackBufferStaging(ctx);
	ctx->cgrafptr_mac_addr = 0;
	DSpReleaseFrontBufferStaging(ctx);
	delete ctx;
	DSpResetHeapIfIdle("synchronous release");
}

static void DSpQueueReleaseAtVBL(DSpContextPrivate *ctx)
{
	DSpRestoreMainDevicePixMap(ctx);  /* Drop the PixMap redirect before back_buffer goes away. */
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
	/* Clear the owner tag now, not at drain: DSp ownership ends when
	 * Release is requested. The Metal refcount drop waits for the VBL. */
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
 *  Like DSpQueueReleaseAtVBL but keeps the DSpContextPrivate alive in the
 *  table (ctx_to_free = nullptr); only the Metal buffer and texture are
 *  released. Foreground restore reallocates into the same struct.
 *  Used only by DSpHandleBackgroundFromEmulThread.
 */
static void DSpQueueReleaseAtVBLPartial(DSpContextPrivate *ctx)
{
	// The compositor target may be overwritten/recreated while suspended.
	// Retain guest bytes, but force the first active publish to restore them.
	ctx->front_staging_present_state.encoded = false;
	DSpRestoreMainDevicePixMap(ctx);  /* Drop the PixMap redirect before back_buffer goes away. */
	// Without guest staging, MainDevice or a cached port may expose the
	// Metal allocation directly. Retain it until the context is released.
	if (ctx->back_buffer != nil && ctx->staging_mac_addr == 0) return;
	uint32_t head = atomic_load_explicit(&dsp_release_head,
	                                      memory_order_relaxed);
	uint32_t next = (head + 1) % DSP_RELEASE_QUEUE_CAPACITY;
	uint32_t tail = atomic_load_explicit(&dsp_release_tail,
	                                      memory_order_acquire);
	/* Clear the owner tag; foreground restore re-tags the new buffer. */
	if (ctx->back_buffer != nil) {
		gfxaccel_resources_clear_buffer_owner(
		    (__bridge void *)ctx->back_buffer);
	}
	if (next == tail) {
		DSP_LOG("DSpQueueReleaseAtVBLPartial: FIFO full, falling back "
		        "to synchronous partial release (cap=%d)",
		        DSP_RELEASE_QUEUE_CAPACITY);
		/* Synchronous partial release, texture first. The struct is
		 * kept for foreground restore. */
		if (ctx->back_buffer != nil) {
			gfxaccel_resources_heap_note_allocation_released(kHeapEngineDSp);
		}
		ctx->back_texture = nil;
		ctx->back_buffer  = nil;
		DSpResetHeapIfIdle("synchronous partial release");
		return;
	}
	dsp_release_queue[head].back_buffer  = ctx->back_buffer;
	dsp_release_queue[head].back_texture = ctx->back_texture;
		dsp_release_queue[head].ctx_to_free  = nullptr;   /* struct stays alive */
	ctx->back_buffer  = nil;
	ctx->back_texture = nil;
	atomic_store_explicit(&dsp_release_head, next,
	                      memory_order_release);
}

static void DSpDrainReleaseQueue(void)
{
	uint32_t tail = atomic_load_explicit(&dsp_release_tail,
	                                      memory_order_relaxed);
	uint32_t head = atomic_load_explicit(&dsp_release_head,
	                                      memory_order_acquire);
	while (tail != head) {
		DSpReleaseEntry *entry = &dsp_release_queue[tail];
		/* Drop texture reference first, buffer second. */
		entry->back_texture = nil;
		if (entry->back_buffer != nil) {
			gfxaccel_resources_heap_note_allocation_released(kHeapEngineDSp);
		}
		entry->back_buffer  = nil;
		if (entry->ctx_to_free != nullptr) {
			delete entry->ctx_to_free;
			entry->ctx_to_free = nullptr;
		}
		tail = (tail + 1) % DSP_RELEASE_QUEUE_CAPACITY;
	}
	atomic_store_explicit(&dsp_release_tail, tail,
	                      memory_order_release);
	DSpResetHeapIfIdle("VBL release drain");
}

extern "C" void DSpVBLReleaseCallback(void * /*ctx*/,
                                       void * /*drawable*/,
                                       double /*ts*/)
{
	DSpDrainReleaseQueue();

	/* Background/foreground transitions run after releases. */
	DSpVBLBackgroundForegroundDrain();
}

/*
 *  VBL secondary callback (registered in DSpInit). Runs after the
 *  compositor's palette latch and copies each context's clut_bytes into
 *  clut_bytes_latched, so GetCLUTEntries reads the value as of the last
 *  VBL rather than an in-flight Set. Emul thread, same as SetCLUTEntries.
 */
extern "C" void DSpVBLClutLatchCallback(void *cb_ctx, void *drawable, double ts)
{
	(void)cb_ctx; (void)drawable; (void)ts;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		/* Snapshot all contexts: Paused ones can still Get their CLUT. */
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
 *  Linear LUT interpolation with round-to-nearest, so long fades don't drift:
 *    out[i] = (start[i] * (duration - elapsed) + end[i] * elapsed
 *              + duration / 2) / duration
 *  Max product 255 * 4096 fits in uint32_t at DSP_MAX_FADE_VBLS.
 *  Caller guarantees duration > 0 and elapsed < duration (zero-length
 *  fades and the final frame push end_lut directly).
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
 *  Build the FadeGamma target LUT from the zero-intensity tint (8-bit) and
 *  a signed percent of original intensity (DSp 1.7 pp.32-33):
 *    100%    -> full_lut, the driver's installed gamma table (not identity)
 *    0%      -> the tint (black when the guest passed NULL)
 *    0..100% -> linear blend tint -> full_lut
 *    >100%   -> converge toward white, reaching 255 at 200%
 *    <0%     -> converge from the tint toward black, reaching 0 at -100%
 *  Results are clamped to [0,255].
 */
static void DSpComputeFadeGammaTargetLUT(uint8_t color_r,
                                          uint8_t color_g,
                                          uint8_t color_b,
                                          int32_t percent,
                                          const uint8_t *full_lut,
                                          uint8_t *out_lut)
{
	const uint8_t channels[3] = { color_r, color_g, color_b };
	for (uint32_t c = 0; c < 3; c++) {
		const int32_t tint = (int32_t)channels[c];
		for (uint32_t i = 0; i < 256; i++) {
			/* Games install functional ramps (e.g. overbright doubling),
			 * so 100% must land on the driver table, not identity. */
			const int32_t full = (int32_t)full_lut[c * 256 + i];
			int32_t v;
			if (percent <= 0) {
				/* 0% -> tint, -100% and below -> 0. */
				int32_t t = -percent;            /* 0..(+inf) */
				if (t > 100) t = 100;
				v = (tint * (100 - t)) / 100;
			} else if (percent >= 100) {
				/* 100% -> driver table, 200% and above -> 255. */
				int32_t t = percent - 100;       /* 0..(+inf) */
				if (t > 100) t = 100;
				v = full + ((255 - full) * t) / 100;
			} else {
				v = (tint * (100 - percent) + full * percent) / 100;
			}
			if (v < 0)   v = 0;
			if (v > 255) v = 255;
			out_lut[c * 256 + i] = (uint8_t)v;
		}
	}
}

/*
 *  Copy the driver's current gamma table (the guest's last SetGamma) from the
 *  DMC snapshot. This is "original intensity" for the fades. Falls back to
 *  identity when there is no snapshot yet (pre-SetGamma boot state).
 */
static void DSpCopyDriverGammaLUT(uint8_t out_lut[768])
{
	const struct DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap != nullptr) {
		memcpy(out_lut, snap->driver_gamma_lut, 768);
		return;
	}
	for (uint32_t c = 0; c < 3; c++) {
		for (uint32_t i = 0; i < 256; i++) {
			out_lut[c * 256 + i] = (uint8_t)i;
		}
	}
}

/* Publish fade ownership together with the DMC's LUT/flag update. */
static int32_t DSpPublishFadeGamma(DSpContextPrivate *ctx,
                                  const uint8_t *lut, int fading)
{
	int32_t rc = dmc_record_gamma_change_with_lut_fade(lut, fading);
	if (rc == kDMCNoErr) s_dsp_gamma_context = fading && ctx ? ctx->handle : 0;
	return rc;
}

/* A removed context must not strand the global displayed gamma in fade mode.
 * If another timed fade is alive, resume its current table; otherwise deliver
 * the latest driver SetGamma (including changes deferred during the fade). */
static int32_t DSpCancelContextFade(DSpContextPrivate *ctx)
{
	if (ctx == nullptr) return kDSpNoErr;
	if (s_dsp_gamma_context != ctx->handle) {
		ctx->fade_state.active = 0;
		return kDSpNoErr;
	}
	uint8_t lut[768];
	DSpContextPrivate *remaining = nullptr;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; ++i) {
		DSpContextPrivate *other = dsp_context_table[i];
		if (other != nullptr && other != ctx && other->fade_state.active != 0)
			remaining = other;
	}
	if (remaining != nullptr) {
		DSpInterpolateGammaLUT(remaining->fade_state.start_lut,
		                       remaining->fade_state.end_lut,
		                       remaining->fade_state.elapsed_vbls,
		                       remaining->fade_state.duration_vbls, lut);
	} else {
		DSpCopyDriverGammaLUT(lut);
	}
	int32_t rc = DSpPublishFadeGamma(remaining, lut, remaining != nullptr);
	if (rc != kDMCNoErr) return kDSpInternalErr;
	ctx->fade_state.active = 0;
	return kDSpNoErr;
}

/*
 *  Shared fade setup for FadeGammaIn/Out/FadeGamma. Caller supplies end_lut,
 *  clamps duration to DSP_MAX_FADE_VBLS, and handles duration 0 itself.
 *
 *  start_lut: if a fade is already running, start from its current
 *  interpolated value so the new fade doesn't snap back (visible flash).
 *  Otherwise start from the DMC's current displayed gamma, or identity if
 *  there is no snapshot.
 */
static void DSpInitFadeStateCore(DSpContextPrivate *ctx,
                                  const uint8_t *end_lut_768,
                                  uint16_t duration_vbls)
{
	if (ctx->fade_state.active != 0) {
			/* Continue from the current interpolated state. */
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
			/* Fresh fade: start from the displayed gamma. */
		const struct DMCModeSnapshot *snap = dmc_current_snapshot();
		if (snap != nullptr) {
			memcpy(ctx->fade_state.start_lut, snap->gamma_lut, 768);
		} else {
				/* No DMC snapshot: start from identity. */
			for (uint32_t c = 0; c < 3; c++) {
				for (uint32_t i = 0; i < 256; i++) {
					ctx->fade_state.start_lut[c * 256 + i] = (uint8_t)i;
				}
			}
			DSP_LOG("DSpInitFadeStateCore: DMC NULL snapshot — "
			        "using identity LUT as start (ctx=%u)", ctx->handle);
		}
	}

	memcpy(ctx->fade_state.end_lut, end_lut_768, 768);

	ctx->fade_state.duration_vbls = duration_vbls;
	ctx->fade_state.elapsed_vbls  = 0;
	ctx->fade_state.active        = 1;
}

/*
 *  VBL secondary callback that advances gamma fades. Registered after
 *  DSpVBLClutLatchCallback, unregistered in reverse order. Each tick it
 *  bumps elapsed_vbls on active fades and publishes the interpolated LUT.
 *  On the final frame it publishes end_lut, writes gamma_lut_persisted, and
 *  clears active. A failed DMC publish rolls back the tick for retry.
 *  Emul thread, same as the SetGamma/FadeGamma handlers.
 */
extern "C" void DSpVBLGammaFadeCallback(void *cb_ctx, void *drawable, double ts)
{
	(void)cb_ctx; (void)drawable; (void)ts;

	/* fade_active is one global flag on the shared DMC snapshot, and the
	 * compositor presents one frame, so the flag must mean "any context
	 * still fading". Publishing per-context state would let one context
	 * finishing clear the flag under another still mid-fade. Pre-scan for
	 * any context still fading after this tick (elapsed + 1 < duration,
	 * matching the final-frame test below) and publish that OR with every
	 * LUT push. */
	uint32_t any_still_fading = 0u;
	DSpContextPrivate *continuing_fade = nullptr;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr || ctx->fade_state.active == 0) continue;
		/* (uint32_t) widen so the +1 cannot wrap the uint16_t counter. */
		uint32_t after = (uint32_t)ctx->fade_state.elapsed_vbls + 1u;
		if (after < (uint32_t)ctx->fade_state.duration_vbls) {
			any_still_fading = 1u;
			continuing_fade = ctx;
			break;
		}
	}

	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;

		/* Most contexts have no active fade. */
		if (ctx->fade_state.active == 0) continue;

		ctx->fade_state.elapsed_vbls++;

		/* Final frame: publish end_lut, persist it, clear active. */
		if (ctx->fade_state.elapsed_vbls >= ctx->fade_state.duration_vbls) {
			// Publish with the cross-context OR so a fade still running in
			// another context isn't cut off; the compositor restores static
			// display-LUT composition once no context is fading. The
			// completing context gives up fade ownership.
			int32_t rv = DSpPublishFadeGamma(continuing_fade,
			    ctx->fade_state.end_lut, (int)any_still_fading);
			if (rv != kDMCNoErr) {
				DSP_LOG("DSpVBLGammaFadeCallback: final-frame DMC push failed "
				        "(ctx=%u, rv=%d) — leaving fade active for retry",
				        ctx->handle, rv);
				ctx->fade_state.elapsed_vbls--;  /* retry next tick */
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

		uint8_t interp_lut[768];
		DSpInterpolateGammaLUT(ctx->fade_state.start_lut,
		                       ctx->fade_state.end_lut,
		                       (uint32_t)ctx->fade_state.elapsed_vbls,
		                       (uint32_t)ctx->fade_state.duration_vbls,
		                       interp_lut);
		// Mid-fade, so the flag is 1: the compositor skips pow and the ramp
		// stays linear (DSp 1.7). Flag and LUT publish together.
		int32_t rv = DSpPublishFadeGamma(ctx, interp_lut, 1);
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

/*
 *  VBL service callback: bumps s_dsp_vbl_count and latches a pending VBLProc
 *  delivery. Registered after DSpVBLGammaFadeCallback, unregistered in
 *  reverse order.
 *
 *  The procs are not called from here. The display link fires from the
 *  runloop pump at the top of HandleInterrupt, i.e. at an arbitrary guest
 *  instruction, before the interrupt-nesting check and on the interrupted
 *  stack, where a call would land inside a leaf routine's red zone.
 *  DSpDeliverPendingVBLProcs runs them from VideoVBL, the guest's own VBL
 *  interrupt.
 */
static bool s_dsp_vblproc_pending = false;
static bool s_dsp_vblproc_delivering = false;

extern "C" void DSpVBLServiceCallback(void *cb_ctx, void *drawable, double ts)
{
	(void)cb_ctx; (void)drawable; (void)ts;

	/* Relaxed: readers only need monotonicity. */
	atomic_fetch_add_explicit(&s_dsp_vbl_count, 1u,
	                          memory_order_relaxed);
	s_dsp_vblproc_pending = true;
}

/*
 *  Calls each Active context's VBLProc via call_macos3, at most once per
 *  guest VBL interrupt and only when a display VBL has elapsed since the
 *  last delivery. Emul thread, guest interrupt time.
 *
 *  VBLProc ABI (DSp 1.7 p.81):
 *    void DSpVBLProc(DSpContextReference ctx, void *refCon, UInt32 vblCount)
 *  r3 = ctx handle, r4 = refCon, r5 = vblCount (low 32 bits of the counter).
 *
 *  Contexts run in table index order with no early exit. call_macos3 blocks
 *  the emul thread until the proc returns; keeping VBLProcs short is the
 *  game's job, and a crashing VBLProc crashes the game as it would on real
 *  hardware.
 */
extern "C" void DSpDeliverPendingVBLProcs(void)
{
	if (!s_dsp_vblproc_pending || s_dsp_vblproc_delivering) return;
	s_dsp_vblproc_pending = false;
	s_dsp_vblproc_delivering = true;

	/* All VBLProcs this tick see the same vblCount. */
	const uint32_t vbl_count_arg =
	    (uint32_t)(atomic_load_explicit(&s_dsp_vbl_count,
	                                     memory_order_relaxed) & 0xFFFFFFFFu);

	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;

		/* VBLProcs fire only while Active (DSp 1.7 p.81). */
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;

		/* 0 = never installed, or uninstalled via SetVBLProc(0). */
		if (ctx->vbl_proc_ptr == 0) continue;

		const uint32_t proc_addr    = ctx->vbl_proc_ptr;
		const uint32_t proc_refcon  = ctx->vbl_proc_refcon;
		const uint32_t proc_handle  = ctx->handle;

		(void)call_macos3(proc_addr,
		                  proc_handle,
		                  proc_refcon,
		                  vbl_count_arg);
	}
	s_dsp_vblproc_delivering = false;
}

/*
 *  VBL auto-publish: presents the DSp back or front staging surface when DSp
 *  owns the display, or when DSp front staging is presentable under another
 *  owner. Lets classic DSp apps (Reserve + QuickDraw to the main port, no
 *  SwapBuffers) show pixels, and keeps front-buffer drawing visible in apps
 *  that mix SwapBuffers with it.
 *
 *  Registered after DSpVBLServiceCallback. Same steps as SwapBuffers: drain guest staging into
 *  back_buffer.contents, encode the present into the compositor framebuffer,
 *  submit an engine-blind framebuffer layer.
 */

/* Bytes to copy from guest staging into back_buffer.contents. Both are
 * sized for the back buffer, which can differ from the display mode
 * (a 512x384 back buffer in a 640x480 mode is legal), so size from the back
 * buffer and clamp to both allocations. */
static uint32_t DSpStagingDrainBytes(const DSpContextPrivate *ctx)
{
	uint32_t bytes =
	    DSpBackBufferAlignedRowBytes(DSpContextBackBufferWidth(ctx),
	                                 ctx->attr.backBufferBestDepth) *
	    DSpContextBackBufferHeight(ctx);
	if (bytes > ctx->staging_size) bytes = ctx->staging_size;
	const NSUInteger buffer_len = ctx->back_buffer.length;
	if ((NSUInteger)bytes > buffer_len) bytes = (uint32_t)buffer_len;
	return bytes;
}

extern "C" void DSpVBLCompositorPublishCallback(void *cb_ctx,
                                                 void *drawable,
                                                 double ts)
{
	(void)cb_ctx; (void)drawable; (void)ts;

	/* A stable display snapshot is required. Mixed DSp+RAVE apps such as
	 * Nanosaur keep drawing QuickDraw UI to the front buffer after RAVE owns
	 * the DMC, so presentable front staging keeps this path alive under the
	 * 3D overlay. */
	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap == nullptr || snap->transitioning != 0) {
		return;
	}

	/* First Active context with a live back buffer wins. */
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

	/* When Host2MacAddr couldn't map back_buffer.contents, the app draws
	 * into guest staging. Drain it before the GPU reads the texture. */
	if (has_back_buffer_staging) {
		const uint32_t buffer_size = DSpStagingDrainBytes(active);

		uint8_t *staging_host  = Mac2HostAddr(active->staging_mac_addr);
		void    *back_contents = [active->back_buffer contents];
		if (staging_host != NULL && back_contents != NULL) {
			memcpy(back_contents, staging_host, buffer_size);
		}
	}

	/* DSpEncodePresentToFramebuffer blits when formats match and uses a
	 * DSp-owned render pass otherwise (e.g. 16 bpp xRGB1555 into the
	 * BGRA8Unorm compositor framebuffer). Metal rejects a raw blit between
	 * mismatched formats. */
	void *fb_tex_raw = MetalCompositorGetFramebufferTexture();
	if (fb_tex_raw == NULL) {
		/* Compositor not initialized yet. Silent: this runs every VBL. */
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
		DSpSaveUnderlayRestoreRegion(active);
		bool front_presented = false;
		if (present_front_staging) {
			front_presented =
			    DSpEncodeFrontBufferStagingToFramebuffer(active,
			                                             (__bridge void *)cb,
			                                             fb_tex_raw);
		}
		if (!front_presented &&
		    !DSpEncodePresentToFramebuffer(active, (__bridge void *)cb, fb_tex_raw)) {
			return;
		}
		/* Register the completion latch before commit
		 * (addCompletedHandler is illegal afterwards). */
		gfxaccel_resources_heap_note_gpu_commit(kHeapEngineDSp,
		                                        (__bridge void *)cb);
		[cb commit];
	}

	/* Submit an engine-blind framebuffer layer. */
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
 *  DSpContext_SetVBLProc (sub-opcode 500). procPtr is a guest TVECT;
 *  0 uninstalls (DSp 1.7 p.81). refCon is stored as-is either way.
 *  The next VBL picks up the change. Emul thread, as is the reader.
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

	/* procPtr == 0 is a valid uninstall. */
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
 *  DSpContext_GetVBLProc (sub-opcode 503). Not a DSp 1.7 export and not
 *  in dsp_install_symbols[]; internal only. Writes the proc and refCon to
 *  the two guest UInt32 out addresses.
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

/* --- DSpProcessEvent (sub-op 750) ---
 *
 * DSp 1.7 PDF p.58:
 *   OSStatus DSpProcessEvent(EventRecord *inEvent, Boolean *outEventWasProcessed)
 * No ctxRef: r3 = inEvent, r4 = outEventWasProcessed. The app passes its
 * own event; DSp handles the suspend/resume osEvt and reports whether it
 * consumed the event. Lifecycle from UIKit goes through
 * DSpHandleBackgroundFromEmulThread / DSpHandleForegroundFromEmulThread
 * instead.
 *
 * EventRecord (16 bytes): what(+0,u16) message(+2,u32) when(+6,u32)
 *   where_v(+10,i16) where_h(+12,i16) modifiers(+14,u16).
 *
 * A suspend/resume osEvt has what == kDSpEvent_OSEvt, message high byte ==
 * kDSpOSEvt_SuspendResumeMessage, and bit 0 (kDSpOSEvtMsg_ResumeFlag) set
 * for resume. Suspend pauses every Active context and sets
 * paused_by_background, like the background handler; resume reactivates
 * those contexts. Only that event is reported consumed; everything else
 * returns false.
 *
 * Emul thread, synchronous.
 */
extern "C" int32_t DSpProcessEventHandler(uint32_t inEventAddr,
                                          uint32_t outProcessedAddr)
{
	/* Validate both guest addresses before touching guest memory. */
	if (inEventAddr == 0 || outProcessedAddr == 0) {
		DSP_LOG("DSpProcessEvent: NULL inEvent=0x%08x or outProcessed=0x%08x "
		        "-> kDSpInvalidAttributesErr", inEventAddr, outProcessedAddr);
		return kDSpInvalidAttributesErr;
	}

	uint16_t what    = (uint16_t)ReadMacInt16(inEventAddr + 0);
	uint32_t message = (uint32_t)ReadMacInt32(inEventAddr + 2);

	bool consumed = false;
	WriteMacInt8(outProcessedAddr, 0);

	/* osEvt suspend/resume: high byte = subtype, bit 0 = resume flag.
	 *
	 * This only drives context state (Active <-> Paused plus
	 * paused_by_background). It does not release/reallocate the Metal back
	 * buffer or cold-start like the host lifecycle path does, so an app
	 * using DSpProcessEvent keeps its back buffer across suspend. Wiring the
	 * full lifecycle in is non-trivial: the two halves gate on different
	 * fields (paused_by_background vs persisted.invalidated_full). */
	if (what == (uint16_t)kDSpEvent_OSEvt) {
		uint8_t subtype = (uint8_t)((message >> 24) & 0xFFu);
		if (subtype == (uint8_t)kDSpOSEvt_SuspendResumeMessage) {
			bool resume = (message & (uint32_t)kDSpOSEvtMsg_ResumeFlag) != 0u;
			if (resume) {
				/* Resume: reactivate contexts paused by background.
				 * User-paused contexts (paused_by_background == 0) stay
				 * Paused. */
				for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
					DSpContextPrivate *ctx = DSpGetContext(i + 1u);
					if (ctx == nullptr) continue;
					if (ctx->state != (uint32_t)kDSpContextState_Paused) continue;
					if (ctx->paused_by_background == 0) continue;
					int32_t rc = DSpContext_SetStateHandler(i + 1u,
						(uint32_t)kDSpContextState_Active);
					if (rc != kDSpNoErr) return rc;
					if (DSpGetContext(i + 1u) != ctx) return kDSpInvalidContextErr;
					ctx->paused_by_background = 0;
				}
			} else {
				/* Suspend: pause every Active context and mark it
				 * paused_by_background so resume restores it. */
				for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
					DSpContextPrivate *ctx = DSpGetContext(i + 1u);
					if (ctx == nullptr) continue;
					if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
					int32_t rc = DSpContext_SetStateHandler(i + 1u,
						(uint32_t)kDSpContextState_Paused);
					if (rc != kDSpNoErr) return rc;
					if (DSpGetContext(i + 1u) != ctx) return kDSpInvalidContextErr;
					ctx->paused_by_background = 1;
				}
			}
			consumed = true;
		}
	}

	/* Pascal Boolean; false for any event DSp doesn't handle. */
	WriteMacInt8(outProcessedAddr, consumed ? 1 : 0);

	DSP_LOG("DSpProcessEvent: what=%u message=0x%08x -> consumed=%d",
	        (unsigned)what, message, consumed ? 1 : 0);

	return kDSpNoErr;
}

/* --- Background / Foreground emul-thread drain --- */

/*
 *  Background path, emul thread (VBL drain). For each Active context:
 *    1. Persist attr and set invalidated_full so foreground does a full
 *       re-upload.
 *    2. Queue the back buffer and texture for partial release (the struct
 *       stays alive).
 *    3. Active -> Paused (DMC owner becomes QuickDraw).
 *  Palette/gamma generation fields are placeholders (0).
 */
extern "C" void DSpHandleBackgroundFromEmulThread(void)
{
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;

		/* Drop the MainDevice PixMap redirect before the partial release
		 * nils back_buffer, so lowmem never points at a freed MTLBuffer.
		 * DSpOnBackground in dsp_engine.cpp explains why this runs from
		 * the VBL drain and not the lifecycle hook. */
		DSpRestoreMainDevicePixMap(ctx);

		ctx->persisted.attr                          = ctx->attr;
		ctx->persisted.persisted_palette_generation  = 0u;  /* CLUT */
		ctx->persisted.persisted_gamma_generation    = 0u;  /* gamma/fade */
		ctx->persisted.invalidated_full              = 1u;

		DSpQueueReleaseAtVBLPartial(ctx);

		DMCOwner new_owner =
		    DSpMapStateToDMCOwnerTyped(kDSpContextState_Paused);
		(void)dmc_set_active_owner((uint32_t)new_owner);
		ctx->state = (uint32_t)kDSpContextState_Paused;
		DSP_LOG("Background: ctx=%u Active->Paused "
		        "(back-buffer queued for VBL partial release)",
		        ctx->handle);
	}

	/* Alt-buffer backings must go too, or their live allocations pin the
	 * DSp bump heap and each bg/fg cycle leaks toward the heap ceiling.
	 * Guest staging survives and repopulates them on foreground. */
	DSpReleaseAltBufferBackingsForBackground();
}

/*
 *  Foreground path, emul thread (VBL drain). For each Paused context with
 *  persisted.invalidated_full set:
 *    1. Reallocate the back buffer from persisted attr.
 *    2. Mark dirty_cold_start so the next SwapBuffers re-uploads fully
 *       (PDF p.38).
 *    3. Paused -> Active through SetState, which restores mode, palette,
 *       ownership and the PixMap redirect.
 *    4. Clear invalidated_full only after activation succeeds.
 *  Any failure leaves the context Paused for retry on the next VBL.
 */
extern "C" void DSpHandleForegroundFromEmulThread(void)
{
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Paused) continue;
		if (ctx->persisted.invalidated_full == 0u) continue;

		/* Re-allocate Metal back-buffer from persisted attributes, at the
		 * back-buffer size Reserve used (not the display mode size). */
		const DSpContextAttributes &pattr = ctx->persisted.attr;
		if (ctx->back_buffer == nil && !DSpAllocateBackBuffer(ctx,
		                           pattr.backBufferWidth != 0
		                               ? pattr.backBufferWidth
		                               : pattr.displayWidth,
		                           pattr.backBufferHeight != 0
		                               ? pattr.backBufferHeight
		                               : pattr.displayHeight,
		                           pattr.backBufferBestDepth)) {
			DSP_LOG("Foreground: ctx=%u back-buffer re-alloc FAILED; "
			        "context remains Paused (retry on next VBL)",
			        ctx->handle);
			continue;
		}

		if (!DSpRestoreBackBufferPixels(ctx)) {
			DSP_LOG("Foreground: ctx=%u back staging is invalid; retaining Paused state", ctx->handle);
			continue;
		}

		/* Force a full re-upload, ignoring any stale dirty rect. */
		ctx->dirty_cold_start = true;
		ctx->dirty_empty      = true;
		ctx->dirty_left       = 0;
		ctx->dirty_top        = 0;
		ctx->dirty_right      = 0;
		ctx->dirty_bottom     = 0;
		DSpSaveUnderlayRestoreRegion(ctx);

		ctx->front_staging_present_state.encoded = false;

		/* A rejected transition keeps Paused and the restore marker so
		 * the next VBL can retry. */
		int32_t rc = DSpContext_SetStateHandler(i + 1u,
		                                      kDSpContextState_Active);
		if (rc != kDSpNoErr) {
			DSP_LOG("Foreground: ctx=%u activation failed rc=%d; retry pending",
			        i + 1u, rc);
			continue;
		}
		if (DSpGetContext(i + 1u) != ctx) continue;
		ctx->persisted.invalidated_full = 0u;

		DSP_LOG("Foreground: ctx=%u Paused->Active "
		        "(back-buffer re-allocated; dirty_cold_start=1)",
		        ctx->handle);
	}

	/* Recreate alt-buffer backings from guest staging. Failure leaves a
	 * nil backing (nil-checked everywhere) and retries next VBL. */
	DSpRestoreAltBufferBackingsForForeground();
}

/*
 *  VBL drain entry point; runs after DSpVBLReleaseCallback drains the
 *  release FIFO. The UIKit hook stores a pending flag (release) and this
 *  exchanges it to 0 (acquire). Today both sides run on the same thread;
 *  the atomic keeps the hand-off correct if emulation moves off main.
 */
static bool DSpForegroundRestorePending(void)
{
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; ++i) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx && ctx->state == (uint32_t)kDSpContextState_Paused &&
		    ctx->persisted.invalidated_full) return true;
	}
	return DSpAltBufferRestorePending();
}

// Foreground remains requested until every invalidated context and alt
// backing has recovered. Retry allocation pressure on later VBL ticks.
static bool dsp_foreground_restore_retry = false;

extern "C" void DSpVBLBackgroundForegroundDrain(void)
{
	uint32_t pending = DSpExchangeBgFgPending();
	/* Background first, so a bg+fg pair that piled up while no drain ran
	 * nets out to release-then-restore. */
	if (pending & kDSpPendingBackground) {
		dsp_foreground_restore_retry = false;
		DSpHandleBackgroundFromEmulThread();
		DSpDrainReleaseQueue();
	}
	if (pending & kDSpPendingForeground) dsp_foreground_restore_retry = true;
	if (dsp_foreground_restore_retry) {
		DSpHandleForegroundFromEmulThread();
		dsp_foreground_restore_retry = DSpForegroundRestorePending();
	}
}

/*
 *  Synchronous lifecycle drain (see dsp_draw_context.h). Runs the bg/fg
 *  drain and then the release FIFO, because the VBL callback that usually
 *  drains the FIFO is paused in background and the memory would be held
 *  the whole time. The nested bg/fg drain in DSpVBLReleaseCallback is then
 *  a no-op.
 */
extern "C" void DSpDrainLifecycleSync(void)
{
	if (vbl_source_in_callback_chain()) {
		/* The in-flight chain will consume the pending bits when it
		 * unwinds; walking the table here would re-enter the state
		 * machine. */
		DSP_LOG("DrainLifecycleSync: deferred to in-flight VBL chain");
		return;
	}
	/* GPU was drained on the background edge and VBL is paused; see
	 * dsp_lifecycle_gpu_drained. */
	dsp_lifecycle_gpu_drained = true;
	DSpVBLBackgroundForegroundDrain();
	DSpVBLReleaseCallback(NULL, NULL, 0.0);
	dsp_lifecycle_gpu_drained = false;
}

/* --- DSpContext_ReserveHandler --- */

enum {
	kDSpColorTable_ctSize = 6,
	kDSpColorTable_ctTable = 8,
	kDSpColorSpec_value = 0,
	kDSpColorSpec_red = 2,
	kDSpColorSpec_green = 4,
	kDSpColorSpec_blue = 6,
	kDSpColorSpec_stride = 8
};

/* Apply DSpContextAttributes.colorTable (a QuickDraw CTabHandle) to the
 * indexed CLUT. *handle -> ColorTable { ctSeed, ctFlags, ctSize, ctTable[] };
 * ctSize is count - 1 and each ColorSpec.value is the destination index.
 * Direct-color contexts ignore it. */
static void DSpApplyReserveColorTable(DSpContextPrivate *ctx,
                                      uint32_t colorTableHandle,
                                      uint32_t depth_bits)
{
	if (ctx == nullptr || colorTableHandle == 0) return;
	if (depth_bits != 1 && depth_bits != 2 &&
	    depth_bits != 4 && depth_bits != 8) {
		return;
	}

	/* Bounds-check every guest extent before reading: a garbage CTabHandle
	 * must fall back to the default CLUT, not fault. */
	if (!NQDMetalAddrInBuffer(colorTableHandle) ||
	    !NQDMetalAddrInBuffer(colorTableHandle + 3u)) {
		DSP_LOG("Reserve: colorTable handle=0x%08x out of mapped RAM; "
		        "default indexed CLUT retained", colorTableHandle);
		return;
	}
	uint32_t colorTableAddr = ReadMacInt32(colorTableHandle);
	if (colorTableAddr == 0) {
		DSP_LOG("Reserve: colorTable handle=0x%08x is nil/purged; "
		        "default indexed CLUT retained", colorTableHandle);
		return;
	}
	/* ColorTable header: ctSeed/ctFlags/ctSize = 8 bytes before ctTable. */
	if (!NQDMetalAddrInBuffer(colorTableAddr) ||
	    !NQDMetalAddrInBuffer(colorTableAddr + kDSpColorTable_ctTable - 1u)) {
		DSP_LOG("Reserve: colorTable handle=0x%08x table=0x%08x header out "
		        "of mapped RAM; default indexed CLUT retained",
		        colorTableHandle, colorTableAddr);
		return;
	}
	int16_t ctSize = (int16_t)ReadMacInt16(colorTableAddr + kDSpColorTable_ctSize);
	if (ctSize < 0) {
		DSP_LOG("Reserve: colorTable handle=0x%08x table=0x%08x "
		        "has negative ctSize=%d; default indexed CLUT retained",
		        colorTableHandle, colorTableAddr, (int)ctSize);
		return;
	}

	uint32_t entry_count = (uint32_t)ctSize + 1u;
	if (entry_count > 256u) entry_count = 256u;

	/* Full ColorSpec array extent (header + entry_count * 8 bytes). */
	uint32_t table_bytes = kDSpColorTable_ctTable +
	                       entry_count * kDSpColorSpec_stride;
	if (!NQDMetalAddrInBuffer(colorTableAddr + table_bytes - 1u)) {
		DSP_LOG("Reserve: colorTable handle=0x%08x table=0x%08x ctTable "
		        "extent %u bytes out of mapped RAM; default indexed CLUT "
		        "retained", colorTableHandle, colorTableAddr, table_bytes);
		return;
	}

	uint8_t staged[256 * 3];
	memcpy(staged, ctx->clut_bytes, sizeof(staged));
	uint32_t applied = 0;
	for (uint32_t i = 0; i < entry_count; i++) {
		uint32_t e = colorTableAddr + kDSpColorTable_ctTable +
		             i * kDSpColorSpec_stride;
		int16_t value = (int16_t)ReadMacInt16(e + kDSpColorSpec_value);
		if (value < 0 || value > 255) continue;
		uint32_t idx = (uint32_t)value;
		staged[idx * 3 + 0] = (uint8_t)(ReadMacInt16(e + kDSpColorSpec_red) >> 8);
		staged[idx * 3 + 1] = (uint8_t)(ReadMacInt16(e + kDSpColorSpec_green) >> 8);
		staged[idx * 3 + 2] = (uint8_t)(ReadMacInt16(e + kDSpColorSpec_blue) >> 8);
		applied++;
	}
	if (applied == 0) {
		DSP_LOG("Reserve: colorTable handle=0x%08x table=0x%08x "
		        "had no valid ColorSpec.value entries; default indexed CLUT retained",
		        colorTableHandle, colorTableAddr);
		return;
	}

	int32_t rv = DSpSetCLUTCore(ctx, 0, 255, staged);
	if (rv == kDSpNoErr) {
		memcpy(ctx->clut_bytes_latched, ctx->clut_bytes, 768);
		DSP_LOG("Reserve: applied colorTable handle=0x%08x table=0x%08x "
		        "entries=%u applied=%u depth=%u",
		        colorTableHandle, colorTableAddr, entry_count, applied, depth_bits);
	} else {
		DSP_LOG("Reserve: DSpSetCLUTCore failed for colorTable handle=0x%08x "
		        "table=0x%08x rv=%d; default indexed CLUT retained",
		        colorTableHandle, colorTableAddr, rv);
	}
}

/*
 *  Reserve on an existing metadata-only context (vended by FindBestContext
 *  or GetFirstContext). DSp 1.7 PDF p.25: the caller already holds the
 *  ctxRef; Reserve applies the desired attributes (the back-buffer depth
 *  may differ from the display depth) and allocates the Metal back buffer.
 *  Re-reserving returns kDSpContextAlreadyReservedErr (p.87). The context
 *  leaves the enumeration chain. Emul thread only.
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

	/* PDF p.87: double Reserve is an error. */
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

	/* Keep the display mode FindBest/GetFirst selected and apply the
	 * requested back-buffer size separately. DSp 1.7 p.25 allows a 320x240
	 * back buffer in a 640x480 display; displayWidth/Height stay the display
	 * mode and the host-only backBufferWidth/Height hold the request. */
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
	ctx->attr.colorTable          = attr->colorTable;
	ctx->attr.contextOptions      = contextOptions;

	/* A reserved context ends enumeration: GetNextContext on it
	 * terminates (PDF p.17). */
	ctx->enumeration_mode_index = DSP_ENUMERATION_INDEX_NONE;
	ctx->state                  = kDSpContextState_Inactive;
	ctx->dirty_empty            = true;
	ctx->dirty_cold_start       = true;   /* PDF p.38: first swap is full */
	ctx->explicit_swap_observed = false;
	ctx->swap_generation = 0;
	ctx->front_staging_refresh_swap_generation = 0;
	DSpInitDefaultCLUT(ctx->clut_bytes, ctx->clut_bytes_latched,
	                   backBufferBestDepth);
	DSpApplyReserveColorTable(ctx, ctx->attr.colorTable,
	                          backBufferBestDepth);

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

extern "C" int32_t DSpPrepareContextForQueue(DSpContextPrivate *ctx,
                                             const DSpContextAttributes *desired)
{
	if (ctx == nullptr || desired == nullptr) return kDSpInvalidAttributesErr;
	if (ctx->state != (uint32_t)kDSpContextState_Inactive)
		return kDSpInvalidContextErr;
	if (desired == &ctx->attr && ctx->back_buffer != nil && ctx->back_texture != nil)
		return kDSpNoErr;
	const uint32_t handle = ctx->handle;
	const uint32_t prior_port = ctx->cgrafptr_mac_addr;
	id<MTLBuffer> prior_back_buffer = ctx->back_buffer;
	id<MTLTexture> prior_back_texture = ctx->back_texture;

	/* Prepare off-table. In particular, an allocation failure must not change
	 * the dimensions/stride of a previously reserved, guest-visible buffer. */
	DSpContextPrivate prepared = {};
	prepared.attr = ctx->attr;
	prepared.attr.gameMustConfirmSwitch = desired->gameMustConfirmSwitch;
	prepared.handle = ctx->handle;
	int32_t rc = DSpContext_Reserve_OnHandle_Core(&prepared, desired);
	if (rc != kDSpNoErr) return rc;

	/* NewPtrSys can execute guest callbacks. Prepare pixel storage without
	 * touching the shared port arena, then revalidate before committing. */
	NQDMetalFlush();
	const uint32_t base = prior_port != 0
	    ? DSpPrepareBackBufferGuestStorage(&prepared) : 0;
	if (DSpGetContext(handle) != ctx ||
	    ctx->state != (uint32_t)kDSpContextState_Inactive ||
	    ctx->back_buffer != prior_back_buffer ||
	    ctx->back_texture != prior_back_texture ||
	    ctx->cgrafptr_mac_addr != prior_port) {
		DSpReleaseBackBufferNow(&prepared);
		return kDSpInvalidContextErr;
	}
	/* A retained back port keeps its address across a successful Queue. No
	 * guest-visible port is changed on staging allocation failure. */
	if (prior_port != 0 && DSpEmitBackBufferCGrafPtr(&prepared, base) == 0) {
		DSpReleaseBackBufferNow(&prepared);
		return kDSpInternalErr;
	}
	DSpReleaseBackBufferNow(ctx);
	ctx->attr = prepared.attr;
	ctx->back_buffer = prepared.back_buffer;
	ctx->back_texture = prepared.back_texture;
	ctx->cgrafptr_mac_addr = prepared.cgrafptr_mac_addr;
	ctx->staging_mac_addr = prepared.staging_mac_addr;
	ctx->staging_size = prepared.staging_size;
	ctx->staging_owned_sysheap = prepared.staging_owned_sysheap;
	ctx->enumeration_mode_index = DSP_ENUMERATION_INDEX_NONE;
	ctx->dirty_empty = ctx->dirty_cold_start = true;
	ctx->underlay_restore_pending = false;
	ctx->explicit_swap_observed = false;
	ctx->front_staging_present_state.encoded = false;
	memcpy(ctx->clut_bytes, prepared.clut_bytes, sizeof(ctx->clut_bytes));
	memcpy(ctx->clut_bytes_latched, prepared.clut_bytes_latched,
	       sizeof(ctx->clut_bytes_latched));
	return kDSpNoErr;
}

extern "C" int32_t DSpContext_ReserveHandler(uint32_t ctxRef,
                                              uint32_t attrAddr)
{
	/*
	 *  DSp 1.7 PDF p.25: r3 = ctxRef, an existing handle from
	 *  FindBestContext / GetFirstContext (not an out-param); r4 = attrAddr.
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
	 *  DSpContextAttributes wire layout (DSp 1.7 PDF p.65): every field
	 *  is 4 bytes. filler[3] @ +52, gameMustConfirmSwitch @ +55 and
	 *  reserved3[4] @ +56..+71 are not validated (p.67).
	 *  backBufferWidth/Height are host-only and default to the display size.
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


/*
 *  Metadata-only context for DSpGetFirstContext / DSpFindBestContext: claims
 *  a slot and stores attr, without the Metal allocation Reserve does.
 *  enumeration_mode_index is the 0-based s_dsp_modes[] index the attr came
 *  from, so GetNextContext can advance; FindBest and other callers pass
 *  DSP_ENUMERATION_INDEX_NONE, which makes the context a terminator.
 *  Emul thread only.
 */
extern "C" uint32_t DSpAllocFirstContextHandle(const DSpContextAttributes *attr,
                                                uint32_t enumeration_mode_index)
{
	if (attr == nullptr) return 0;

	DSpContextPrivate *ctx = new DSpContextPrivate();
	ctx->attr  = *attr;
	ctx->state = kDSpContextState_Inactive;
	ctx->enumeration_mode_index = enumeration_mode_index;
	/* 0 = no max-fps limit; dirty grid defaults to the base unit. */
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

	/* Vend the existing metadata context for this mode if there is one, as
	 * real DSp does (a context ref names a display mode, and enumerating
	 * twice returns the same refs). Enumeration contexts are never freed
	 * (PDF p.16), so without this each walk and each FindBest would claim
	 * new slots until the table fills. DSpContextAttributes is all
	 * uint32_t, so memcmp sees no padding. */
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (!DSpIsInactiveMetadataOnlyContext(ctx)) continue;
		if (ctx->enumeration_mode_index != enumeration_mode_index) continue;
		if (memcmp(&ctx->attr, attr, sizeof(*attr)) != 0) continue;
		return ctx->handle;
	}

	uint32_t handle = DSpAllocFirstContextHandle(attr, enumeration_mode_index);
	if (handle != 0) return handle;

	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (!DSpIsInactiveMetadataOnlyContext(ctx)) continue;
		/* Last resort, reachable only with more distinct metadata contexts
		 * than slots: reclaim one. Any ref the app still holds to it then
		 * names the new mode. */

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
	/* Deactivation owns the mode, PixMap and idle-timer handoff; do it while
	 * the handle is still resolvable. On failure retain the context for retry. */
	if (ctx->state != (uint32_t)kDSpContextState_Inactive) {
		int32_t rc = DSpContext_SetStateHandler(ctxRef, kDSpContextState_Inactive);
		if (rc != kDSpNoErr) return rc;
		if (DSpGetContext(ctxRef) != ctx) return kDSpInvalidContextErr;
	}
	int32_t rc = DSpCancelContextFade(ctx);
	if (rc != kDSpNoErr) return rc;
	DSpFreeContextHandle(ctxRef);
	dsp_context_count--;
	/* Deferred to the next VBL, never synchronous. */
	DSpQueueReleaseAtVBL(ctx);
	DSP_LOG("Release: handle=%u queued for VBL drain", ctxRef);
	return kDSpNoErr;
}

/* Final Shutdown owns all remaining contexts, including metadata-only ones.
 * Keep callbacks installed until every release has completed its display and
 * gamma handoff, then release alt buffers and restore ambient gamma too. */
extern "C" int32_t DSpReleaseAllContexts(void)
{
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; ++i) {
		if (dsp_context_table[i] == nullptr) continue;
		int32_t rc = DSpContext_ReleaseHandler(i + 1u);
		if (rc != kDSpNoErr) return rc;
	}
	DSpResetAltBufferTable();
	uint8_t lut[768];
	DSpCopyDriverGammaLUT(lut);
	if (DSpPublishFadeGamma(nullptr, lut, 0) != kDMCNoErr)
		return kDSpInternalErr;
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
	/* Sub-op 705 underlay (PDF p.51): if an underlay alt buffer is set,
	 * restore the back buffer's dirty areas from it before returning.
	 * No-op otherwise. */
	DSpRestoreBackBufferFromUnderlay(ctx);
	WriteMacInt32(outBufAddr, cgrafptr);
	return kDSpNoErr;
}


/* --- DSpContext_SwapBuffersHandler --- */

static uint32_t DSpMaxFrameRatePacingVBLs(uint32_t maxFrameRate,
                                          uint64_t cadenceUsec)
{
	if (maxFrameRate == 0) return 1;

	if (cadenceUsec == 0) {
		cadenceUsec = GFX_FRAME_PACING_DEFAULT_USEC;
	} else {
		cadenceUsec = GfxFramePacingClampCadenceUsec(cadenceUsec);
	}

	uint64_t refreshHz = (1000000ULL + cadenceUsec / 2u) / cadenceUsec;
	if (refreshHz == 0) refreshHz = 1;
	if ((uint64_t)maxFrameRate >= refreshHz) return 1;

	uint64_t vbls = (refreshHz + (uint64_t)maxFrameRate - 1u) /
	                (uint64_t)maxFrameRate;
	if (vbls == 0) return 1;
	if (vbls > UINT32_MAX) return UINT32_MAX;
	return (uint32_t)vbls;
}

static void DSpSyncSwapFramePacing(uint32_t ctxRef, uint32_t maxFrameRate)
{
	uint64_t cadenceUsec = vbl_source_get_cadence_usec();
	uint32_t pacingVBLs = DSpMaxFrameRatePacingVBLs(maxFrameRate,
	                                                cadenceUsec);
	if (maxFrameRate != 0 && pacingVBLs > 1) {
		DSP_VLOG("SwapBuffers: ctx=%u maxFrameRate=%u cadence=%llu "
		         "-> pacing %u VBLs",
		         ctxRef, maxFrameRate,
		         (unsigned long long)cadenceUsec, pacingVBLs);
	}

	for (uint32_t i = 0; i < pacingVBLs; i++) {
		int32_t rc =
		    vbl_source_sync_3d_pacing_for_engine(kGfxFramePacingEngineDSp);
		if (rc != kGfxAccelNoErr) {
			DSP_LOG("SwapBuffers: frame pacing sync failed rc=%d "
			        "(ctx=%u, pass=%u/%u)",
			        rc, ctxRef, i + 1u, pacingVBLs);
			break;
		}
	}
}


/* Pre-swap busyProc gate. DSp 1.7 DSpCallbackProcPtr is
 * Boolean (*)(DSpContextReference inContext, void *inRefCon); it returns
 * false when its checks are done and true while still busy. 0 means no
 * gate. Polls every 0.5 ms for at most 2 VBLs (~33 ms at 60 Hz) so a
 * looping guest busyProc can't hang the emul thread. */
static bool DSpPollBusyProc(uint32_t ctxRef, uint32_t busyProcAddr,
                            uint32_t userRefCon)
{
	if (busyProcAddr == 0) return true;
	DSpContextPrivate *expected = DSpGetContext(ctxRef);
	if (expected == nullptr) return false;
	const uint32_t entry_state = expected->state;

	uint64_t cadence = vbl_source_get_cadence_usec();
	if (cadence == 0) cadence = 16667;    /* 60 Hz fallback */
	uint64_t timeout_usec = cadence * 2;  /* 2-VBL cap */
	uint64_t elapsed = 0;
	const uint32_t poll_step_usec = 500;  /* 0.5 ms */

	/* busyProc is a 32-bit TVECT (PDF p.39). Call call_macos2 directly:
	 * the CallMacOS2 macro widens guest values through uintptr. Classic
	 * Boolean is one byte, so only the low byte counts. */
	while (elapsed < timeout_usec) {
		/* The callback can release or pause the context. Stop as soon as
		 * it changes; SwapBuffers revalidates before touching surfaces. */
		DSpContextPrivate *current = DSpGetContext(ctxRef);
		if (current != expected || current->state != entry_state) return false;
		uint32 rv = call_macos2(busyProcAddr, ctxRef, userRefCon);
		if ((rv & 0xff) == 0) {
			return true;   /* checks complete */
		}
		usleep(poll_step_usec);
		elapsed += poll_step_usec;
	}
	DSP_LOG("DSpPollBusyProc: 2-VBL timeout (busyProcAddr=0x%08x "
	        "userRefCon=0x%08x elapsed=%llu)",
	        busyProcAddr, userRefCon, (unsigned long long)elapsed);
	return false;
}

static int32_t DSpRevalidateSwapContext(uint32_t ctxRef,
                                        DSpContextPrivate *expected,
                                        uint32_t entry_state,
                                        DSpContextPrivate **outCtx,
                                        const char *site)
{
	DSpContextPrivate *fresh = DSpGetContext(ctxRef);
	if (fresh == nullptr || fresh != expected) {
		DSP_LOG("SwapBuffers: ctxRef=%u was released/replaced during %s",
		        ctxRef, site);
		return kDSpInvalidContextErr;
	}
	/* Reject only a state change across the re-entry window (busyProc,
	 * frame-pacing runloop pump). A context that entered the swap
	 * non-Active (e.g. Paused by background) must still succeed: classic
	 * apps expect SwapBuffers not to fail. */
	if (fresh->state != entry_state) {
		DSP_LOG("SwapBuffers: ctxRef=%u state changed during %s "
		        "(entry=%u now=%u)",
		        ctxRef, site, entry_state, fresh->state);
		return kDSpInvalidContextErr;
	}
	if (fresh->back_texture == nil || fresh->back_buffer == nil) {
		DSP_LOG("SwapBuffers: ctxRef=%u lost back-buffer during %s",
		        ctxRef, site);
		return kDSpInternalErr;
	}
	if (outCtx != nullptr) {
		*outCtx = fresh;
	}
	return kDSpNoErr;
}

// Bring an already-vended front surface up to date at the swap, so a later
// GetFrontBuffer or resume doesn't copy the next, half-drawn back frame over
// this picture or over front-buffer edits made after the swap.
static void DSpRefreshFrontBufferAfterSwap(DSpContextPrivate *ctx,
                                           id<MTLTexture> framebuffer_texture,
                                           bool full_present,
                                           int32_t left, int32_t top,
                                           int32_t right, int32_t bottom)
{
	const uint32_t depth = ctx->attr.backBufferBestDepth;
	const uint32_t front_depth = DSpDisplayModeDepth(depth, ctx->attr.displayBestDepth);
	const uint32_t front_pitch = DSpDisplayModePitch(ctx->attr.displayWidth, front_depth);
	const uint32_t back_pitch = DSpBackBufferAlignedRowBytes(DSpContextBackBufferWidth(ctx), depth);
	const uint64_t front_size = (uint64_t)front_pitch * ctx->attr.displayHeight;
	if (depth != front_depth || front_size == 0 || front_size > ctx->front_staging_size ||
	    DSpUsableGuestBaseOrZero(ctx->front_staging_mac_addr, (uint32_t)front_size,
	                            (uint32_t)RAMBase, (uint32_t)RAMSize) == 0) return;
	uint8_t *dst = Mac2HostAddr(ctx->front_staging_mac_addr);
	const uint8_t *src = (const uint8_t *)ctx->back_buffer.contents;
	if (dst == NULL || src == NULL) return;
	uint32_t width = ctx->attr.displayWidth < DSpContextBackBufferWidth(ctx)
	    ? ctx->attr.displayWidth : DSpContextBackBufferWidth(ctx);
	uint32_t height = ctx->attr.displayHeight < DSpContextBackBufferHeight(ctx)
	    ? ctx->attr.displayHeight : DSpContextBackBufferHeight(ctx);
	if (width > framebuffer_texture.width) width = (uint32_t)framebuffer_texture.width;
	if (height > framebuffer_texture.height) height = (uint32_t)framebuffer_texture.height;
	const bool entire_front_presented = full_present &&
	    (uint32_t)width == ctx->attr.displayWidth &&
	    (uint32_t)height == ctx->attr.displayHeight;
	const DSpFrontStagingPresentState &prior = ctx->front_staging_present_state;
	const bool prior_front_presented = prior.valid && prior.encoded &&
	    prior.last_size == front_size &&
	    prior.last_hash == DSpFrontStagingHashBytes(dst, (uint32_t)front_size);
	if (full_present) { left = top = 0; right = width; bottom = height; }
	auto clamp = [](int32_t value, int32_t low, int32_t high) {
		return value < low ? low : (value > high ? high : value);
	};
	left = clamp(left, 0, width);
	right = clamp(right, left, width);
	top = clamp(top, 0, height);
	bottom = clamp(bottom, top, height);
	const uint32_t byte_left = (uint32_t)left * depth / 8;
	const uint32_t byte_right = ((uint32_t)right * depth + 7) / 8;
	for (int32_t y = top; y < bottom; y++) {
		if ((uint64_t)y * back_pitch + byte_right > ctx->back_buffer.length) return;
		memcpy(dst + (size_t)y * front_pitch + byte_left,
		       src + (size_t)y * back_pitch + byte_left, byte_right - byte_left);
	}
	ctx->front_staging_refresh_swap_generation = ctx->swap_generation;
	DSpFrontStagingRememberHash(&ctx->front_staging_present_state,
	    DSpFrontStagingHashBytes(dst, (uint32_t)front_size), (uint32_t)front_size);
	// A partial swap doesn't publish front edits outside its damage; leave
	// them for the next VBL front upload.
	ctx->front_staging_present_state.encoded =
	    entire_front_presented || prior_front_presented;
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

	/* Revalidation rejects on state change across the re-entry windows,
	 * not on non-Active as such. */
	const uint32_t entry_state = ctx->state;

	/* PDF p.39: busyProc runs before the swap, not after. */
	const bool busy_completed = DSpPollBusyProc(ctxRef, busyProcAddr, userRefCon);
	int32_t revalidate_rc =
	    DSpRevalidateSwapContext(ctxRef, ctx, entry_state, &ctx, "busyProc");
	if (revalidate_rc != kDSpNoErr) return revalidate_rc;
	if (!busy_completed) {
		DSP_LOG("SwapBuffers: busyProc gate timed out (2 VBL cap); "
		        "proceeding with swap");
	}

	/* VBL sync unless kDSpContextOption_DontSyncVBL. max_frame_rate
	 * multiplies the wait: a 60 fps cap on 120 Hz waits two VBLs. */
	if ((ctx->attr.contextOptions & kDSpContextOption_DontSyncVBL) == 0) {
		DSpSyncSwapFramePacing(ctxRef, ctx->max_frame_rate);
		revalidate_rc =
		    DSpRevalidateSwapContext(ctxRef, ctx, entry_state, &ctx,
		                             "frame pacing");
		if (revalidate_rc != kDSpNoErr) return revalidate_rc;
	}

	/* Blit into the compositor-owned framebuffer texture. The layer's
	 * source is that texture, not ctx->back_texture, so no DSp identity
	 * reaches the compositor. */
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

		/* When Host2MacAddr couldn't map the MTLBuffer contents, the app
		 * draws into guest staging. Copy it into back_buffer.contents
		 * before the GPU reads the texture. */
		if (has_back_buffer_staging) {
			uint32_t buffer_size = DSpStagingDrainBytes(ctx);

			uint8_t *staging_host = Mac2HostAddr(ctx->staging_mac_addr);
			void    *back_contents = ctx->back_buffer.contents;
			if (staging_host != NULL && back_contents != NULL) {
				memcpy(back_contents, staging_host, buffer_size);
			}
		}

		/* Blit back_texture into the framebuffer, or use the unpack
		 * render pass when formats differ (e.g. R16Uint after a depth
		 * switch vs a BGRA8Unorm framebuffer). The helper manages its own
		 * encoder. */
		DSpSaveUnderlayRestoreRegion(ctx);
		bool front_presented = false;
		if (present_front_staging) {
			front_presented =
			    DSpEncodeFrontBufferStagingToFramebuffer(ctx,
			                                             (__bridge void *)cb,
			                                             fb_tex_raw);
		}
		const bool full_present = ctx->back_texture.pixelFormat !=
		    ((__bridge id<MTLTexture>)fb_tex_raw).pixelFormat ||
		    ctx->dirty_cold_start || ctx->dirty_empty ||
		    (uint64_t)(ctx->dirty_right - ctx->dirty_left) *
		    (uint64_t)(ctx->dirty_bottom - ctx->dirty_top) * 10 >
		    (uint64_t)DSpContextBackBufferWidth(ctx) * DSpContextBackBufferHeight(ctx) * 9;
		const int32_t left = ctx->dirty_left, top = ctx->dirty_top;
		const int32_t right = ctx->dirty_right, bottom = ctx->dirty_bottom;
		if (!front_presented &&
		    !DSpEncodePresentToFramebuffer(ctx, (__bridge void *)cb, fb_tex_raw)) {
			return kDSpInternalErr;
		}
		ctx->explicit_swap_observed = true;
		ctx->swap_generation++;
		DSpRefreshFrontBufferAfterSwap(ctx, (__bridge id<MTLTexture>)fb_tex_raw,
		                               full_present, left, top, right, bottom);
		/* Register the completion latch before commit
		 * (addCompletedHandler is illegal afterwards). */
		gfxaccel_resources_heap_note_gpu_commit(kHeapEngineDSp,
		                                        (__bridge void *)cb);
		[cb commit];
	}

	/* Submit an engine-blind layer with the compositor's framebuffer
	 * texture as source. SubmitFrame no-ops framebuffer-slot layers (the
	 * blit above is what shows the pixels), but it still validates the
	 * descriptor and rejects stale generations, same as RAVE/GL. */
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
		/* Still return noErr: classic apps have no notion of rebuilding
		 * and expect SwapBuffers to succeed. */
	} else if (rc != kGfxAccelNoErr) {
		DSP_LOG("SwapBuffers: SubmitFrame returned %d (ctxRef=%u)",
		        rc, ctxRef);
	}

	/* Reset dirty state for the next frame. */
	ctx->dirty_empty      = true;
	ctx->dirty_cold_start = false;

	/* PDF p.39: "This function returns immediately, even if the buffer
	 * swap has not yet occurred." */
	return kDSpNoErr;
}

/* Local helpers for the MainDevice redirect below. DSpAlignedRowBytes
 * duplicates the file-local copy in dsp_metal_renderer.mm; keep them
 * identical. */

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
			const bool geometry_changed =
			    ctx->front_staging_row_bytes != row_bytes ||
			    ctx->front_staging_height != height;
			if (DSpShouldRefreshFrontBufferStagingFromBackStaging(
			        ctx->attr.backBufferBestDepth,
			        front_depth,
			        ctx->staging_mac_addr,
			        reusable,
			        ctx->staging_size,
			        buffer_size,
			        back_staging_row_bytes,
			        row_bytes,
			        ctx->swap_generation,
			        ctx->front_staging_refresh_swap_generation,
			        geometry_changed)) {
				uint8_t *dst = Mac2HostAddr(reusable);
				uint8_t *src = Mac2HostAddr(ctx->staging_mac_addr);
				if (dst != NULL && src != NULL) {
					memcpy(dst, src, buffer_size);
					ctx->front_staging_refresh_swap_generation =
					    ctx->swap_generation;
					DSpFrontStagingRememberSeedBytes(
						&ctx->front_staging_present_state,
						dst,
						buffer_size);
					DSP_LOG("%s: front staging refreshed from back staging "
					        "(src=0x%08x dst=0x%08x size=%u rowBytes=%u bpp=%u "
					        "swapGen=%u)",
					        caller, ctx->staging_mac_addr, reusable,
					        buffer_size, row_bytes, front_depth,
					        ctx->swap_generation);
				}
			}
			ctx->front_staging_row_bytes = row_bytes;
			ctx->front_staging_height = height;
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
	ctx->front_staging_owned_sysheap = true;
	ctx->front_staging_row_bytes = row_bytes;
	ctx->front_staging_height = height;
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
			ctx->front_staging_refresh_swap_generation =
			    ctx->swap_generation;
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
 *  DSpBlit_Fastest (711): 1:1 copy via NQDMetalBitblt1to1.
 *  DSpBlit_Faster (710): scaled copy via NQDMetalBitbltScaled; nearest
 *    neighbor unless kDSpBlitMode_Interpolation (PDF p.87); honors
 *    SrcKey/DstKey.
 *
 *  Both run on NQD's Metal compute queue. Async requests complete
 *  synchronously: encode, flush, set completionFlag, then call the guest
 *  completionProc via call_macos1 (never cast the guest pointer). Guest
 *  addresses are bounds-checked before dispatch and rects are clamped to
 *  the port bounds.
 * ===================================================================== */

/* One side of a DSpBlit. base_origin_mac is the guest address of the rect
 * origin pixel, so the kernel addresses from there. */
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

/* Resolve a CGrafPtr + blit Rect into a DSpBlitSide. The port is either the
 * DSp flat shim (alt buffers, legacy callers) or a real CGrafPort whose
 * portPixMap is a PixMapHandle (back/front buffers). Both PixMap layouts have
 * baseAddr@0, rowBytes@4 (high bit is a flag, masked off) and bounds@6;
 * later fields use compact offsets for shims and QuickDraw offsets for real
 * ports. The Rect (top/left/bottom/right, big-endian i16) is clamped to the
 * PixMap bounds. Returns false for NULL, unsupported depth, or empty rect. */
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

	/* DSp surfaces are top-down, so only positive strides are supported.
	 * The rowBytes high bit is a flag, not a sign, so masking it already
	 * gives a positive value. Zero is rejected. */
	uint32_t row_bytes = (uint32_t)(rb_raw & 0x7FFFu);   /* drop the PixMap flag bit */
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

	/* Clamp to the pixmap bounds; bounds top/left is baseAddr's origin. */
	int32_t c_top    = (r_top    < pbnd_top)   ? pbnd_top   : r_top;
	int32_t c_left   = (r_left   < pbnd_left)  ? pbnd_left  : r_left;
	int32_t c_bottom = (r_bottom > pbnd_bot)   ? pbnd_bot   : r_bottom;
	int32_t c_right  = (r_right  > pbnd_right) ? pbnd_right : r_right;

	int32_t w = c_right  - c_left;
	int32_t h = c_bottom - c_top;
	if (w <= 0 || h <= 0) return false;   /* empty / inverted */

	/* baseAddr + (top - bnd_top) * rowBytes + (left - bnd_left) * bpp */
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

/* Flush NQD so the GPU writes land, set DSpBlitInfo.completionFlag, and for
 * async calls invoke the guest completionProc via call_macos1. Completing
 * synchronously is faithful enough for a single-display emulator. */
static void DSpBlitComplete(uint32_t inBlitInfo, uint32_t inAsyncFlag)
{
	NQDMetalFlush();

	WriteMacInt8(inBlitInfo + DSP_BLITINFO_OFF_completionFlag, 1);

	uint32_t completionProc = ReadMacInt32(inBlitInfo + DSP_BLITINFO_OFF_completionProc);
	if (inAsyncFlag != 0 && completionProc != 0) {
			/* DSpBlitDoneProc(DSpBlitInfoPtr): one arg in r3. */
		(void)call_macos1(completionProc, inBlitInfo);
	}
}

/* --- DSpBlit_FastestHandler (sub-op 711) ---
 *
 *  DSp 1.7 PDF p.47. The spec has the caller guarantee srcRect == dstRect
 *  and does no validation. We deliberately differ: mismatched rects copy
 *  only the overlap, so the copy never leaves the resolved geometry.
 *  SrcKey -> transparent (mode 36); Plain -> srcCopy (0).
 *  NULL inBlitInfo -> kDSpInvalidAttributesErr; out-of-range address or
 *  unsupported depth -> kDSpInternalErr. */
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
	/* No scaling: copy the overlap of the two rects (see above). */
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
 *  DSp 1.7 PDF p.46. Scales srcRect -> dstRect; nearest neighbor unless
 *  kDSpBlitMode_Interpolation (p.87). Honors SrcKey/DstKey. Errors as for
 *  Fastest. */
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


/* Save presented damage separately: render encoders consume dirty_* before
 * GetBackBuffer restores the underlay. No invalid rect means the whole
 * drawable was invalidated (DSp 1.7 p.38). */
static void DSpSaveUnderlayRestoreRegion(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->underlay_alt_buffer == 0) return;
	const bool full = ctx->dirty_cold_start || ctx->dirty_empty;
	int32_t left = full ? 0 : ctx->dirty_left;
	int32_t top = full ? 0 : ctx->dirty_top;
	int32_t right = full ? (int32_t)DSpContextBackBufferWidth(ctx) : ctx->dirty_right;
	int32_t bottom = full ? (int32_t)DSpContextBackBufferHeight(ctx) : ctx->dirty_bottom;
	if (ctx->underlay_restore_pending) {
		if (left > ctx->underlay_restore_left) left = ctx->underlay_restore_left;
		if (top > ctx->underlay_restore_top) top = ctx->underlay_restore_top;
		if (right < ctx->underlay_restore_right) right = ctx->underlay_restore_right;
		if (bottom < ctx->underlay_restore_bottom) bottom = ctx->underlay_restore_bottom;
	}
	ctx->underlay_restore_left = left;
	ctx->underlay_restore_top = top;
	ctx->underlay_restore_right = right;
	ctx->underlay_restore_bottom = bottom;
	ctx->underlay_restore_pending = true;
}

/* Restore into the surface the guest actually sees, not the derived Metal
 * cache, so a later staging drain keeps it. Strides and allocation extents
 * are checked before any copy. */
static void DSpRestoreBackBufferFromUnderlay(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->underlay_alt_buffer == 0 ||
	    !ctx->underlay_restore_pending) return;
	DSpAltBufferRecord *u = DSpGetAltBuffer(ctx->underlay_alt_buffer);
	if (u == nullptr) {
		ctx->underlay_alt_buffer = 0;
		ctx->underlay_restore_pending = false;
		return;
	}
	const uint32_t depth = ctx->attr.backBufferBestDepth;
	if (u->depth != depth || (depth != 8 && depth != 16 && depth != 32)) return;
	const uint32_t width = DSpContextBackBufferWidth(ctx);
	const uint32_t height = DSpContextBackBufferHeight(ctx);
	const uint32_t px = depth / 8u;
	const uint32_t srcRB = DSpAlignedRowBytes(u->width, depth);
	const uint32_t dstRB = DSpAlignedRowBytes(width, depth);
	int32_t left = ctx->underlay_restore_left, top = ctx->underlay_restore_top;
	int32_t right = ctx->underlay_restore_right, bottom = ctx->underlay_restore_bottom;
	if (left < 0) left = 0;
	if (top < 0) top = 0;
	if (right > (int32_t)width) right = (int32_t)width;
	if (right > (int32_t)u->width) right = (int32_t)u->width;
	if (bottom > (int32_t)height) bottom = (int32_t)height;
	if (bottom > (int32_t)u->height) bottom = (int32_t)u->height;
	if (right <= left || bottom <= top) {
		ctx->underlay_restore_pending = false;
		return;
	}
	const uint64_t srcEnd = uint64_t(bottom - 1) * srcRB + uint64_t(right) * px;
	const uint64_t dstEnd = uint64_t(bottom - 1) * dstRB + uint64_t(right) * px;
	uint8_t *src = nullptr, *dst = nullptr;
	if (u->baseaddr_mac != 0) {
		if (srcEnd > u->baseaddr_size ||
		    !DSpGuestRAMContains(u->baseaddr_mac, (uint32_t)srcEnd,
		                         (uint32_t)RAMBase, (uint32_t)RAMSize)) return;
		src = Mac2HostAddr(u->baseaddr_mac);
	} else if (u->backing != nil && srcEnd <= u->backing.length) {
		src = (uint8_t *)u->backing.contents;
	}
	if (ctx->staging_mac_addr != 0) {
		if (dstEnd > ctx->staging_size ||
		    !DSpGuestRAMContains(ctx->staging_mac_addr, (uint32_t)dstEnd,
		                         (uint32_t)RAMBase, (uint32_t)RAMSize)) return;
		dst = Mac2HostAddr(ctx->staging_mac_addr);
	} else if (ctx->back_buffer != nil && dstEnd <= ctx->back_buffer.length) {
		dst = (uint8_t *)ctx->back_buffer.contents;
	}
	if (src == nullptr || dst == nullptr) return;
	NQDMetalFlush();
	for (int32_t y = top; y < bottom; ++y) {
		memmove(dst + (uint32_t)y * dstRB + (uint32_t)left * px,
		        src + (uint32_t)y * srcRB + (uint32_t)left * px,
		        (uint32_t)(right - left) * px);
	}
	ctx->underlay_restore_pending = false;
}

/* --------------------------------------------------------------------- *
 *  MainDevice PixMap redirect / restore                                 *
 *                                                                       *
 *  Lowmem walk:                                                         *
 *      LMADDR_MAIN_DEVICE (0x8A4) -> GDeviceHandle -> GDevice           *
 *        -> GDEVICE_OFF_PMAP (0x16) -> PixMapHandle -> PixMap           *
 *                                                                       *
 *  The original PixMap fields are saved in ctx->saved_pixmap_* before   *
 *  being overwritten. Host2MacAddr(back_buffer.contents) may fail for   *
 *  the heap-backed MTLBuffer, so guest system-heap staging is the       *
 *  fallback. The new baseAddr must be nonzero and inside guest RAM, or  *
 *  the redirect is abandoned and saved_pixmap_valid cleared so Restore  *
 *  is a no-op. Emul thread only.                                        *
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

	/* Defensive walk: refuse to dereference any intermediate address that
	 * is outside guest RAM and outside the low-memory page [0, 0x3000).
	 * The DSP-RDR-Sn log tags identify which step failed. */
	const uint32_t kLomemBase = 0x0;
	const uint32_t kLomemTop  = 0x3000;        /* matches gZeroPage in vm.hpp */
	const uint32_t kRamLo     = (uint32_t)RAMBase;
	const uint32_t kRamHi     = (uint32_t)(RAMBase + RAMSize);
	#define DSP_REDIR_INRANGE(a) \
		(((a) >= kRamLo && (a) < kRamHi) || \
		 ((a) >= kLomemBase && (a) < kLomemTop))

	/* S0: nothing to redirect without a back buffer. */
	if (ctx->back_buffer == nil) {
		DSP_VLOG("DSpRedirectMainDevicePixMap: DSP-RDR-S0 ctx->back_buffer is nil "
		         "(ctx=%p) — skipping redirect", (void *)ctx);
		return;
	}

	/* S1: MainDevice handle at 0x8A4 (always in the low-memory page). */
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

	/* S2: handle -> GDevice. */
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

	/* S3: GDevice.gdPMap @ +0x16 -> PixMapHandle. */
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

	/* S4: handle -> PixMap. */
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

	/* S5: save the originals before overwriting. A reassertion on the same
	 * PixMap must keep the original screen snapshot (Nanosaur calls
	 * GetFrontBuffer and then probes MainDevice directly). */
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
		/* Also save GDevice.gdRect: apps read it for the display's global
		 * bounds (DMGetGDeviceByDisplayID centering), so the redirect sets
		 * it to the context size and Restore puts this back. */
		if (DSP_REDIR_INRANGE(gdevicePtr + GDEVICE_OFF_GDRECT) &&
		    DSP_REDIR_INRANGE(gdevicePtr + GDEVICE_OFF_GDRECT + 7)) {
			ctx->saved_gdevice_ptr = gdevicePtr;
			ctx->saved_gdrect[0] = (int16_t)ReadMacInt16(gdevicePtr + GDEVICE_OFF_GDRECT + 0);
			ctx->saved_gdrect[1] = (int16_t)ReadMacInt16(gdevicePtr + GDEVICE_OFF_GDRECT + 2);
			ctx->saved_gdrect[2] = (int16_t)ReadMacInt16(gdevicePtr + GDEVICE_OFF_GDRECT + 4);
			ctx->saved_gdrect[3] = (int16_t)ReadMacInt16(gdevicePtr + GDEVICE_OFF_GDRECT + 6);
			ctx->saved_gdrect_valid = 1;
		}
		/* The live PixMap may already belong to another DSp context's
		 * redirect. Inherit that context's saved real-screen snapshot (never
		 * its redirected buffer) so either release order restores the
		 * screen. */
		for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; ++i) {
			DSpContextPrivate *other = dsp_context_table[i];
			if (other == nullptr || other == ctx ||
			    other->state != (uint32_t)kDSpContextState_Active ||
			    other->saved_pixmap_valid == 0 ||
			    (other->saved_pixmap_addr != pixMapPtr &&
			     !DSpPixMapLooksLikeContextRedirect(other, pixMapPtr))) continue;
			/* The guest may have moved the PixMap: keep this context's new
			 * struct address but inherit the original contents and bounds. */
			ctx->saved_pixmap_baseAddr = other->saved_pixmap_baseAddr;
			ctx->saved_pixmap_rowBytes = other->saved_pixmap_rowBytes;
			ctx->saved_pixmap_pixelType = other->saved_pixmap_pixelType;
			ctx->saved_pixmap_pixelSize = other->saved_pixmap_pixelSize;
			ctx->saved_pixmap_cmpCount = other->saved_pixmap_cmpCount;
			ctx->saved_pixmap_cmpSize = other->saved_pixmap_cmpSize;
			ctx->saved_pixmap_pmVersion = other->saved_pixmap_pmVersion;
			ctx->saved_pixmap_packType = other->saved_pixmap_packType;
			ctx->saved_pixmap_packSize = other->saved_pixmap_packSize;
			ctx->saved_pixmap_hRes = other->saved_pixmap_hRes;
			ctx->saved_pixmap_vRes = other->saved_pixmap_vRes;
			ctx->saved_pixmap_planeBytes = other->saved_pixmap_planeBytes;
			ctx->saved_pixmap_valid = other->saved_pixmap_valid;
			ctx->saved_gdevice_ptr = other->saved_gdevice_ptr;
			ctx->saved_gdrect_valid = other->saved_gdrect_valid;
			memcpy(ctx->saved_pixmap_bounds, other->saved_pixmap_bounds,
			       sizeof(ctx->saved_pixmap_bounds));
			memcpy(ctx->saved_gdrect, other->saved_gdrect,
			       sizeof(ctx->saved_gdrect));
			break;
		}
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

	/* S6: prefer a separate display-depth front staging surface so front
	 * (visible) and back (draw target) don't alias; aliasing breaks the
	 * guest's double-buffer page arithmetic. Point MainDevice straight at
	 * the back buffer only when there is no presentable front staging and
	 * the depths match. */
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
					ctx->staging_owned_sysheap = true;
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

	/* Never write an address outside guest RAM into PixMap.baseAddr: a
	 * failed mapping plus failed staging would otherwise write 0 and let
	 * QuickDraw trash low memory. Clearing saved_pixmap_valid makes the
	 * matching Restore a no-op. */
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
	/* Keep GDevice.gdRect matching the redirected bounds. Apps center inside
	 * gdRect (DMGetGDeviceByDisplayID), so a stale full-screen rect around a
	 * smaller mode offsets every blit by the letterbox margin (Diablo II
	 * 800x600 in 1024x768 lands at (112,84)). Restore writes the saved rect
	 * back. */
	if (DSP_REDIR_INRANGE(gdevicePtr + GDEVICE_OFF_GDRECT) &&
	    DSP_REDIR_INRANGE(gdevicePtr + GDEVICE_OFF_GDRECT + 7)) {
		WriteMacInt16(gdevicePtr + GDEVICE_OFF_GDRECT + 0, 0);
		WriteMacInt16(gdevicePtr + GDEVICE_OFF_GDRECT + 2, 0);
		WriteMacInt16(gdevicePtr + GDEVICE_OFF_GDRECT + 4,
		              (uint16_t)pixmap_height);
		WriteMacInt16(gdevicePtr + GDEVICE_OFF_GDRECT + 6,
		              (uint16_t)pixmap_width);
	}
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
	/* Restore the saved GDevice.gdRect. */
	if (ctx->saved_gdrect_valid != 0 &&
	    DSpLowMemOrGuestRAMContainsAtOffset(ctx->saved_gdevice_ptr,
	                                        GDEVICE_OFF_GDRECT, 8)) {
		WriteMacInt16(ctx->saved_gdevice_ptr + GDEVICE_OFF_GDRECT + 0,
		              (uint16_t)ctx->saved_gdrect[0]);
		WriteMacInt16(ctx->saved_gdevice_ptr + GDEVICE_OFF_GDRECT + 2,
		              (uint16_t)ctx->saved_gdrect[1]);
		WriteMacInt16(ctx->saved_gdevice_ptr + GDEVICE_OFF_GDRECT + 4,
		              (uint16_t)ctx->saved_gdrect[2]);
		WriteMacInt16(ctx->saved_gdevice_ptr + GDEVICE_OFF_GDRECT + 6,
		              (uint16_t)ctx->saved_gdrect[3]);
		DSP_LOG("DSpRestoreMainDevicePixMap: restored gdRect (%d,%d)-(%d,%d) "
		        "gdevicePtr=0x%08x",
		        ctx->saved_gdrect[0], ctx->saved_gdrect[1],
		        ctx->saved_gdrect[2], ctx->saved_gdrect[3],
		        ctx->saved_gdevice_ptr);
	}
	ctx->saved_gdrect_valid = 0;
	ctx->saved_pixmap_valid = 0;
}

/* --- DSpContext_SetStateHandler ---
 *
 *  State transitions (DrawSprocket 1.7 pp.29, 75, 86):
 *
 *  +-----------------------+-----------------------------------------+
 *  | From -> To            | DMC owner                               |
 *  +-----------------------+-----------------------------------------+
 *  | Inactive/Paused->Active | kDMCOwnerDSp                          |
 *  | Inactive -> Paused    | kDMCOwnerQuickDraw                      |
 *  | Active   -> Paused    | kDMCOwnerQuickDraw                      |
 *  | Active/Paused->Inactive | kDMCOwnerQuickDraw                    |
 *  | X -> X                | noErr, no DMC call                      |
 *  | state not in {0,1,2}  | kDSpInvalidAttributesErr (-30443)       |
 *  | invalid ctxRef        | kDSpInvalidContextErr (-30442)          |
 *  +-----------------------+-----------------------------------------+
 *
 *  The owner stays DSp while any other context is Active. Paused and
 *  Inactive differ only at the DSp level; the DMC just sees "not DSp".
 *  Emul thread only.
 */
static uint32_t s_dsp_setstate_switch_handoff_ctx = 0;

extern "C" void DSpContext_SetStateSwitchHandoff(uint32_t oldCtxRef)
{
	s_dsp_setstate_switch_handoff_ctx = oldCtxRef;
}

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
	/* A host suspend can remove a reserved context's backing. Guest resume
	 * events must not bypass the pending foreground restore, and an
	 * unreserved enumeration context must not take the display. */
	if (state == (uint32_t)kDSpContextState_Active &&
	    (ctx->back_buffer == nil || ctx->back_texture == nil)) {
		DSP_LOG("SetState: ctx=%u has no drawable back-buffer", ctxRef);
		return ctx->persisted.invalidated_full != 0
		    ? kDSpInternalErr : kDSpContextNotReservedErr;
	}
	/* Needed after the owner swap for the Paused->Active replay. */
	const uint32_t prev_state = ctx->state;
	if (ctx->state == state) {
		DSP_LOG("SetState: idempotent self-transition ctx=%u state=%u (noErr)",
		        ctxRef, state);
		return kDSpNoErr;
	}

	/* On activation, request a DMC mode switch if the context's mode
	 * differs from the current snapshot. Skipping same-mode switches
	 * avoids needless OnModeExit/OnModeEnter churn. The DMC handles
	 * everything downstream (overlay-cache clear, frame interval, palette,
	 * gamma, snapshot publish). Its subscribers must not re-enter DSp, and
	 * a mode switch must never be nested inside a palette-change callback
	 * (the DMC returns kDMCErrReentrantRequest). */
	if (state == (uint32_t)kDSpContextState_Active &&
	    prev_state != (uint32_t)kDSpContextState_Active) {
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
			new_mode.vbl_usec  = 0;  /* 0 keeps the current cadence */
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
			DSP_LOG("SetState: mode switch %ux%u@%u completed via DMC "
			        "(backBuffer@%u ctx=%u)",
			        ctx->attr.displayWidth, ctx->attr.displayHeight,
			        display_depth, ctx->attr.backBufferBestDepth, ctxRef);
		}
	}

	/* DSpMapStateToDMCOwnerTyped (internal header) returns the DMCOwner
	 * enum; the public variant returns uint32_t. */
	DMCOwner new_owner = DSpMapStateToDMCOwnerTyped(state);
	if (state != (uint32_t)kDSpContextState_Active) {
		for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; ++i) {
			DSpContextPrivate *other = dsp_context_table[i];
			if (other != nullptr && other != ctx &&
			    other->state == (uint32_t)kDSpContextState_Active) {
				new_owner = kDMCOwnerDSp;
				break;
			}
		}
	}
	/* Restore the desktop mode for the last context before discarding the
	 * redirect snapshot or changing ctx->state, so a rejected transition
	 * leaves Release everything it needs to retry. */
	const bool switch_handoff =
	    state == (uint32_t)kDSpContextState_Inactive &&
	    s_dsp_setstate_switch_handoff_ctx == ctxRef;
	DMCModeDesc restored_qd_mode = {};
	const bool have_restored_qd_mode =
	    state != (uint32_t)kDSpContextState_Active &&
	    new_owner != kDMCOwnerDSp && !switch_handoff &&
	    DSpBuildSavedQuickDrawModeDesc(ctx, &restored_qd_mode);
	const DMCModeSnapshot *prior_snapshot = dmc_current_snapshot();
	const uint32_t prior_owner = prior_snapshot ? prior_snapshot->active_owner
	                                            : (uint32_t)kDMCOwnerQuickDraw;
	int32_t dmc_rc = dmc_set_active_owner((uint32_t)new_owner);
	if (dmc_rc != 0) {
		DSP_LOG("SetState: DMC rejected transition ctx=%u %u->%u rc=%d",
		        ctxRef, ctx->state, state, dmc_rc);
		return kDSpInvalidAttributesErr;
	}
	if (have_restored_qd_mode) {
		const DMCModeSnapshot *snap = dmc_current_snapshot();
		/* A desktop below 32 bpp needs the switch even when the mode is
		 * unchanged: on activation the compositor replaced its surface
		 * with a standalone BGRA texture (MetalCompositor_OnModeEnter),
		 * and only a snapshot carrying screen_base_host points it back at
		 * the QuickDraw framebuffer. */
		if (snap == nullptr ||
		    restored_qd_mode.depth != 32u ||
		    DSpQuickDrawModeRestoreDiffers(restored_qd_mode.width,
		                                   restored_qd_mode.height,
		                                   restored_qd_mode.depth,
		                                   snap->width, snap->height, snap->depth)) {
			int32_t rc = dmc_request_mode_switch(&restored_qd_mode);
			if (rc != kDMCNoErr) {
				/* DMC mode switches are transactional; put ownership back
				 * too, keeping the live surface and its saved desktop. */
				(void)dmc_set_active_owner(prior_owner);
				DSP_LOG("SetState: QuickDraw restore rejected rc=%d; "
				        "ctx=%u retained for retry", rc, ctxRef);
				return kDSpInternalErr;
			}
		}
	}
	/* PDF p.29 resets page flipping to page 0 on Paused. Page flipping
	 * isn't implemented. */
	if (state == (uint32_t)kDSpContextState_Paused) {
		DSP_LOG("SetState: Paused — page-flip reset to page 0 (no-op; "
		        "page flipping not implemented)");
	}
	DSP_LOG("SetState: ctx=%u %u->%u DMC owner->%d",
	        ctxRef, ctx->state, state, (int)new_owner);
	ctx->state = state;

	/*
	 *  On activation, replay the stored CLUT to the compositor so the first
	 *  active frame shows the default CLUT, a Reserve colorTable, or a
	 *  SetCLUTEntries made while Paused. Leaving Active needs no push: the
	 *  compositor keeps the last CLUT. Same calls as the Set handler.
	 */
	if (state == (uint32_t)kDSpContextState_Active) {
		ctx->front_staging_present_state.encoded = false;
		MetalCompositorUpdatePalette(ctx->clut_bytes, 256);
		dmc_record_palette_change();
		DSP_LOG("SetState: %u->Active CLUT replay (ctx=%u) -> OK",
		        prev_state, ctxRef);
	}

	/*
	 *  Every DSp context is fullscreen, so "any Active context" drives the
	 *  host idle-timer bridge. DSpHostBridge_SetActiveFullscreen posts a
	 *  notification that DSpIdleTimerService uses to toggle
	 *  isIdleTimerDisabled. Call it only when the aggregate changes, to
	 *  avoid spamming the observer.
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

	/* Install or drop the MainDevice PixMap redirect. Must run after the
	 * owner change and ctx->state update. The DSp heap is exempt from the
	 * on_mode_exit reset, so back_buffer survives the mode switch. */
	if (state == (uint32_t)kDSpContextState_Active) {
		DSpRedirectMainDevicePixMap(ctx);
	} else {
		DSpRestoreMainDevicePixMap(ctx);
		if (any_active) {
			for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; ++i) {
				DSpContextPrivate *other = dsp_context_table[i];
				if (other != nullptr && other->state == (uint32_t)kDSpContextState_Active) {
					DSpRedirectMainDevicePixMap(other);
					break;
				}
			}
		}
		if (switch_handoff) {
			DSP_LOG("SetState: ctx=%u switch handoff suppressed "
			        "intermediate QuickDraw mode restore", ctxRef);
		}
	}

	return kDSpNoErr;
}

/* --- DSpContext_GetStateHandler ---
 *
 *  ctx->state is authoritative; the DMC's active_owner is derived from it,
 *  so there is no DMC round-trip. A zero outStateAddr returns
 *  kDSpInvalidContextErr, as DSp 1.7 does.
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


/* --- DSpContext_IsBusyHandler (sub-op 730) ---
 *
 *  DSp 1.7 PDF p.40: outBusyFlag is true when no back buffer is ready. Our
 *  single back buffer is always ready once allocated, so report false, or
 *  true for a context with no back buffer yet. 1-byte Boolean. */
extern "C" int32_t DSpContext_IsBusyHandler(uint32_t ctxRef,
                                             uint32_t outBusyAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outBusyAddr == 0) {
		DSP_LOG("IsBusy: invalid ctxRef=%u or outBusyAddr=0x%08x",
		        ctxRef, outBusyAddr);
		return kDSpInvalidContextErr;
	}
	WriteMacInt8(outBusyAddr, (ctx->back_buffer != nil) ? 0 : 1);
	return kDSpNoErr;
}


/* GetDisplayID returns classic Display Manager IDs (video.h viAppleID).
 * There is one fullscreen display, so every ID maps to it. */

/* --- DSpContext_GetDisplayIDHandler (sub-op 731) ---
 *
 *  DSp 1.7 PDF pp.14-15. Reports kDSpGuestDMMainDisplayID, the guest
 *  Display Manager's ID for the screen, so apps can pass it to
 *  DMGetGDeviceByDisplayID. The per-mode APPLE_* IDs are not DM display
 *  IDs and fail that lookup (see dsp_display_id_policy.h). */
extern "C" int32_t DSpContext_GetDisplayIDHandler(uint32_t ctxRef,
                                                   uint32_t outIDAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || outIDAddr == 0) {
		DSP_LOG("GetDisplayID: invalid ctxRef=%u or outIDAddr=0x%08x",
		        ctxRef, outIDAddr);
		return kDSpInvalidContextErr;
	}
	const uint32_t display_id = kDSpGuestDMMainDisplayID;
	WriteMacInt32(outIDAddr, display_id);
	DSP_LOG("GetDisplayID: ctx=%u %ux%u -> displayID=0x%08x",
	        ctxRef, ctx->attr.displayWidth, ctx->attr.displayHeight,
	        display_id);
	return kDSpNoErr;
}


/* Base dirty-rect grid unit: 32x32 px, the PPC cache line (DSp 1.7 PDF
 * p.43). SetDirtyRectGridSize rounds requests up to a multiple of it. */
#define kDSpDirtyRectGridUnit 32u

/* --- DSpContext_GetDirtyRectGridUnitsHandler (sub-op 738) ---
 *
 *  DSp 1.7 PDF p.43. Always reports the constant 32 x 32 base unit. */
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


/* --- DSpContext_GetMaxFrameRateHandler (sub-op 734) ---
 *
 *  DSp 1.7 PDF pp.44-45. 0 means no limit. */
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
 *  DSp 1.7 PDF p.44. Stored only; SwapBuffers does the pacing. */
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


/* Display refresh as a Fixed 16.16 Hz value: (1e6 << 16) / cadence_usec. */
static uint32_t DSpComputeMonitorFrequencyFixed(void)
{
	uint64_t cadence = vbl_source_get_cadence_usec();   /* usec per VBL */
	/* PDF pp.19, 46 allow 0 when not yet timed. */
	return (cadence > 0) ? (uint32_t)((1000000ULL << 16) / cadence) : 0;
}

/* --- DSpContext_GetMonitorFrequencyHandler (sub-op 733) ---
 *
 *  DSp 1.7 PDF pp.19, 45-46. Refresh rate as Fixed 16.16 Hz from the VBL
 *  cadence. */
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


/* Round a grid cell dimension up to a multiple of the 32 px base unit
 * (DSp 1.7 PDF p.41). 0 stays 0, meaning "use the base unit". */
static uint32_t DSpRoundUpToGridUnit(uint32_t v)
{
	if (v == 0) return 0;
	return ((v + kDSpDirtyRectGridUnit - 1) / kDSpDirtyRectGridUnit)
	       * kDSpDirtyRectGridUnit;
}

/* --- DSpContext_SetDirtyRectGridSizeHandler (sub-op 737) ---
 *
 *  DSp 1.7 PDF p.41. Stores each dimension rounded up to the base unit. */
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
 *  DSp 1.7 PDF p.42. Defaults to the 32x32 base unit until set. */
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


#define DSP_FRONT_PIXMAP_SIZE DSpFrontBufferPixMapRecordSize()
#define DSP_FRONT_CGP_SIZE DSP_CGRAFPORT_MIN_SIZE

/* Build a real guest CGrafPort (50-byte PixMap, PixMapHandle, portVersion
 * 0xC000, rect vis/clip regions) for a DSp drawable. Every CGrafPtr DSp
 * hands out (front, back and alt buffers) goes through here. Guests use
 * them as real ports (portPixMap -> GetPixBaseAddr / CopyBits / portRect),
 * so a PixMap-shaped shim isn't enough: Diablo II software mode draws
 * through the alt-buffer port.
 * seed_pixmap_mac (0 = zero-fill) seeds the PixMap before the canonical
 * fields are written; the front buffer passes the saved MainDevice PixMap.
 * Returns the CGrafPort address, or 0. out_pixmap_mac and
 * out_pixmap_handle_mac are optional. */
extern "C" uint32_t DSpEmitSurfaceCGrafPort(uint32_t baseAddr_mac,
                                            uint32_t w,
                                            uint32_t h,
                                            uint32_t depth,
                                            uint32_t row_bytes,
                                            uint32_t seed_pixmap_mac,
                                            uint32_t *out_pixmap_mac,
                                            uint32_t *out_pixmap_handle_mac,
                                            uint32_t port_storage)
{
	if (baseAddr_mac == 0 || w == 0 || h == 0 || row_bytes == 0) return 0;

	if (port_storage == 0) return 0;
	const uint32_t pixmap_addr = port_storage + DSpPortPixMapOffset;
	const uint32_t pixmap_handle_addr = port_storage + DSpPortPixMapHandleOffset;
	const uint32_t cgrafptr_addr = port_storage + DSpPortCGrafOffset;
	auto region = [&](uint32_t record, uint32_t handle) {
		Mac_memset(record, 0, DSP_RECT_REGION_SIZE);
		WriteMacInt16(record + DSP_REGION_OFF_SIZE, DSP_RECT_REGION_SIZE);
		WriteMacInt16(record + DSP_REGION_OFF_BBOX + 4, (uint16_t)h);
		WriteMacInt16(record + DSP_REGION_OFF_BBOX + 6, (uint16_t)w);
		WriteMacInt32(handle, record);
		return handle;
	};
	const uint32_t vis_rgn_handle = region(port_storage + DSpPortVisRegionOffset,
	                                      port_storage + DSpPortVisHandleOffset);
	const uint32_t clip_rgn_handle = region(port_storage + DSpPortClipRegionOffset,
	                                       port_storage + DSpPortClipHandleOffset);

	uint16_t pixelType, pixelSize, cmpCount, cmpSize;
	DSpPixMapFormatForDepth(depth,
	                         &pixelType, &pixelSize, &cmpCount, &cmpSize);

	const uint16_t row_bytes_field =
	    DSpFrontBufferPixMapRowBytesField(row_bytes);

	if (seed_pixmap_mac != 0) {
		Host2Mac_memcpy(pixmap_addr,
		                Mac2HostAddr(seed_pixmap_mac),
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
	// InitCPort defaults: black foreground, white background (IM QD 4-65).
	// CopyBits colorizes through these even for srcCopy; swapped, every
	// copied image comes out as a negative (e.g. Civilization III).
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 0, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 2, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 4, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 0,
	              0xffff);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 2,
	              0xffff);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 4,
	              0xffff);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PN_SIZE + 0, 1);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PN_SIZE + 2, 1);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PN_MODE, 8);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_TX_SIZE, 12);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_FG_COLOR, 0xffffffffu);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_BK_COLOR, 0x00000000u);

	if (out_pixmap_mac != nullptr) *out_pixmap_mac = pixmap_addr;
	if (out_pixmap_handle_mac != nullptr)
		*out_pixmap_handle_mac = pixmap_handle_addr;
	return cgrafptr_addr;
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

	/* Seed from the saved MainDevice PixMap when it is valid and in guest
	 * RAM, so unspecified fields inherit the real screen's metadata. */
	uint32_t seed_pixmap_mac = 0;
	if (ctx->saved_pixmap_valid != 0 &&
	    ctx->saved_pixmap_addr != 0 &&
	    DSpGuestRAMContains(ctx->saved_pixmap_addr,
	                        DSP_FRONT_PIXMAP_SIZE,
	                        (uint32_t)RAMBase,
	                        (uint32_t)RAMSize)) {
		seed_pixmap_mac = ctx->saved_pixmap_addr;
	}

	uint32_t pixmap_addr = 0;
	uint32_t pixmap_handle_addr = 0;
	uint32_t cgrafptr_addr = DSpEmitSurfaceCGrafPort(baseAddr_mac,
	                                                 w, h,
	                                                 front_depth,
	                                                 row_bytes,
	                                                 seed_pixmap_mac,
	                                                 &pixmap_addr,
	                                                 &pixmap_handle_addr,
	    DSpGuestPortStorageSlot(dsp_guest_port_storage_addr,
	        DSP_MAX_CONTEXTS + ctx->handle - 1,
	        2 * DSP_MAX_CONTEXTS + DSP_MAX_ALT_BUFFERS));
	if (cgrafptr_addr == 0) {
		DSP_LOG("DSpGetFrontBufferCGrafPtr: CGrafPort emission failed "
		        "(ctx=%u %ux%u@%u)", ctx->handle, w, h, front_depth);
		return 0;
	}

	ctx->front_cgrafptr_mac_addr = cgrafptr_addr;
	ctx->front_pixmap_mac_addr = pixmap_addr;
	ctx->front_pixmap_handle_mac_addr = pixmap_handle_addr;
	DSP_LOG("DSpGetFrontBufferCGrafPtr: ctx=%u cgrafptr=0x%08x pixmapH=0x%08x "
	        "pixmap=0x%08x baseAddr=0x%08x "
	        "rbRaw=0x%04x rb=%u pixelSize=%u "
	        "hRes=0x%08x vRes=0x%08x pmTable=0x%08x (backBuffer@%u)",
	        ctx->handle, cgrafptr_addr, pixmap_handle_addr, pixmap_addr,
	        baseAddr_mac,
	        ReadMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES),
	        row_bytes,
	        ReadMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE),
	        ReadMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_HRES),
	        ReadMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_VRES),
	        ReadMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_PMTABLE),
	        ctx->attr.backBufferBestDepth);
	return cgrafptr_addr;
}

/* --- DSpContext_GetFrontBufferHandler (sub-op 732) ---
 *
 *  DSp 1.7 PDF p.36: "The front buffer is the screen display." A context
 *  can pair a low-depth back buffer with a higher-depth display (for
 *  RAVE/QD3D discovery); the front CGrafPtr then describes the display,
 *  not the back buffer. */
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


/* --- DSpGetCurrentContextHandler (sub-op 745) ---
 *
 *  DSp 1.7 PDF p.15: DSpGetCurrentContext(DisplayIDType inDisplayID,
 *  DSpContextReference *outContext). The first arg is a display ID, not a
 *  ctxRef; every accepted ID maps to the one display. Returns the Active
 *  context with a live back buffer, or writes 0 and returns
 *  kDSpContextNotFoundErr. */
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


/* Low-memory MouseLocation Point (DSp 1.7 PDF p.54: DSpGetMouse reports
 * the Toolbox's global mouse position). adb.cpp keeps it current. */
#define kDSpLM_MouseLocation_v 0x82cu   /* Point.v */
#define kDSpLM_MouseLocation_h 0x82eu   /* Point.h */


/* Current global mouse position from the MouseLocation low-memory Point. */
static void DSpReadGlobalMousePoint(int16_t *v, int16_t *h)
{
	*v = (int16_t)ReadMacInt16(kDSpLM_MouseLocation_v);
	*h = (int16_t)ReadMacInt16(kDSpLM_MouseLocation_h);
}

/* --- DSpGetMouseHandler (sub-op 720) ---
 *
 *  DSp 1.7 PDF p.54: DSpGetMouse(Point *outGlobalPoint). No context; r3 is
 *  the out Point (v at +0, h at +2, big-endian int16). */
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


/* --- DSpContext_GlobalToLocalHandler (sub-op 721) ---
 *
 *  DSp 1.7 PDF p.55. The single fullscreen context's local origin is
 *  (0,0), so this is the identity. If a nonzero context offset is ever
 *  needed, subtract it here. */
extern "C" int32_t DSpContext_GlobalToLocalHandler(uint32_t ctxRef,
                                                   uint32_t ioPointAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || ioPointAddr == 0) {
		DSP_LOG("GlobalToLocal: invalid ctxRef=%u or ioPointAddr=0x%08x",
		        ctxRef, ioPointAddr);
		return kDSpInvalidContextErr;
	}
	const int16_t v = (int16_t)ReadMacInt16(ioPointAddr + 0);
	const int16_t h = (int16_t)ReadMacInt16(ioPointAddr + 2);
	WriteMacInt16(ioPointAddr + 0, (uint16_t)v);
	WriteMacInt16(ioPointAddr + 2, (uint16_t)h);
	return kDSpNoErr;
}


/* --- DSpContext_LocalToGlobalHandler (sub-op 722) ---
 *
 *  DSp 1.7 PDF p.55. Inverse of GlobalToLocal; also the identity. */
extern "C" int32_t DSpContext_LocalToGlobalHandler(uint32_t ctxRef,
                                                   uint32_t ioPointAddr)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr || ioPointAddr == 0) {
		DSP_LOG("LocalToGlobal: invalid ctxRef=%u or ioPointAddr=0x%08x",
		        ctxRef, ioPointAddr);
		return kDSpInvalidContextErr;
	}
	const int16_t v = (int16_t)ReadMacInt16(ioPointAddr + 0);
	const int16_t h = (int16_t)ReadMacInt16(ioPointAddr + 2);
	WriteMacInt16(ioPointAddr + 0, (uint16_t)v);
	WriteMacInt16(ioPointAddr + 2, (uint16_t)h);
	return kDSpNoErr;
}


/* Handle of the Active context (with a live back buffer) containing the
 * global point, or 0 when the point is off-screen or nothing is Active. */
static uint32_t DSpResolveContextHandleAtPoint(int16_t v, int16_t h)
{
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = dsp_context_table[i];
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
		if (ctx->back_buffer == nil) continue;
		/* v = row, h = column. The fullscreen context contains
		 * [0, displayHeight) x [0, displayWidth). */
		const int32_t dispW = (int32_t)ctx->attr.displayWidth;
		const int32_t dispH = (int32_t)ctx->attr.displayHeight;
		if (v < 0 || h < 0 || (int32_t)v >= dispH || (int32_t)h >= dispW) {
			return 0;   /* off-screen */
		}
		return ctx->handle;
	}
	return 0;   /* no Active context */
}

/* --- DSpFindContextFromPointHandler (sub-op 723) ---
 *
 *  DSp 1.7 PDF p.53: DSpFindContextFromPoint(Point inGlobalPoint,
 *  DSpContextReference *outContext). The Point is passed by value; the
 *  dispatcher unpacks it from r3 (v = high half, h = low half). An
 *  off-screen point or no Active context writes 0 and returns
 *  kDSpContextNotFoundErr. */
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


/* ==========================================================================
 *  Discovery / multi-display (sub-ops 744, 746, 747, 760, 761).
 *  There is one display: FindBestContextOnDisplayID and UserSelectContext
 *  delegate to DSpFindBestContextHandler. SetDebugMode only stores a flag.
 *  SetBlankingColor sets the DMC blanking color without entering the
 *  Blanking state.
 * ========================================================================== */

/* DSpSetDebugMode flag (sub-op 761). Stored only; nothing reads it yet.
 * Emul thread only. */
static bool s_dsp_debug_mode = false;

/* --- DSpSetDebugModeHandler (sub-op 761) ---
 *
 *  DSp 1.7 PDF p.59: DSpSetDebugMode(Boolean inDebugMode). No ctxRef. */
extern "C" int32_t DSpSetDebugModeHandler(uint32_t inDebugMode)
{
	s_dsp_debug_mode = (inDebugMode != 0);
	DSP_LOG("SetDebugMode: s_dsp_debug_mode = %d", (int)s_dsp_debug_mode);
	return kDSpNoErr;
}


/* --- DSpCanUserSelectContextHandler (sub-op 746) ---
 *
 *  DSp 1.7 PDF p.19. Answers whether more than one cached mode meets the
 *  requested minimum attributes, not whether the host has several
 *  displays. Classic games use false to skip their mode picker and call
 *  DSpFindBestContext.
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


/* --- DSpFindBestContextOnDisplayIDHandler (sub-op 744) ---
 *
 *  DSp 1.7 PDF p.14: DSpFindBestContextOnDisplayID(DSpContextAttributesPtr
 *  inDesiredAttributes, DSpContextReference *outContext, DisplayIDType
 *  inDisplayID): r3 = attrs, r4 = outContext, r5 = displayID.
 *  Any display ID maps to the one screen (like GetFirstContext), then this
 *  delegates to DSpFindBestContextHandler. An unmatchable request returns
 *  0 + kDSpContextNotFoundErr from there. */
extern "C" int32_t DSpFindBestContextOnDisplayIDHandler(uint32_t attrAddr,
                                                        uint32_t outCtxRefAddr,
                                                        uint32_t inDisplayID)
{
	if (outCtxRefAddr == 0) {
		DSP_LOG("FindBestContextOnDisplayID: NULL outCtxRefAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	if (!DSpAcceptsSingleDisplayID(inDisplayID)) {
		/* Log non-main IDs (apps pass Display Manager IDs, e.g. 256). */
		DSP_LOG("FindBestContextOnDisplayID: displayID=%u accepted "
		        "(single-screen iOS — mapped to backing screen)", inDisplayID);
	}
	return DSpFindBestContextHandler(attrAddr, outCtxRefAddr);
}


/* --- DSpUserSelectContextHandler (sub-op 747) ---
 *
 *  DSp 1.7 PDF p.20: DSpUserSelectContext(DSpContextAttributesPtr
 *  inDesiredAttributes, DisplayIDType inDialogDisplayLocation,
 *  DSpEventProcPtr inCleanupEventProc, DSpContextReference *outContext):
 *  r3..r6. Real DSp shows a selection dialog; with one display there's
 *  nothing to choose, so this auto-picks via DSpFindBestContextHandler. */
extern "C" int32_t DSpUserSelectContextHandler(uint32_t attrAddr,
                                               uint32_t inDialogDisplayLocation,
                                               uint32_t inEventProc,
                                               uint32_t outCtxRefAddr)
{
	(void)inDialogDisplayLocation;   /* no dialog on a single display */
	(void)inEventProc;               /* no dialog, so no cleanup proc */
	if (outCtxRefAddr == 0) {
		DSP_LOG("UserSelectContext: NULL outCtxRefAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	return DSpFindBestContextHandler(attrAddr, outCtxRefAddr);
}


/* --- DSpSetBlankingColorHandler (sub-op 760) ---
 *
 *  DSp 1.7 PDF p.30: DSpSetBlankingColor(const RGBColor *inRGBColor). No
 *  ctxRef. Sets the color used the next time a context blanks; it doesn't
 *  blank now. RGBColor is three 16-bit channels at +0/+2/+4, reduced to
 *  8-bit by the high byte, alpha 0xFF. Best effort: a missing DMC still
 *  returns kDSpNoErr. */
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


/* --- DSpContext_InvalBackBufferRectHandler ---
 *
 *  InvalBackBufferRect (PDF p.38) marks a drawn sub-region so SwapBuffers
 *  can upload only that part. Rects are unioned into one bounding rect:
 *  classic apps dirty either everything or one rect, so a list or tile
 *  grid isn't worth it. SwapBuffers falls back to a full upload above 90%
 *  coverage.
 *
 *  With no Inval call between swaps the whole buffer is dirty (PDF p.38).
 *  Reserve and foreground restore set dirty_cold_start, which SwapBuffers
 *  checks first.
 *
 *  Out-of-range rect fields are clamped, not rejected; empty or inverted
 *  rects are ignored.
 */

/*
 *  Clamp the rect and union it into the accumulator. Negative edges clamp
 *  to 0; right/bottom clamp to displayWidth/displayHeight.
 */
static void DSpInvalBackBufferRect_Accumulate(DSpContextPrivate *ctx,
                                               int16_t top, int16_t left,
                                               int16_t bottom, int16_t right)
{
	if (ctx == nullptr) return;

	int32_t clamped_top    = (top    < 0) ? 0 : top;
	int32_t clamped_left   = (left   < 0) ? 0 : left;
	int32_t clamped_bottom = (bottom < 0) ? 0 : bottom;
	int32_t clamped_right  = (right  < 0) ? 0 : right;
	if ((uint32_t)clamped_right  > ctx->attr.displayWidth)
		clamped_right  = (int32_t)ctx->attr.displayWidth;
	if ((uint32_t)clamped_bottom > ctx->attr.displayHeight)
		clamped_bottom = (int32_t)ctx->attr.displayHeight;

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
	/* Big-endian Rect of 4 x int16; cast for the sign. */
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


/* ============================================================== */
/*  DSpContext_GetAttributes (sub-opcode 202)                      */
/*                                                                 */
/*  Returns ctx->attr as reserved (normalized for state), in the   */
/*  PDF p.65 layout. PDF p.18 asks for the active attributes; that */
/*  is the same thing because FindBest never substitutes a mode.   */
/*  If substitution is added, store and prefer an actual_attr.     */
/*  Lives here because the context table is private to this file.  */
/* ============================================================== */

/*
 *  Write DSpContextAttributes to guest RAM in the PDF p.65 layout, zeroing
 *  reserved and filler fields so the app never sees stale guest memory.
 *  frequency is always 0 ("not available", PDF p.66).
 */
static void DSpWriteAttributesCore(const DSpContextAttributes *attr,
                                    uint32_t outAttrAddr)
{
	/* DSp 1.7 PDF p.65: all UInt32/Fixed/OptionBits/CTabHandle fields are
	 * 4 bytes. filler[3] + gameMustConfirmSwitch fill +52..+55;
	 * reserved3[4] is +56..+71. */
	WriteMacInt32(outAttrAddr +  0, 0 /* frequency unavailable, PDF p.66 */);
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
	/* filler[3] @ +52..+54, gameMustConfirmSwitch (Boolean) @ +55. */
	WriteMacInt8 (outAttrAddr + 52, 0 /* filler[0] */);
	WriteMacInt8 (outAttrAddr + 53, 0 /* filler[1] */);
	WriteMacInt8 (outAttrAddr + 54, 0 /* filler[2] */);
	WriteMacInt8 (outAttrAddr + 55, (uint8_t)(attr->gameMustConfirmSwitch ? 1 : 0));
	/* reserved3[0..3] @ +56..+71. */
	WriteMacInt32(outAttrAddr + 56, 0 /* reserved3[0] */);
	WriteMacInt32(outAttrAddr + 60, 0 /* reserved3[1] */);
	WriteMacInt32(outAttrAddr + 64, 0 /* reserved3[2] */);
	WriteMacInt32(outAttrAddr + 68, 0 /* reserved3[3] */);
}

extern "C" int32_t DSpContext_GetAttributesHandler(uint32_t ctxRef,
                                                    uint32_t outAttrAddr)
{
	/* Check outAttrAddr first so a bad pointer with a valid handle reports
	 * kDSpInvalidAttributesErr rather than kDSpInvalidContextErr. */
	if (outAttrAddr == 0) {
		DSP_LOG("GetAttributes: NULL outAttrAddr (ctxRef=%u) -> "
		        "kDSpInvalidAttributesErr", ctxRef);
		return kDSpInvalidAttributesErr;
	}
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



/*
 *  DSpContext_FadeGammaIn (sub-opcode 402), DSp 1.7 PDF p.35:
 *  (inContext, RGBColor *inZeroIntensityColor). Fades to full intensity,
 *  i.e. the driver's installed gamma table, over one second.
 *  DSpVBLGammaFadeCallback advances the fade; starting a new fade while
 *  one is running continues from its current value.
 */
extern "C" int32_t DSpContext_FadeGammaInHandler(uint32_t ctxRef,
                                                  uint32_t colorAddr)
{
	/*
	 *  PDF p.35: a NULL context fades all displays (ambient). Apps call
	 *  FadeGammaOut(NULL, NULL) between Reserve and SetState (Apple's
	 *  "OpenGL DrawSprocket.c" sample). Accept it as a no-op returning
	 *  kDSpNoErr: The Sims treats an error here as DSp being broken and
	 *  never issues GetBackBuffer/SwapBuffers. Later per-context fades
	 *  keep the display correct.
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
	 *  The fade is a fixed one second (PDF p.35), not a guest duration.
	 *  Convert from the live VBL cadence (60 at 60 Hz, 120 at 120 Hz).
	 *  The tint only defines the 0% start, and the start is taken from the
	 *  current displayed gamma, so it is unused here.
	 */
	(void)colorAddr;

	uint64_t cadence_usec = vbl_source_get_cadence_usec();
	uint32_t vbls_1sec = (cadence_usec > 0)
	                     ? (uint32_t)((1000000ull + cadence_usec / 2) / cadence_usec)
	                     : 60u;
	if (vbls_1sec > DSP_MAX_FADE_VBLS) vbls_1sec = DSP_MAX_FADE_VBLS;

	/* End on the driver table so a game-installed ramp (e.g. overbright)
	 * survives instead of being replaced by identity. */
	uint8_t full_lut[768];
	DSpCopyDriverGammaLUT(full_lut);

	DSpInitFadeStateCore(ctx, full_lut, (uint16_t)vbls_1sec);
	DSP_LOG("FadeGammaIn: ctx=%u 1-second fade -> %u VBLs (cadence %llu usec) started",
	        ctxRef, vbls_1sec, (unsigned long long)cadence_usec);
	return kDSpNoErr;
}

/*
 *  DSpContext_FadeGammaOut (sub-opcode 403), DSp 1.7 PDF p.34. Same
 *  arguments as FadeGammaIn. Fades over one second to 0% intensity: a flat
 *  LUT of the zero-intensity tint, or black when the color is NULL.
 */
extern "C" int32_t DSpContext_FadeGammaOutHandler(uint32_t ctxRef,
                                                   uint32_t colorAddr)
{
	/*
	 *  PDF p.34: NULL context is the ambient fade. Accepted as a no-op;
	 *  see FadeGammaIn.
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
	 *  One-second fade derived from the VBL cadence (PDF p.34). The end
	 *  state is the inZeroIntensityColor tint; NULL means black.
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

	/* At percent 0 the target is the flat tint for every index. */
	uint8_t full_lut[768];
	DSpCopyDriverGammaLUT(full_lut);
	uint8_t end_lut[768];
	DSpComputeFadeGammaTargetLUT(color_r, color_g, color_b, 0, full_lut, end_lut);

	DSpInitFadeStateCore(ctx, end_lut, (uint16_t)vbls_1sec);
	DSP_LOG("FadeGammaOut: ctx=%u tint=(%u,%u,%u) 1-second fade -> %u VBLs "
	        "(cadence %llu usec) started",
	        ctxRef, color_r, color_g, color_b,
	        vbls_1sec, (unsigned long long)cadence_usec);
	return kDSpNoErr;
}


/*
 *  DSpContext_FadeGamma (sub-opcode 404), DSp 1.7 pp.32-33:
 *    OSStatus DSpContext_FadeGamma(DSpContextReference inContext,
 *                                  SInt32 inPercentOfOriginalIntensity,
 *                                  RGBColor *inZeroIntensityColor);
 *  inPercent is signed: 0..100 normal, >100 converges on white, <0 on
 *  black. A NULL color means black (p.32). There is no duration: the app
 *  makes repeated timed calls (p.33), and each call applies its target
 *  immediately.
 *
 *  Errors: kDSpInvalidContextErr (nonzero ctxRef not found),
 *  kDSpInternalErr (DMC publish failed).
 */
extern "C" int32_t DSpContext_FadeGammaHandler(uint32_t ctxRef,
                                                int32_t  inPercent,
                                                uint32_t colorAddr)
{
	/*
	 *  PDF p.32: a NULL context fades all displays. Apple's transition idiom
	 *  fades the ambient display to black and later calls
	 *  FadeGamma(NULL, 100) to restore it, so this must actually apply to
	 *  the compositor gamma; a no-op leaves the screen black (Cro-Mag Rally
	 *  gameplay vanished after a transition). FadeGammaIn/Out (402/403)
	 *  keep their NULL no-op because The Sims depends on it.
	 */
	if (ctxRef == 0) {
		uint8_t color_r = 0, color_g = 0, color_b = 0;
		if (colorAddr != 0) {
			DSpReadParametricColorFromGuest(colorAddr, &color_r, &color_g, &color_b);
		}
		uint8_t full_lut[768];
		DSpCopyDriverGammaLUT(full_lut);
		uint8_t target_lut[768];
		DSpComputeFadeGammaTargetLUT(color_r, color_g, color_b,
		                              inPercent, full_lut, target_lut);
		/* Any percent other than 100 leaves the display mid-fade: the LUT
		 * stays linear and a driver SetGamma arriving now is deferred.
		 * 100 restores the driver table and ends the fade. */
		int32_t rv = DSpPublishFadeGamma(nullptr,
		    target_lut, (inPercent != 100) ? 1 : 0);
		if (rv != kDMCNoErr) {
			DSP_LOG("FadeGamma: ctxRef=0 ambient inPercent=%d "
			        "dmc_record_gamma_change_with_lut_fade returned %d", inPercent, rv);
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

	/* NULL colorAddr means black. */
	uint8_t color_r = 0, color_g = 0, color_b = 0;
	if (colorAddr != 0) {
		DSpReadParametricColorFromGuest(colorAddr, &color_r, &color_g, &color_b);
	}

	uint8_t full_lut[768];
	DSpCopyDriverGammaLUT(full_lut);
	uint8_t target_lut[768];
	DSpComputeFadeGammaTargetLUT(color_r, color_g, color_b,
	                              inPercent, full_lut, target_lut);

	/* Apply once; the app loops the call over time. fade_active as in
	 * the ambient case above. */
	int32_t rv = DSpPublishFadeGamma(ctx,
	    target_lut, (inPercent != 100) ? 1 : 0);
	if (rv != kDMCNoErr) {
		DSP_LOG("FadeGamma: dmc_record_gamma_change_with_lut_fade returned %d "
		        "for ctx=%u",
		        rv, ctxRef);
		return kDSpInternalErr;
	}
	memcpy(ctx->gamma_lut_persisted, target_lut, 768);
	/* An immediate parametric apply cancels any In/Out fade. */
	ctx->fade_state.active = 0;
	DSP_LOG("FadeGamma: ctx=%u inPercent=%d tint=(%u,%u,%u) "
	        "-> target applied immediately",
	        ctxRef, inPercent,
	        color_r, color_g, color_b);
	return kDSpNoErr;
}
