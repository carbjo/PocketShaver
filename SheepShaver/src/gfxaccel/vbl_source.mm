/*
 *  vbl_source.mm - VBL tick source implementation.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Wraps CAMetalDisplayLink (iOS 17+) and CADisplayLink (13.4-16) behind
 *  the C-callable API declared in vbl_source.h.  The iOS 17+ path
 *  delivers the drawable and target presentation timestamp directly in
 *  the callback; the legacy path delivers timing only.
 *
 *  Design notes:
 *    - @available(iOS 17, *) branch inside vbl_source_init().
 *    - Cadence derived from inter-callback delta (17+) or
 *      CADisplayLink.duration (13.4-16).
 *    - Monotonic uint64 tick count incremented per VBL callback.
 *    - dispatch_semaphore for 3D frame pacing (no usleep/nanosleep).
 *
 *  Threading: VBL callbacks fire on the main RunLoop.  Tick and cadence
 *  counters are C11 _Atomic for read-mostly access from emul thread.
 */

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

#include "vbl_source.h"

#include <stdatomic.h>
#include <cstdio>
#include <dispatch/dispatch.h>

// ---------------------------------------------------------------------------
// Logging macros
// ---------------------------------------------------------------------------

#define VBL_LOG(fmt, ...) \
	do { printf("[gfxaccel-vbl] " fmt "\n", ##__VA_ARGS__); } while (0)

#define VBL_ERR(fmt, ...) \
	do { printf("[gfxaccel-vbl ERROR] " fmt "\n", ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------------------
// File-scope static state
// ---------------------------------------------------------------------------

static VBLSourceCallbackFn s_callback     = NULL;
static void               *s_callback_ctx = NULL;

/* Up to 4 secondary callbacks, invoked AFTER the
 * primary callback in every VBL tick path (CADisplayLink displayLinkFired:
 * AND the iOS 17+ metalDisplayLink:needsUpdate: delegate).
 *
 * Threading: No _Atomic is needed on the secondary-callback array.
 * Registration happens at DSpInit time on the emul thread BEFORE any VBL
 * tick fires; deregistration at DSpShutdown; no in-flight mutations. This
 * matches the existing s_callback non-atomic pattern. */
static VBLSourceCallbackFn s_secondary_cb[VBL_SECONDARY_CALLBACK_MAX]  = {NULL};
static void               *s_secondary_ctx[VBL_SECONDARY_CALLBACK_MAX] = {NULL};

static inline void DrainSecondaryCallbacks(void *drawable, double ts)
{
	for (int i = 0; i < VBL_SECONDARY_CALLBACK_MAX; i++) {
		if (s_secondary_cb[i] != NULL) {
			s_secondary_cb[i](s_secondary_ctx[i], drawable, ts);
		}
	}
}

// C11 _Atomic for read-mostly counters -- minimal threading exception;
// no mutex needed.  Written once per VBL callback on
// main thread, read from emul thread.
static _Atomic uint64_t    s_tick_count   = 0;
static _Atomic uint64_t    s_cadence_usec = 16667;  // default 60 Hz

static dispatch_semaphore_t s_pacing_semaphore = NULL;
static int                  s_initialized      = 0;

// iOS 17+ state -- stored as `id` to avoid compile-time type references
// on older deployment targets.
static id                   s_metal_display_link = nil;

// iOS 13.4-16 state
static id                   s_ca_display_link    = nil;

// ---------------------------------------------------------------------------
// iOS 17+ delegate: CAMetalDisplayLinkDelegate
// ---------------------------------------------------------------------------

API_AVAILABLE(ios(17))
@interface VBLMetalDisplayLinkDelegate : NSObject <CAMetalDisplayLinkDelegate>
@end

@implementation VBLMetalDisplayLinkDelegate

- (void)metalDisplayLink:(CAMetalDisplayLink *)link
             needsUpdate:(CAMetalDisplayLinkUpdate *)update
{
	// Increment tick count
	atomic_fetch_add_explicit(&s_tick_count, 1, memory_order_relaxed);

	// Update cadence from inter-callback delta (more accurate
	// than preferredFrameRateRange).
	static CFTimeInterval s_last_target_ts = 0;
	if (s_last_target_ts > 0 &&
	    update.targetPresentationTimestamp > s_last_target_ts) {
		uint64_t delta_usec = (uint64_t)(
			(update.targetPresentationTimestamp - s_last_target_ts) * 1e6);
		if (delta_usec > 0) {
			atomic_store_explicit(&s_cadence_usec, delta_usec,
			                     memory_order_relaxed);
		}
	}
	s_last_target_ts = update.targetPresentationTimestamp;

	// Signal 3D pacing semaphore
	vbl_source_signal_3d_pacing();

	// Fire user callback with drawable + timestamp
	if (s_callback) {
		s_callback(s_callback_ctx,
		           (__bridge void *)update.drawable,
		           update.targetPresentationTimestamp);
	}

	// Fan-out to registered secondary callbacks
	// (e.g., DSpVBLReleaseCallback for VBL-bounded release drain).
	DrainSecondaryCallbacks((__bridge void *)update.drawable,
	                         update.targetPresentationTimestamp);
}

@end

static VBLMetalDisplayLinkDelegate *s_delegate = nil;

// ---------------------------------------------------------------------------
// iOS 13.4-16 target: CADisplayLink callback
// ---------------------------------------------------------------------------

@interface VBLDisplayLinkTarget : NSObject
- (void)displayLinkFired:(CADisplayLink *)link;
@end

@implementation VBLDisplayLinkTarget

- (void)displayLinkFired:(CADisplayLink *)link
{
	// Increment tick count
	atomic_fetch_add_explicit(&s_tick_count, 1, memory_order_relaxed);

	// Update cadence from link.duration
	uint64_t dur_usec = (uint64_t)(link.duration * 1e6);
	if (dur_usec > 0) {
		atomic_store_explicit(&s_cadence_usec, dur_usec,
		                     memory_order_relaxed);
	}

	// Signal 3D pacing semaphore
	vbl_source_signal_3d_pacing();

	// Fire user callback (no drawable on legacy path)
	if (s_callback) {
		s_callback(s_callback_ctx, NULL, link.targetTimestamp);
	}

	// Fan-out to registered secondary callbacks
	// (e.g., DSpVBLReleaseCallback for VBL-bounded release drain).
	DrainSecondaryCallbacks(NULL, link.targetTimestamp);
}

@end

static VBLDisplayLinkTarget *s_link_target = nil;

// ---------------------------------------------------------------------------
// Public API: lifecycle
// ---------------------------------------------------------------------------

extern "C"
int32_t vbl_source_init(void *cametal_layer,
                        VBLSourceCallbackFn callback,
                        void *ctx)
{
	if (s_initialized) {
		VBL_ERR("vbl_source_init: already running");
		return kGfxAccelErrVBLAlreadyRunning;
	}

	s_callback     = callback;
	s_callback_ctx = ctx;

	// Create pacing semaphore
	s_pacing_semaphore = dispatch_semaphore_create(0);

	// CAMetalDisplayLink (iOS 17+) is disabled: it forbids
	// [layer nextDrawable] and requires all rendering to happen inside the
	// delegate callback. The emulator's threading model (PPC emul thread
	// presents, display link fires on main thread) makes this impractical
	// without a major architectural refactor, and ProMotion is already honored
	// via CADisplayLink's preferredFrameRateRange = (60,120) — there is no
	// pacing benefit to the revive. Using CADisplayLink for timing for ALL iOS
	// versions; nextDrawable for drawables. vbl_source_uses_metal_display_link()
	// returns 0 by design.
	{
		// --- CADisplayLink path (all iOS versions) ---
		if (cametal_layer == NULL) {
			VBL_LOG("vbl_source_init: nil layer (TESTING_BUILD or headless)");
			s_initialized = 1;
			return 0;
		}

		s_link_target = [[VBLDisplayLinkTarget alloc] init];
		CADisplayLink *link =
			[CADisplayLink displayLinkWithTarget:s_link_target
			                            selector:@selector(displayLinkFired:)];

		if (@available(iOS 15, *)) {
			link.preferredFrameRateRange =
				CAFrameRateRangeMake(60, 120, 0);
		} else {
			link.preferredFramesPerSecond = 60;
		}

		[link addToRunLoop:[NSRunLoop mainRunLoop]
		           forMode:NSDefaultRunLoopMode];

		s_ca_display_link = link;
		VBL_LOG("vbl_source_init: CADisplayLink created");
	}

	s_initialized = 1;
	VBL_LOG("vbl_source_init: ready");
	return 0;  // kGfxAccelNoErr
}

extern "C"
void vbl_source_shutdown(void)
{
	if (!s_initialized) {
		return;
	}

	// Invalidate display link
	if (@available(iOS 17, *)) {
		if (s_metal_display_link != nil) {
			CAMetalDisplayLink *link =
				(CAMetalDisplayLink *)s_metal_display_link;
			[link invalidate];
			s_metal_display_link = nil;
			s_delegate = nil;
		}
	}

	if (s_ca_display_link != nil) {
		CADisplayLink *link = (CADisplayLink *)s_ca_display_link;
		[link invalidate];
		s_ca_display_link = nil;
		s_link_target = nil;
	}

	s_callback     = NULL;
	s_callback_ctx = NULL;

	atomic_store_explicit(&s_tick_count, 0, memory_order_relaxed);
	atomic_store_explicit(&s_cadence_usec, 16667, memory_order_relaxed);

	s_pacing_semaphore = NULL;
	s_initialized      = 0;

	VBL_LOG("vbl_source_shutdown: done");
}

// ---------------------------------------------------------------------------
// Public API: queries
// ---------------------------------------------------------------------------

extern "C"
uint64_t vbl_source_get_cadence_usec(void)
{
	return atomic_load_explicit(&s_cadence_usec, memory_order_relaxed);
}

extern "C"
uint64_t vbl_source_get_tick_count(void)
{
	return atomic_load_explicit(&s_tick_count, memory_order_relaxed);
}

extern "C"
int vbl_source_uses_metal_display_link(void)
{
	if (@available(iOS 17, *)) {
		return (s_metal_display_link != nil) ? 1 : 0;
	}
	return 0;
}

extern "C"
void vbl_source_set_paused(int paused)
{
	if (@available(iOS 17, *)) {
		if (s_metal_display_link != nil) {
			CAMetalDisplayLink *link =
				(CAMetalDisplayLink *)s_metal_display_link;
			link.paused = (paused != 0);
		}
	}

	if (s_ca_display_link != nil) {
		CADisplayLink *link = (CADisplayLink *)s_ca_display_link;
		link.paused = (paused != 0);
	}
}

// ---------------------------------------------------------------------------
// Public API: 3D pacing semaphore
// ---------------------------------------------------------------------------

extern "C"
int32_t vbl_source_sync_3d_pacing(void)
{
	if (!s_initialized || s_pacing_semaphore == NULL) {
		return kGfxAccelErrVBLNotInitialized;
	}

	// 33 ms timeout (~2 frames at 60 Hz)
	long result = dispatch_semaphore_wait(
		s_pacing_semaphore,
		dispatch_time(DISPATCH_TIME_NOW, 33333333));

	if (result != 0) {
		return kGfxAccelErrVBLTimeout;
	}
	return 0;  // kGfxAccelNoErr
}

extern "C"
void vbl_source_signal_3d_pacing(void)
{
	if (s_pacing_semaphore != NULL) {
		dispatch_semaphore_signal(s_pacing_semaphore);
	}
}

// ---------------------------------------------------------------------------
// Secondary-callback fan-out registration API
// ---------------------------------------------------------------------------

extern "C"
int32_t vbl_source_register_secondary_callback(VBLSourceCallbackFn cb,
                                                void *ctx)
{
	if (cb == NULL) return kGfxAccelErrVBLAlreadyRunning;  /* reject NULL cb */
	for (int i = 0; i < VBL_SECONDARY_CALLBACK_MAX; i++) {
		if (s_secondary_cb[i] == NULL) {
			s_secondary_cb[i]  = cb;
			s_secondary_ctx[i] = ctx;
			return 0;
		}
	}
	return kGfxAccelErrVBLAlreadyRunning;  /* table full */
}

extern "C"
void vbl_source_unregister_secondary_callback(VBLSourceCallbackFn cb)
{
	for (int i = 0; i < VBL_SECONDARY_CALLBACK_MAX; i++) {
		if (s_secondary_cb[i] == cb) {
			s_secondary_cb[i]  = NULL;
			s_secondary_ctx[i] = NULL;
			return;
		}
	}
}

// ---------------------------------------------------------------------------
// TESTING_BUILD hooks
// ---------------------------------------------------------------------------

#ifdef TESTING_BUILD

extern "C"
uint32_t vbl_source_testing_is_initialized(void)
{
	return (uint32_t)s_initialized;
}

extern "C"
uint64_t vbl_source_testing_get_tick_count(void)
{
	return vbl_source_get_tick_count();
}

extern "C"
void vbl_source_testing_reset(void)
{
	vbl_source_shutdown();

	// Belt-and-suspenders: explicitly zero everything
	s_callback         = NULL;
	s_callback_ctx     = NULL;
	s_pacing_semaphore = NULL;
	s_metal_display_link = nil;
	s_ca_display_link    = nil;
	s_delegate           = nil;
	s_link_target        = nil;
	s_initialized        = 0;

	// Reset the secondary-callback table too.
	for (int i = 0; i < VBL_SECONDARY_CALLBACK_MAX; i++) {
		s_secondary_cb[i]  = NULL;
		s_secondary_ctx[i] = NULL;
	}

	atomic_store_explicit(&s_tick_count, 0, memory_order_relaxed);
	atomic_store_explicit(&s_cadence_usec, 16667, memory_order_relaxed);
}

extern "C"
void vbl_source_testing_simulate_vbl_tick(void)
{
	// Manually fire the callback chain without a real display link.
	// Increment tick count
	atomic_fetch_add_explicit(&s_tick_count, 1, memory_order_relaxed);

	// Signal pacing semaphore
	vbl_source_signal_3d_pacing();

	// Fire user callback (NULL drawable, 0 timestamp for test)
	if (s_callback) {
		s_callback(s_callback_ctx, NULL, 0.0);
	}

	// Fan-out to secondary callbacks in the test
	// path too, so DSpContextTests can drain the release FIFO via
	// vbl_source_testing_simulate_vbl_tick() between Reserve/Release
	// cycles.
	DrainSecondaryCallbacks(NULL, 0.0);
}

#endif /* TESTING_BUILD */
