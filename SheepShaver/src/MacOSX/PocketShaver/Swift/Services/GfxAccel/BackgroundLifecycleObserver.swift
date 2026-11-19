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
 *  Forwards background/foreground transitions to
 *  gfxaccel_handle_background_enter() / gfxaccel_handle_foreground_enter()
 *  on the main thread. The shims must return within 50 ms.
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
