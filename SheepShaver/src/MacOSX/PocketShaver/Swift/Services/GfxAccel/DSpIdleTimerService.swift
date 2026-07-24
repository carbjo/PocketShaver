/*
 *  DSpIdleTimerService.swift - idle-timer / screensaver
 *                               suppression observer.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Observes three NotificationCenter events on the main queue and toggles
 *  UIApplication.shared.isIdleTimerDisabled accordingly:
 *
 *    1. UIApplication.didEnterBackgroundNotification → clear isIdleTimerDisabled
 *       (background restores idle-timer immediately).
 *
 *    2. UIApplication.willEnterForegroundNotification → if the DSp engine's
 *       s_dsp_active_fullscreen flag is true (read via
 *       DSpHostBridge_GetActiveFullscreen), re-apply isIdleTimerDisabled = true
 *       (foreground re-applies suppression if still Active).
 *
 *    3. Custom notification "DSpHostBridge.activeFullscreenChanged" posted by
 *       DSpHostBridge_SetActiveFullscreen (from DSpContext_SetStateHandler on
 *       the emul thread) → switch to main queue + toggle isIdleTimerDisabled
 *       per the NEW flag value (Active-fullscreen transitions in
 *       the foregrounded state).
 *
 *  Follows the BackgroundLifecycleObserver.swift singleton pattern
 *  EXACTLY: @objc public final class with static let shared singleton;
 *  install() / uninstall() lifecycle; NotificationCenter observer with
 *  queue: .main; C function call in the closure body; deinit cleanup.
 *
 *  iOS UIKit apps are always fullscreen; ANY Active DSp context
 *  ⇒ fullscreen per the engine. This implements the simpler gate;
 *  Catalyst / external-display multi-screen edge cases are out of M2 scope.
 */

import UIKit

@objc public final class DSpIdleTimerService: NSObject {

	@objc public static let shared = DSpIdleTimerService()

	/// Custom notification name posted by DSpHostBridge_SetActiveFullscreen
	/// from the emul thread. DSpIdleTimerService's observer hops to main
	/// queue before toggling UIApplication.shared.isIdleTimerDisabled.
	public static let activeFullscreenChangedName =
		Notification.Name("DSpHostBridge.activeFullscreenChanged")

	private var backgroundToken: NSObjectProtocol?
	private var foregroundToken: NSObjectProtocol?
	private var activeFullscreenToken: NSObjectProtocol?

	@objc public func install() {
		guard backgroundToken == nil else { return }

		/* Background clears idle-timer override. iOS clears
		 * it automatically too, but the explicit main-thread write makes
		 * the state transition atomic with other background-entry cleanup
		 * and provides an observable seam for tests. */
		backgroundToken = NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			_ = self  // prevent unused capture warning
			UIApplication.shared.isIdleTimerDisabled = false
		}

		/* Foreground re-applies suppression iff the DSp
		 * engine's active-fullscreen flag is still set. Read the C-side
		 * flag via the bridge (DSpHostBridge_GetActiveFullscreen). */
		foregroundToken = NotificationCenter.default.addObserver(
			forName: UIApplication.willEnterForegroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			_ = self  // prevent unused capture warning
			if DSpHostBridge_GetActiveFullscreen() {
				UIApplication.shared.isIdleTimerDisabled = true
			} else {
				UIApplication.shared.isIdleTimerDisabled = false
			}
		}

		/* State-transition notification — fires from
		 * DSpHostBridge_SetActiveFullscreen on the emul thread when
		 * DSpContext_SetStateHandler completes a transition that changes
		 * the aggregate "any Active DSp context?" predicate. The observer
		 * hops to main queue (addObserver queue: .main) before writing
		 * UIApplication.shared.isIdleTimerDisabled. */
		activeFullscreenToken = NotificationCenter.default.addObserver(
			forName: DSpIdleTimerService.activeFullscreenChangedName,
			object: nil,
			queue: .main
		) { [weak self] _ in
			_ = self  // prevent unused capture warning
			UIApplication.shared.isIdleTimerDisabled =
				DSpHostBridge_GetActiveFullscreen()
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
		if let t = activeFullscreenToken {
			NotificationCenter.default.removeObserver(t)
			activeFullscreenToken = nil
		}
	}

	deinit {
		uninstall()
	}
}
