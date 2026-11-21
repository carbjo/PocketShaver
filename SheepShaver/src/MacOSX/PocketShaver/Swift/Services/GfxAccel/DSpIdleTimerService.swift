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
 *  Disables the idle timer while any DSp context is active (treated as
 *  fullscreen, since iOS apps always are). Clears it on background and
 *  re-applies it on foreground. Catalyst and external displays aren't
 *  handled separately.
 */

import UIKit

@objc public final class DSpIdleTimerService: NSObject {

	@objc public static let shared = DSpIdleTimerService()

	/// Posted by DSpHostBridge_SetActiveFullscreen on the emul thread.
	public static let activeFullscreenChangedName =
		Notification.Name("DSpHostBridge.activeFullscreenChanged")

	private var backgroundToken: NSObjectProtocol?
	private var foregroundToken: NSObjectProtocol?
	private var activeFullscreenToken: NSObjectProtocol?

	@objc public func install() {
		guard backgroundToken == nil else { return }

		/* iOS also clears this on background; the explicit write keeps
		 * the state in step with other background-entry cleanup. */
		backgroundToken = NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			_ = self  // prevent unused capture warning
			UIApplication.shared.isIdleTimerDisabled = false
		}

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

		/* Posted when the "any active DSp context" state changes. */
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
