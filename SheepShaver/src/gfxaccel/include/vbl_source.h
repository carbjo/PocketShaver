/*
 *  vbl_source.h - VBL tick source wrapping CAMetalDisplayLink (iOS 17+) /
 *                 CADisplayLink (13.4-16).
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  CAMetalDisplayLink delivers a drawable and target timestamp; the
 *  CADisplayLink fallback delivers timing only, so callers use nextDrawable.
 *
 *  Callbacks fire on the main runloop thread. Tick count and cadence are
 *  _Atomic and read from the emul thread. The CAMetalLayer is passed as void*.
 */

#ifndef VBL_SOURCE_H
#define VBL_SOURCE_H

#include <stdint.h>
#include "gfx_frame_pacing_policy.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Continues the -4000 gfxaccel error block. */
enum GfxAccelVBLError {
	kGfxAccelErrVBLNotInitialized = -4009,
	kGfxAccelErrVBLTimeout        = -4010,
	kGfxAccelErrVBLAlreadyRunning = -4011
};

/*
 * drawable is an id<CAMetalDrawable> on iOS 17+, NULL on the CADisplayLink
 * path. target_presentation_ts is a CFTimeInterval for present(at:).
 */
typedef void (*VBLSourceCallbackFn)(void *ctx,
                                    void *drawable,
                                    double target_presentation_ts);

/* --- Lifecycle --- */

/*
 * Creates the display link for cametal_layer (id<CAMetalLayer>). callback
 * runs every tick with ctx. Returns 0, or kGfxAccelErrVBLAlreadyRunning.
 */
int32_t  vbl_source_init(void *cametal_layer,
                         VBLSourceCallbackFn callback,
                         void *ctx);

/* Invalidates the link and resets tick, cadence and deadline state. Idempotent. */
void     vbl_source_shutdown(void);

/* --- Queries --- */

/* Frame interval in usec; follows ProMotion. 16667 before the first tick. */
uint64_t vbl_source_get_cadence_usec(void);

/* Monotonic VBL tick count; 0 before the first tick. */
uint64_t vbl_source_get_tick_count(void);

/*
 * Nonzero when CAMetalDisplayLink is active. Callers must then not call
 * [layer nextDrawable]; the drawable comes with the callback.
 */
int      vbl_source_uses_metal_display_link(void);

/* Pauses (nonzero) or resumes the link, for background/suspend. */
void     vbl_source_set_paused(int paused);

/*
 * Nonzero while this thread is inside the primary/secondary callback chain.
 * Synchronous lifecycle drains use it to defer to the in-flight tick's drain
 * instead of nesting.
 */
int      vbl_source_in_callback_chain(void);

/* --- 3D deadline pacing --- */

/*
 * Blocks until the engine's next frame deadline: last tick plus cadence, or
 * one cadence from now if ticks stop. Returns kGfxAccelNoErr,
 * kGfxAccelErrVBLTimeout if mach_wait_until fails, or
 * kGfxAccelErrVBLNotInitialized.
 */
int32_t  vbl_source_sync_3d_pacing_for_engine(int32_t engine_id);

/* Legacy wrapper; new code calls vbl_source_sync_3d_pacing_for_engine(). */
int32_t  vbl_source_sync_3d_pacing(void);

/* Records a tick for deadline pacing. Called from the VBL callback only. */
void     vbl_source_signal_3d_pacing(void);

/* --- Secondary-callback fan-out --- */

/*
 * Secondary callbacks run after the primary one in the same tick (DSp
 * release-queue drain, background/foreground drain). They live here so the
 * compositor stays unaware of DSp.
 *
 * Returns 0, or kGfxAccelErrVBLAlreadyRunning when all slots are taken.
 * Register at DSpInit time, before the first tick.
 */
#define VBL_SECONDARY_CALLBACK_MAX 5
int32_t vbl_source_register_secondary_callback(VBLSourceCallbackFn cb,
                                                void *ctx);
void    vbl_source_unregister_secondary_callback(VBLSourceCallbackFn cb);

#ifdef __cplusplus
}
#endif

#endif /* VBL_SOURCE_H */
