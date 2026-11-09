/*
 *  MemoryWarningObserver.swift - memory-warning observer.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Forwards memory warnings to gfxaccel_handle_memory_warning(), which only
 *  flags a pending eviction; the next compositor SubmitFrame performs it.
 */

import UIKit

@objc public final class GfxAccelMemoryWarningObserver: NSObject {

	@objc public static let shared = GfxAccelMemoryWarningObserver()

	private var token: NSObjectProtocol?

	@objc public func install() {
		guard token == nil else { return }
		token = NotificationCenter.default.addObserver(
			forName: UIApplication.didReceiveMemoryWarningNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			_ = self  // prevent unused capture warning
			gfxaccel_handle_memory_warning()
		}
	}

	@objc public func uninstall() {
		if let t = token {
			NotificationCenter.default.removeObserver(t)
			token = nil
		}
	}

	deinit {
		uninstall()
	}
}
