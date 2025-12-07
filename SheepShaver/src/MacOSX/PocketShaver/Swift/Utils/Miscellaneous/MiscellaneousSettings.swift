//
//  MiscellaneousSettings.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-17.
//

import NotificationCenter
import UIKit

enum MiscellaneousNotifications {
	static let fpsCounterSettingChanged = NSNotification.Name("fpsCounterSettingChanged")
}

enum FrameRateSetting: String, Codable, CaseIterable {
	case f60hz
	case f75hz
	case f120hz

	var frameRate: Int {
		switch self {
		case .f60hz: return 60
		case .f75hz: return 75
		case .f120hz: return 120
		}
	}
}

class MiscellaneousSettings: Codable {
	private(set) var hasDismissedSetupInstructions: Bool
	private(set) var showHints: Bool
	private(set) var iPadMousePassthrough: Bool {
		didSet {
			objc_replaceBool("ipadmousepassthrough", iPadMousePassthrough)
		}
	}
	private(set) var gestureHapticFeedback: Bool
	private(set) var mouseHapticFeedback: Bool
	private(set) var keyHapticFeedback: Bool
	private(set) var soundDisabled: Bool {
		didSet {
			objc_replaceBool("nosound", soundDisabled)
		}
	}
	private(set) var fpsCounterEnabled: Bool {
		didSet {
			NotificationCenter.default.post(.init(name: MiscellaneousNotifications.fpsCounterSettingChanged))
		}
	}
	private(set) var frameRateSetting: FrameRateSetting
	private(set) var alwaysLandscapeMode: Bool
	private(set) var hasDisplayedPortraitModeWarning: Bool

	var shouldDisplayAlwaysLandscapeModeOption: Bool {
		if #available(iOS 16, *) {
			return true
		} else {
			// Solution does not work in iOS 15.x
			return false
		}
	}

	@MainActor
	init() {
		hasDismissedSetupInstructions = false
		showHints = true
		iPadMousePassthrough = false
		gestureHapticFeedback = true
		mouseHapticFeedback = true
		keyHapticFeedback = true
		soundDisabled = objc_findBool("nosound")
		fpsCounterEnabled = false
		if UIScreen.supportsHighRefreshRate {
			frameRateSetting = .f75hz
		} else {
			frameRateSetting = .f60hz
		}
		alwaysLandscapeMode = false
		hasDisplayedPortraitModeWarning = false
	}

	@MainActor
	static var current: MiscellaneousSettings = {
		if let data = Storage.shared.load(from: .miscellaneous),
		   let settings = try? JSONDecoder().decode(MiscellaneousSettings.self, from: data) {
			return settings
		}

		return MiscellaneousSettings()
	}()

	@MainActor
	func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .miscellaneous)
		} catch {}
	}

	@MainActor
	func reportHasDismissedSetupInstructions() {
		hasDismissedSetupInstructions = true

		saveAsCurrent()
	}

	@MainActor
	func set(showHints: Bool) {
		self.showHints = showHints

		saveAsCurrent()
	}

	@MainActor
	func set(iPadMousePassthrough: Bool) {
		self.iPadMousePassthrough = iPadMousePassthrough

		saveAsCurrent()
	}

	@MainActor
	func set(gestureHapticFeedback: Bool) {
		self.gestureHapticFeedback = gestureHapticFeedback

		saveAsCurrent()
	}

	@MainActor
	func set(mouseHapticFeedback: Bool) {
		self.mouseHapticFeedback = mouseHapticFeedback

		objc_setMouseHapticFeedbackEnabled(mouseHapticFeedback)

		saveAsCurrent()
	}

	@MainActor
	func set(keyHapticFeedback: Bool) {
		self.keyHapticFeedback = keyHapticFeedback

		saveAsCurrent()
	}

	@MainActor
	func set(soundDisabled: Bool) {
		self.soundDisabled = soundDisabled

		saveAsCurrent()
	}

	@MainActor
	func set(fpsCounterEnabled: Bool) {
		self.fpsCounterEnabled = fpsCounterEnabled

		saveAsCurrent()
	}

	@MainActor
	func set(frameRateSetting: FrameRateSetting) {
		self.frameRateSetting = frameRateSetting

		saveAsCurrent()
	}

	@MainActor
	func set(alwaysLandscapeMode: Bool) {
		self.alwaysLandscapeMode = alwaysLandscapeMode
		if alwaysLandscapeMode {
			hasDisplayedPortraitModeWarning = true
		}

		saveAsCurrent()
	}

	@MainActor
	func set(hasDisplayedPortraitModeWarning: Bool) {
		self.hasDisplayedPortraitModeWarning = hasDisplayedPortraitModeWarning

		saveAsCurrent()
	}
}

@objcMembers
public class MiscellaneousSettingsObjC: NSObject {

	@MainActor
	static func isKeyHapticFeedbackOn() -> Bool {
		MiscellaneousSettings.current.keyHapticFeedback
	}

	@MainActor
	static func getFrameRateSetting() -> Int {
		MiscellaneousSettings.current.frameRateSetting.frameRate
	}
}
