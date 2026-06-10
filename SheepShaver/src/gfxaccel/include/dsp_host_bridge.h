/*
 *  dsp_host_bridge.h - DSp <-> iOS host C-callable bridge.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Pure-C header. No Metal / Objective-C / Swift types — consumable from
 *  .cpp / .mm / Swift bridging header alike. Isolates the DSp engine's
 *  need to toggle UIApplication.shared.isIdleTimerDisabled behind a
 *  single C-linkage entry point; the Swift-side observer
 *  (DSpIdleTimerService.swift) reads the flag via
 *  DSpHostBridge_GetActiveFullscreen on foreground re-apply.
 *
 *  The fullscreen-only idle-timer suppression deliberately diverges from
 *  the RAVE/NQD engine-blind compositor boundary.
 */

#ifndef DSP_HOST_BRIDGE_H
#define DSP_HOST_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>

/*
 *  Mark the DSp engine as holding an Active fullscreen context (true)
 *  or not (false). Called from DSpContext_SetStateHandler
 *  on Active/Paused/Inactive transitions — the handler computes
 *  "any DSp context Active AND fullscreen-mode" and calls this setter
 *  on the transition edge (fullscreen-only idle-timer
 *  suppression per DSp 1.7 spec p.88).
 *
 *  Writes a file-static flag in dsp_host_bridge.mm AND posts
 *  Notification.Name("DSpHostBridge.activeFullscreenChanged") so
 *  DSpIdleTimerService can toggle UIApplication.shared.isIdleTimerDisabled
 *  on the main thread (iOS requires UIApplication on main).
 *
 *  Threading: single-writer emul-thread (DSpContext_SetStateHandler
 *  always runs on emul thread) + single-reader
 *  main-thread (DSpIdleTimerService reads on foreground re-apply).
 *  The flag is stored as `_Atomic bool` with relaxed memory ordering —
 *  matches the single-word read-mostly cross-thread flag pattern
 *  (minimum primitive sufficient;
 *  no happens-before requirements beyond monotonic writes).
 */
void DSpHostBridge_SetActiveFullscreen(bool active);

/*
 *  Read the current active-fullscreen flag. Called by
 *  DSpIdleTimerService on foreground re-apply (UIApplication
 *  .willEnterForegroundNotification) to decide whether to re-assert
 *  isIdleTimerDisabled after the OS restored it on background entry.
 *
 *  Returns the value of the file-static atomic flag.
 */
bool DSpHostBridge_GetActiveFullscreen(void);

/* ============================================================
 * DSp event integration C bridge.
 *
 * Four C-linkage entries that DSpEventService.swift calls to inject iOS
 * bg/fg lifecycle signals + iOS input events into per-context DSp event
 * queues: bg/fg lifecycle and per-context SPSC event ring write.
 *
 * All four entries are pure-C signatures (no Objective-C / Metal
 * types); consumable from .cpp / .mm / Swift bridging header alike.
 * Threading: all four are called on the main thread (Swift observers
 * run on main queue). Internal walks of dsp_context_table happen on
 * the calling thread (main); the SPSC ring atomic head/tail handle
 * cross-thread visibility for the ring reader at dequeue time.
 *
 * NOTE: the emul-thread dequeue export
 * DSpContext_ProcessEventHandler was retired (sub-op 600
 * removed; replaced by the canonical DSpProcessEvent sub-op 750, which
 * CONSUMES app-supplied events — the opposite direction and does NOT
 * read this ring). The ring currently has NO production consumer; its
 * only surviving reader is the TESTING_BUILD helper
 * DSpTesting_DequeueContextEvent. The producer side below is kept (the
 * SPSC input-fanout ring is retained).
 * ============================================================ */

/*
 *  Background lifecycle hook. Called from BackgroundLifecycleObserver via
 *  DSpEventService.swift when the iOS app
 *  transitions to background. Walks dsp_context_table; for each Active
 *  context: enqueues a context-loss event (kDSpContextReason_Lost as the
 *  message field of an osEvt EventRecord per DSp 1.7 PDF p.~92), enqueues
 *  an osEvt(suspendResumeMessage cleared = suspend), calls
 *  DSpContext_SetState(Paused), sets paused_by_background = 1.
 *
 *  Threading: called on main thread (BackgroundLifecycleObserver fires on
 *  the main queue via UIApplication.didEnterBackgroundNotification observer).
 */
void DSpHostBridge_OnBackground(void);

/*
 *  Foreground lifecycle hook. Called from BackgroundLifecycleObserver via
 *  DSpEventService.swift when the iOS app
 *  transitions to foreground. Walks dsp_context_table; for each Paused
 *  context with paused_by_background == 1: calls DSpContext_SetState(Active),
 *  enqueues an osEvt(suspendResumeMessage set = resume), clears
 *  paused_by_background. The flag distinguishes user-Paused contexts (which
 *  stay Paused after fg) from bg-induced-Paused contexts (which auto-resume).
 *
 *  Threading: called on main thread.
 */
void DSpHostBridge_OnForeground(void);

/*
 *  Push a single DSp event onto a specific context's SPSC ring. Called from
 *  DSpEventService.swift when the iOS
 *  input stack delivers a keyboard / gamepad / mouse event that DSp apps
 *  should observe via DSpProcessEvent.
 *
 *  Args (all single-word, sized to fit standard C calling convention):
 *    ctx_idx  - dsp_context_table index (0..DSP_MAX_CONTEXTS-1) of the
 *               target context. Caller resolves which contexts are Active.
 *    what     - DSp event kind (kDSpEvent_MouseDown, kDSpEvent_KeyDown, etc.)
 *    message  - 4-byte event-kind-specific payload (key code, mouse button, etc.)
 *    when     - Tick count when event fired (TickCount() in DSp 1.7 spec)
 *    where_v  - Vertical position (pixels; mouse events; 0 for non-mouse)
 *    where_h  - Horizontal position (pixels; mouse events; 0 for non-mouse)
 *    modifiers - Event modifier mask (shift / cmd / opt / ctrl bits)
 *
 *  Threading: writer = main thread (Swift observer runs on main queue).
 *  Reader = the ring's dequeue side. The production emul-thread dequeue
 *  export (DSpContext_ProcessEventHandler) was retired; the ring currently
 *  has NO production consumer and is drained
 *  only by the TESTING_BUILD helper DSpTesting_DequeueContextEvent.
 *  _Atomic uint32_t events_head/tail with relaxed-acquire/release
 *  ordering (SPSC).
 *  Overflow: drop oldest event with DSP_LOG warning.
 */
void DSpHostBridge_EnqueueEvent(uint32_t ctx_idx, uint16_t what, uint32_t message,
                                 uint32_t when, int16_t where_v, int16_t where_h,
                                 uint16_t modifiers);

/*
 *  Push a single DSp event onto every Active context's SPSC ring. Walks
 *  dsp_context_table; for each ctx with state == kDSpContextState_Active,
 *  calls DSpHostBridge_EnqueueEvent(idx, what, ...) with the same args.
 *  Convenience wrapper used by DSpEventService.swift's input observers —
 *  most input events fan out to all Active contexts rather
 *  than targeting a specific ctx.
 */
void DSpHostBridge_EnqueueEventToActiveContexts(uint16_t what, uint32_t message,
                                                  uint32_t when, int16_t where_v,
                                                  int16_t where_h, uint16_t modifiers);

#ifdef __cplusplus
}
#endif

#endif /* DSP_HOST_BRIDGE_H */
