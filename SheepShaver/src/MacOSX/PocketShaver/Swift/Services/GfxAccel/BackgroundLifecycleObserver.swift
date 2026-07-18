/*
 *  BackgroundLifecycleObserver.swift - background/foreground observer.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Observes UIApplication.didEnterBackgroundNotification and
 *  UIApplication.willEnterForegroundNotification on the main thread,
 *  calling the C entry points gfxaccel_handle_background_enter() and
 *  gfxaccel_handle_foreground_enter() respectively.
 *
 *  Follows the MemoryWarningObserver singleton pattern:
 *    - @objc public final class with static let shared singleton
 *    - install() / uninstall() lifecycle
 *    - NotificationCenter observer with queue: .main
 *    - C function call in the closure body
 *    - deinit { uninstall() } cleanup
 *
 *  Swift singleton calls C shims from main thread for background and
 *  foreground; the C shims return within a 50 ms budget on main thread.
 */

import UIKit

@objc public final class GfxAccelBackgroundLifecycleObserver: NSObject {

	@objc public static let shared = GfxAccelBackgroundLifecycleObserver()

	private var backgroundToken: NSObjectProtocol?
	private var foregroundToken: NSObjectProtocol?

	@objc public func install() {
		guard backgroundToken == nil else { return }
		backgroundToken = NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			_ = self  // prevent unused capture warning
			gfxaccel_handle_background_enter()
		}
		foregroundToken = NotificationCenter.default.addObserver(
			forName: UIApplication.willEnterForegroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			_ = self  // prevent unused capture warning
			gfxaccel_handle_foreground_enter()
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
	}

	deinit {
		uninstall()
	}
}
