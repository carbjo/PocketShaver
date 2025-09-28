//
//  Untitled.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-02.
//

import Combine

enum PreferencesError: Error {
	case romFileMissing
	case noMountedDiskFiles
}

enum PreferencesChange {
	case changeRequiringRestartBeforeBootMade
	case changeRequiringRestartAfterBootMade
}

class PreferencesModel {
	let changeSubject = PassthroughSubject<PreferencesChange, Never>()

	var needsRestart = false

	init() {
		Task { @MainActor in
			_ = MonitorResolutionManager.shared
			objc_update_sdl_ipad_mouse_setting(MiscellaneousSettings.current.iPadMousePassthrough)
			objc_setMouseHapticFeedbackEnabled(MiscellaneousSettings.current.mouseHapticFeedback)
		}
	}

	@MainActor
	func validate() throws {
		let romUrl = FileManager.documentUrl.appendingPathComponent(RomManager.romFilename)
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
