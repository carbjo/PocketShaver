/*
 *  dsp_host_bridge.mm - DSp <-> iOS host bridge implementation.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  The setter performs the full NotificationCenter wiring.
 *  DSpIdleTimerService.swift observes the posted notification on the
 *  main queue and toggles UIApplication.shared.isIdleTimerDisabled.
 *
 *  Threading:
 *    - Setter called from DSpContext_SetStateHandler on the emul thread.
 *    - NotificationCenter.postNotification is thread-safe by Apple's
 *      documented contract (internal lock; safe to call from any thread).
 *    - Observer closure runs on main queue (queue: .main in addObserver
 *      call) — UIApplication.shared.isIdleTimerDisabled write happens on
 *      main thread per UIKit's main-thread contract.
 *    - Getter: single-word _Atomic bool read (memory_order_relaxed);
 *      callable from any thread.
 *
 *  Threading rationale for `_Atomic bool`:
 *    - Single writer: DSpContext_SetStateHandler on emul thread
 *      (NATIVE_DSP_DISPATCH serialized).
 *    - Readers: DSpIdleTimerService on main thread via the
 *      willEnterForegroundNotification observer; test code
 *      via DSpHostBridge_GetActiveFullscreen.
 *    - Cross-thread single-word bool — `_Atomic bool` with
 *      memory_order_relaxed is the minimum sanctioned primitive per the
 *      read-mostly precedent. The threading-grep CI gate
 *      (MTLFence|MTLSharedEvent|std::mutex|@synchronized) does not
 *      match _Atomic by design.
 *
 *  The `_Atomic bool s_dsp_active_fullscreen` flag is kept
 *  because DSpIdleTimerService re-reads it on willEnterForegroundNotification
 *  — the notification post path alone would miss the case where DSp
 *  transitioned to Active-fullscreen WHILE the app was backgrounded (no
 *  observer firing during that window). The flag provides the source of
 *  truth for foreground re-apply decisions.
 */

#import <Foundation/Foundation.h>

#import "dsp_host_bridge.h"
#import "dsp_engine.h"    /* DSP_LOG;
                           * DSpContextState_* enum + DSP_MAX_CONTEXTS
                           * (via dsp_draw_context.h below). */
#import "dsp_draw_context.h"  /* DSP_MAX_CONTEXTS +
                               * DSpGetContext + DSpContext_SetStateHandler
                               * prototypes for the bg/fg walk bodies. */
#include "dsp_context_private.h"  /* DSpContextPrivate full
                                   * struct (events_queue / events_head /
                                   * events_tail / paused_by_background
                                   * field access by OnBackground/OnForeground). */
#include "dsp_event_record.h"     /* kDSpEvent_OSEvt +
                                   * kDSpOSEvt_SuspendResumeMessage +
                                   * kDSpOSEvtMsg_ResumeFlag +
                                   * kDSpContextReason_Lost constants. */

#include <stdatomic.h>

/* dsp_context_table is file-static to dsp_draw_context.mm;
 * DSpGetContext(handle) is the cross-TU accessor (handle = index + 1;
 * returns nullptr for empty slots). OnBackground/OnForeground walk
 * indices 0..DSP_MAX_CONTEXTS-1 via DSpGetContext(i+1). The
 * contract allows main-thread reads alongside emul-thread
 * Reserve/Release writes because Reserve/Release cannot be concurrent
 * with a main-thread iOS bg/fg notification dispatch window. */

/* Module-scope storage — single writer emul-thread; readers: main-thread
 * Swift observer on foreground re-apply, plus test code via
 * the getter. Initial state = false (no DSp context is Active at DSp boot
 * time; DSpContext_Reserve's default state is Inactive). */
static _Atomic bool s_dsp_active_fullscreen = false;

