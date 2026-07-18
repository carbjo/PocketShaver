//
//  Untitled.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-02.
//

import Combine
import NotificationCenter
import UIKit
import UserNotifications

enum PreferencesError: Error {
	case romFileMissing
	case noMountedDiskFiles
}

enum PreferencesChange {
	case changeRequiringRestartBeforeBootMade
	case changeRequiringRestartAfterBootMade
	case alwaysLandscapeModeOptionToggled
	case selectedResolutionsChanged
	case frameRateSettingChanged
	case iPadMouseEnabledChanged
	case gamepadLayoutsDidUpdate
}

class PreferencesModel {

	let mode: PreferencesLaunchMode

	let changeSubject = PassthroughSubject<PreferencesChange, Never>()

	var needsRestart = false

	init(
		mode: PreferencesLaunchMode
	) {
		self.mode = mode

		Task { @MainActor in
			_ = MonitorResolutionManager.shared
			NetworkSettings.initIfNeeded()
			objc_update_sdl_ipad_mouse_setting(MiscellaneousSettings.current.iPadMousePassthrough)
			UNUserNotificationCenter.current().removeAllDeliveredNotifications()
			// The on-screen gamepad (and its expensive, full-window, main-thread
			// thumbnail rendering) is not shown on Mac, so skip the preload there.
			if UIDevice.deviceType != .mac {
				GamepadThumbnailCache.shared.preloadImages()
			}
		}
	}

	@MainActor
	func validate() throws {
		let romUrl = RomManager.shared.romUrl
		let hasRomFile = FileManager.default.fileExists(atPath: romUrl.path)
		guard hasRomFile else {
			throw PreferencesError.romFileMissing
		}

		let hasMountedDiskFiles = !DiskManager.shared.diskArray.filter({ $0.isEnabled }).isEmpty
		guard hasMountedDiskFiles else {
			throw PreferencesError.noMountedDiskFiles
		}
	}
}
