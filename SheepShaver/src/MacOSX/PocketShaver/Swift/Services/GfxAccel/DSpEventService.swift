/*
 *  DSpEventService.swift - iOS bg/fg observer half.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Observes UIApplication.didEnterBackground / willEnterForeground on
 *  the main queue and calls DSpHostBridge_OnBackground / OnForeground
 *  (C-bridge entries) which walk dsp_context_table,
 *  enqueue osEvts + context-loss events, call DSpContext_SetStateHandler
 *  Active<->Paused, and manage the paused_by_background flag.
 *
 *  This class also handles the kbd/gamepad/mouse input fan-out half —
 *  additional observer tokens + the InputInteractionModel
 *  input-event-subject subscription.
 *
 *  Follows the DSpIdleTimerService.swift singleton
 *  pattern EXACTLY: @objc public final class with static shared;
 *  install() / uninstall() lifecycle; NotificationCenter queue: .main
 *  observers; C function calls in closure bodies; deinit cleanup.
 *
 *  paused_by_background distinguishes user-Paused (stays Paused
 *  on fg) from bg-induced-Paused (auto-resumes on fg). The flag
 *  management happens inside DSpHostBridge_OnBackground/OnForeground —
 *  Swift observer is a thin call-through.
 */

import UIKit
import Combine

@objc public final class DSpEventService: NSObject {

	@objc public static let shared = DSpEventService()

	/* Observer tokens (bg/fg half). */
	private var backgroundToken: NSObjectProtocol?
	private var foregroundToken: NSObjectProtocol?

	/* Input-event Combine subscription.
	 * Attached in install() to InputInteractionModel.shared.dspInputEventSubject;
	 * cancelled + nilified in uninstall(). @MainActor subject publishes on
	 * main thread; .sink runs synchronously on publish thread (no
	 * .receive(on:) operator); forwardInputEventToDSp marshals to the
	 * C bridge on main thread. */
	private var inputEventSubscription: AnyCancellable?

	@objc public func install() {
		guard backgroundToken == nil else { return }

		/* Background enqueues context-loss +
		 * suspend osEvt + SetState(Paused). The
		 * observer's queue: .main hops delivery to main thread before
		 * calling DSpHostBridge_OnBackground, matching the threading
		 * contract documented in dsp_host_bridge.mm OnBackground body. */
		backgroundToken = NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			_ = self  // prevent unused capture warning
			DSpHostBridge_OnBackground()
		}

		/* Foreground enqueues resume osEvt + SetState(Active)
		 * for bg-induced-Paused contexts; user-Paused skipped. */
		foregroundToken = NotificationCenter.default.addObserver(
			forName: UIApplication.willEnterForegroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			_ = self  // prevent unused capture warning
			DSpHostBridge_OnForeground()
		}

		/*
		 *  Input-event fan-out.
		 *
		 *  Subscribes to InputInteractionModel.shared.dspInputEventSubject
		 *  (main-thread publisher because InputInteractionModel is
		 *  @MainActor). Combine .sink runs synchronously on the thread the
		 *  subject publishes from — which is main for our use case.
		 *  forwardInputEventToDSp translates the Swift value type to the
		 *  7-arg C call DSpHostBridge_EnqueueEventToActiveContexts.
		 *
		 *  Observer-only: InputInteractionModel.handle()
		 *  methods are NOT modified except for the .send() call AFTER the
		 *  existing objc_ADB* call. Existing gamepad/keyboard/
		 *  mouse tests continue to exercise the ADB path identically.
		 *
		 *  Retain-cycle safety: [weak self] capture on the .sink closure
		 *  + AnyCancellable property lifecycle prevents leaks. uninstall()
		 *  calls .cancel() + nilifies; deinit calls uninstall.
		 */
		inputEventSubscription = InputInteractionModel.shared.dspInputEventSubject
			.sink { [weak self] event in
				_ = self  // prevent unused capture warning
				Self.forwardInputEventToDSp(event)
			}
	}

	@objc public func uninstall() {
		if let t = backgroundToken {
			NotificationCenter.default.removeObserver(t)
			backgroundToken = nil
		}
		if let t = foregroundToken {
			NotificationCenter.default.removeObserver(t)
			foregroundToken = nil
		}

		/* Cancel the Combine input-event subscription. */
		inputEventSubscription?.cancel()
		inputEventSubscription = nil
	}

	deinit {
		uninstall()
	}

	/*
	 *  Swift → C translator.
	 *
	 *  Maps DSpInputEvent.kind to the DSp 1.7 EventRecord.what constant
	 *  (kDSpEvent_KeyDown = 3, kDSpEvent_KeyUp = 4, kDSpEvent_MouseDown = 1,
	 *  kDSpEvent_MouseUp = 2 per dsp_event_record.h).
	 *
	 *  Forwards to DSpHostBridge_EnqueueEventToActiveContexts which walks
	 *  dsp_context_table and pushes the event onto every Active DSp
	 *  context's SPSC events_queue.
	 *
	 *  message field: low 16 bits = keyCode (for key events; SDLKey.enValue
	 *  is the classic Mac virtual key code per SDLKey.swift) or buttonIndex
	 *  (for mouse events; 1-based Mac convention). DSp 1.7 spec documents
	 *  low-byte-charcode / high-byte-virtualkey distinction for key
	 *  events; we use keyCode for both halves because the
	 *  PocketShaver mapping already produces virtual key codes.
	 *
	 *  where_v / where_h: 0 — mouse-click position is not
	 *  tracked by InputInteractionModel.mouseClick.
	 *
	 *  Threading: called from the .sink closure on main thread (Combine
	 *  default for @MainActor-published subjects). DSpHostBridge_EnqueueEventToActiveContexts
	 *  walks the table on main thread; per-context SPSC-ring writes fence
	 *  via memory_order_release on events_head for the emul-thread reader.
	 */
	private static func forwardInputEventToDSp(_ event: DSpInputEvent) {
		let what: UInt16
		let message: UInt32

		switch event.kind {
		case .keyDown:
			what = UInt16(kDSpEvent_KeyDown)    // 3
			message = UInt32(event.keyCode & 0xFFFF)
		case .keyUp:
			what = UInt16(kDSpEvent_KeyUp)      // 4
			message = UInt32(event.keyCode & 0xFFFF)
		case .mouseDown:
			what = UInt16(kDSpEvent_MouseDown)  // 1
			message = UInt32(event.buttonIndex & 0xFFFF)
		case .mouseUp:
			what = UInt16(kDSpEvent_MouseUp)    // 2
			message = UInt32(event.buttonIndex & 0xFFFF)
		}

		DSpHostBridge_EnqueueEventToActiveContexts(
			what,
			message,
			event.timestamp,     // when
			0,                   // where_v (mouse-position not tracked)
			0,                   // where_h
			event.modifiers      // modifier mask
		)
	}
}