extern "C" void DSpHostBridge_SetActiveFullscreen(bool active)
{
	/* Write the flag first so readers (including the observer
	 * closure that the notification post will trigger) see the new value
	 * atomically. _Atomic bool with memory_order_relaxed is the minimum
	 * sanctioned primitive — the Swift observer's queue: .main hop
	 * provides the happens-before for the subsequent UIApplication write
	 * (main-runloop iteration boundary is a synchronization point). */
	atomic_store_explicit(&s_dsp_active_fullscreen, active,
	                      memory_order_relaxed);

	/* Post notification to DSpIdleTimerService. Uses the
	 * same name string the Swift observer registered for:
	 * Notification.Name("DSpHostBridge.activeFullscreenChanged"). The
	 * Swift observer's queue: .main hops delivery to main thread before
	 * writing UIApplication.shared.isIdleTimerDisabled.
	 *
	 * @autoreleasepool guards against any autoreleased objects the post
	 * might create internally (defensive — the NATIVE_DSP_DISPATCH emul
	 * thread does not have an enclosing autorelease pool). Negligible
	 * cost on a transition-edge-only call path. */
	@autoreleasepool {
		[[NSNotificationCenter defaultCenter]
		    postNotificationName:@"DSpHostBridge.activeFullscreenChanged"
		                  object:nil];
	}
}

extern "C" bool DSpHostBridge_GetActiveFullscreen(void)
{
	return atomic_load_explicit(&s_dsp_active_fullscreen,
	                            memory_order_relaxed);
}

/*
 * ============================================================
 * File-static SPSC-ring writer helpers.
 *
 * The SPSC-ring write logic + overflow policy are centralized in
 * dsp_enqueue_into_ring. DSpHostBridge_EnqueueEvent and
 * DSpHostBridge_EnqueueEventToActiveContexts both call it, so future
 * changes happen in one place.
 *
 * SPSC writer-side contract: plain slot-data
 * store + memory_order_release atomic store to events_head fences the
 * slot write so the ring reader sees a coherent 16-byte EventRecord. The
 * emul-thread dequeue export (DSpContext_ProcessEventHandler) that was
 * the original reader has been RETIRED; the ring now
 * has no production consumer and is drained only by the TESTING_BUILD
 * helper DSpTesting_DequeueContextEvent.
 *
 * Overflow policy: if head - tail >= 64, drop OLDEST by
 * advancing events_tail before writing the new record. DSP_LOG warning
 * on overflow. Matches DSp 1.7 spec — caller is responsible for pumping
 * ProcessEvent fast enough.
 * ============================================================ */

/*
 *  Extracted ring-write helper.
 *
 *  Shared by EnqueueEvent, EnqueueEventToActiveContexts, and the
 *  TESTING_BUILD enqueue helper. Centralizes the SPSC-ring write logic +
 *  overflow policy so future changes happen in one place.
 *
 *  Threading: called on main thread (all live callers are
 *  main-thread input/test paths). memory_order_release on events_head
 *  advance fences the slot payload for the ring reader. The original
 *  emul-thread reader DSpContext_ProcessEventHandler has been RETIRED;
 *  the ring's only surviving reader is the
 *  TESTING_BUILD helper DSpTesting_DequeueContextEvent (no production
 *  consumer).
 *
 *  Overflow: drop OLDEST by advancing events_tail before writing the
 *  new slot. DSP_LOG warning on overflow.
 */
/* Declared `extern "C"` so DSpTesting_EnqueueEventToCtx
 * (in dsp_draw_context.mm, a different TU) can dispatch through the same
 * SPSC-ring write helper used by the production enqueue path. No
 * prototype added to any public header — the symbol is linker-visible
 * cross-TU but invisible to external consumers. */
extern "C" void dsp_enqueue_into_ring(DSpContextPrivate *ctx,
                                   uint16_t what, uint32_t message,
                                   uint32_t when, int16_t where_v,
                                   int16_t where_h, uint16_t modifiers)
{
	if (ctx == nullptr) return;

	uint32_t head = atomic_load_explicit(&ctx->events_head, memory_order_relaxed);
	uint32_t tail = atomic_load_explicit(&ctx->events_tail, memory_order_relaxed);

	if (head - tail >= 64u) {
		atomic_store_explicit(&ctx->events_tail, tail + 1u,
		                      memory_order_relaxed);
		DSP_LOG("DSpHostBridge: events_queue overflow on ctx handle=%u "
		        "— dropped oldest",
		        ctx->handle);
	}

	DSpEventRecord *slot = &ctx->events_queue[head % 64u];
	slot->what       = what;
	slot->message    = message;
	slot->when       = when;
	slot->where_v    = where_v;
	slot->where_h    = where_h;
	slot->modifiers  = modifiers;

	atomic_store_explicit(&ctx->events_head, head + 1u,
	                      memory_order_release);
}

