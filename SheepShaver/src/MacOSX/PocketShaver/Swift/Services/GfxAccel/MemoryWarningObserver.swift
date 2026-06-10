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
 *  Observes UIApplicationDidReceiveMemoryWarningNotification on the main
 *  thread and calls the C shim gfxaccel_handle_memory_warning() which
 *  dispatch_async's eviction work to the emul serial queue.
 *
 *  Swift singleton calls C shim from main thread; the C shim returns in
 *  <=1 ms (dispatch_async only). No std::mutex / std::atomic;
 *  synchronization is via the emul serial queue owned by
 *  gfxaccel_resources_heap.mm.
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
