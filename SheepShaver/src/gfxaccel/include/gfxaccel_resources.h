/*
 *  gfxaccel_resources.h - Cross-boundary Metal resource lifetime owner.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Owns the Metal resources that cross the engine/compositor boundary:
 *  per-engine overlay texture pairs, the zero-copy framebuffer MTLBuffer
 *  over guest RAM, and the DMC fan-out through which engines attach and
 *  detach instead of subscribing to DMC themselves.
 *
 *  gfxaccel_resources_init() must subscribe to DMC after
 *  MetalCompositorInit(). DMC enters in LIFO order, so engines attach before
 *  the compositor's first post-switch present; it exits in FIFO order, so the
 *  compositor drops drawable refs before engines detach.
 *
 *  Emul thread only, no locking. Metal objects are exposed as void* so the
 *  header works from .cpp, .mm and Swift.
 */

#ifndef GFXACCEL_RESOURCES_H
#define GFXACCEL_RESOURCES_H

#include <stdint.h>

#include "display_mode_controller.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Declared only here. The compositor must stay engine-blind: kGfxEngine*
 * must never appear in metal_compositor.{h,mm} or compositor_shaders.metal. */
typedef enum {
	kGfxEngineNQD    = 0,
	kGfxEngineRAVE   = 1,
	kGfxEngineGL     = 2,
	kGfxEngineDSp    = 3,
	kGfxEngineCount  = 4
} GfxEngineId;

/*
 * Engines register attach/detach callbacks here rather than with DMC. This
 * module is the single DMC subscriber for engines and dispatches LIFO on
 * enter and FIFO on exit, like DMC.
 *
 * A nonzero attach return becomes kDMCErrSubscriberRejected and triggers
 * DMC rollback, so an engine that can't allocate can veto a mode switch.
 * Detach returns are advisory.
 */
typedef int32_t (*GfxResAttachFn)(uint32_t engine_id,
                                  const struct DMCModeSnapshot *incoming,
                                  void *ctx);
typedef int32_t (*GfxResDetachFn)(uint32_t engine_id,
                                  const struct DMCModeSnapshot *outgoing,
                                  void *ctx);

struct GfxResEngineHandlers {
	GfxResAttachFn attach;   /* nullable */
	GfxResDetachFn detach;   /* nullable */
	void          *ctx;      /* passed verbatim to attach/detach */
};

/* -4000 block, clear of DMC's -3000..-3099 range. */
enum GfxAccelResourcesError {
	kGfxAccelResNoErr           = 0,
	kGfxAccelResErrGeneric      = -4001,
	kGfxAccelResErrNotInit      = -4002, /* called before gfxaccel_resources_init() */
	kGfxAccelResErrAlreadyInit  = -4003, /* defensive only; init is idempotent */
	kGfxAccelResErrInvalidEngine = -4004, /* engine_id >= kGfxEngineCount */
	kGfxAccelResErrMisaligned   = -4005, /* framebuffer not page-aligned */
	kGfxAccelResErrAllocFailed  = -4006  /* Metal newBuffer/newTexture returned nil */
};

/* --- Lifecycle --- */

/*
 * Idempotent. Requires SharedMetalDevice() and must run after
 * MetalCompositorInit() has subscribed to DMC (see file header).
 * Returns kGfxAccelResErrGeneric if dmc_subscribe fails with anything other
 * than kDMCErrSubscriberAlreadyRegistered.
 */
int32_t gfxaccel_resources_init(void);

/*
 * Idempotent. Releases the overlay textures, framebuffer buffer and shared
 * depth-stencil texture, drops any still-registered engines, and
 * unsubscribes from DMC. Call before MetalCompositorShutdown().
 */
void gfxaccel_resources_shutdown(void);

/* --- Engine fan-out registry --- */

/*
 * Call from engine init after gfxaccel_resources_init(). Re-registering an
 * engine_id replaces its entry. Either handler may be NULL.
 */
void gfxaccel_resources_register_engine(uint32_t engine_id,
                                        const struct GfxResEngineHandlers *h);

/* Call at engine shutdown. No-op if engine_id isn't registered. */
void gfxaccel_resources_unregister_engine(uint32_t engine_id);

/* --- Framebuffer MTLBuffer --- */

/*
 * Vend the framebuffer MTLBuffer wrapping guest RAM (newBufferWithBytesNoCopy,
 * shared storage, deallocator:nil). Cached per (host_base, length); new args
 * replace the buffer.
 *
 * host_base must be vm_page_size-aligned, or Metal asserts on 16K-page
 * devices; misaligned input logs and returns NULL. Also NULL before init or
 * if Metal fails.
 *
 * Owned by this module; don't release it. Valid until shutdown or the next
 * call that replaces it.
 */
void *gfxaccel_resources_get_framebuffer_buffer(void *host_base, uint32_t length);

/* --- Per-engine overlay texture fleet --- */

/*
 * Vend overlay texture 0 for engine_id (RenderTarget | ShaderRead, private
 * storage). Same size returns the cached texture; a new size releases the
 * engine's pair and allocates fresh. Engines never share textures. NULL on
 * bad engine_id, before init, or if allocation fails.
 */
void *gfxaccel_resources_vend_overlay_texture(uint32_t engine_id,
                                              uint32_t width,
                                              uint32_t height,
                                              uint32_t pixel_format);

/*
 * Vend texture 0 or 1 of an engine's overlay pair. Both share size and
 * format; a different size or format releases the pair.
 */
void *gfxaccel_resources_vend_overlay_texture_indexed(uint32_t engine_id,
                                                      uint32_t texture_index,
                                                      uint32_t width,
                                                      uint32_t height,
                                                      uint32_t pixel_format);

/*
 * Release an engine's overlay texture (mode exit or engine shutdown). An
 * unknown handle logs a warning; NULL is a no-op.
 */
void gfxaccel_resources_release_overlay_texture(uint32_t engine_id, void *texture);

/* --- Per-buffer engine-id ownership tagging --- */

/*
 * Tag a buffer (as returned by gfxaccel_resources_heap_alloc_buffer) with
 * its owning engine so arbitration code can query it without engine-specific
 * types. Retagging replaces the old tag. No-op for NULL buffer or invalid
 * engine_id. Fixed 32-entry map.
 *
 * The compositor never queries this; it only sees slot and source handle.
 */
void gfxaccel_resources_set_buffer_owner(void *buffer, uint32_t engine_id);

/* Remove a buffer's tag before the buffer is dropped, so the map holds no
 * dangling pointer. No-op if NULL or untagged. */
void gfxaccel_resources_clear_buffer_owner(void *buffer);

/* --- Background/Foreground lifecycle --- */

/*
 * Called by BackgroundLifecycleObserver on the main thread. Pauses the VBL
 * source, drains in-flight GPU work, releases drawables (drawableSize =
 * CGSizeZero), then runs the DSp background hook. Must return within 50 ms.
 */
void gfxaccel_handle_background_enter(void);

/*
 * Called by BackgroundLifecycleObserver on the main thread. Restores
 * drawableSize from the DMC snapshot, resumes the VBL source, then runs the
 * DSp foreground hook. Rendering resumes on the next VBL tick.
 */
void gfxaccel_handle_foreground_enter(void);

/* DSp lifecycle hooks; fn may be NULL. */
typedef void (*GfxAccelLifecycleHookFn)(void *ctx);
void gfxaccel_set_dsp_background_hook(GfxAccelLifecycleHookFn fn, void *ctx);
void gfxaccel_set_dsp_foreground_hook(GfxAccelLifecycleHookFn fn, void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* GFXACCEL_RESOURCES_H */