extern "C" void DSpHostBridge_EnqueueEvent(uint32_t ctx_idx, uint16_t what,
                                            uint32_t message, uint32_t when,
                                            int16_t where_v, int16_t where_h,
                                            uint16_t modifiers)
{
	/*
	 *  Per-context event push.
	 *
	 *  Called from DSpEventService.swift's Combine subscription on the
	 *  main thread (InputInteractionModel's dspInputEventSubject publishes
	 *  on @MainActor). Writes a DSpEventRecord to ctx[ctx_idx]'s SPSC
	 *  events_queue via dsp_enqueue_into_ring.
	 *
	 *  Validation: ctx_idx < DSP_MAX_CONTEXTS. Out-of-range logs a
	 *  warning + early-returns. nullptr table entry also early-returns
	 *  (benign — caller might race with a Release path).
	 *
	 *  dsp_context_table is file-static to dsp_draw_context.mm; use
	 *  DSpGetContext(handle = index + 1) to accessor-read. The
	 *  contract allows main-thread reads alongside emul-thread
	 *  Reserve/Release writes because Reserve/Release cannot be
	 *  concurrent with a main-thread input-event dispatch window.
	 */
	if (ctx_idx >= DSP_MAX_CONTEXTS) {
		DSP_LOG("DSpHostBridge_EnqueueEvent: ctx_idx=%u out of range (max=%u)",
		        ctx_idx, (unsigned)DSP_MAX_CONTEXTS);
		return;
	}
	DSpContextPrivate *ctx = DSpGetContext(ctx_idx + 1u);
	if (ctx == nullptr) {
		/* No context at that index — silent. Swift caller walks the
		 * table itself (via EnqueueEventToActiveContexts) so this case
		 * is unreachable in practice; defensive. */
		return;
	}
	dsp_enqueue_into_ring(ctx, what, message, when, where_v, where_h, modifiers);
}

extern "C" void DSpHostBridge_EnqueueEventToActiveContexts(uint16_t what,
                                                             uint32_t message,
                                                             uint32_t when,
                                                             int16_t where_v,
                                                             int16_t where_h,
                                                             uint16_t modifiers)
{
	/*
	 *  Multi-context event
	 *  fan-out. Walks dsp_context_table; for each ctx with state ==
	 *  Active, pushes the same event onto ctx's SPSC events_queue.
	 *
	 *  DSp events fan out to all Active contexts — most
	 *  input events target "whichever context is currently visible",
	 *  and DSp 1.7 semantics route through ProcessEvent per-context
	 *  (each context polls its own queue). Multiple Active contexts is
	 *  uncommon but supported.
	 *
	 *  Multi-engine isolation: this walk ONLY touches
	 *  dsp_context_table. RAVE / NQD / GL contexts unaffected — their
	 *  event handling is owned by the gamepad/keyboard/mouse path
	 *  (InputInteractionModel → objc_ADB*) which this path does NOT
	 *  modify.
	 *
	 *  Threading: called on main thread (DSpEventService subscription
	 *  on @MainActor InputInteractionModel.dspInputEventSubject). Walk
	 *  + per-ctx dsp_enqueue_into_ring SPSC writes use
	 *  memory_order_release on events_head to fence the slot payload
	 *  for the ring reader. The emul-thread reader
	 *  DSpContext_ProcessEventHandler has been RETIRED;
	 *  the ring now has no production consumer (drained only by the
	 *  TESTING_BUILD helper DSpTesting_DequeueContextEvent).
	 */
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = DSpGetContext(i + 1u);
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
		dsp_enqueue_into_ring(ctx, what, message, when, where_v, where_h, modifiers);
	}
}
