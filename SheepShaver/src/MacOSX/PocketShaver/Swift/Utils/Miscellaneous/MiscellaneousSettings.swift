//
//  MiscellaneousSettings.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-17.
//

import NotificationCenter
import UIKit

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

enum RelativeMouseModeSetting: String, Codable, CaseIterable {
	case manual
	case automatic
	case alwaysOn
}

enum RightClickSetting: String, Codable, CaseIterable {
	case control
	case command
}

enum GammaSetting: String, Codable, CaseIterable {
	case osDefined
	case linear
}

class MiscellaneousSettings: Codable {
	private(set) var showHints: Bool
	private(set) var iPadMousePassthrough: Bool
	private(set) var gestureHapticFeedback: Bool
	private(set) var mouseHapticFeedback: Bool
	private(set) var keyHapticFeedback: Bool
	private(set) var soundDisabled: Bool
	private(set) var fpsCounterEnabled: Bool {
		didSet {
			NotificationCenter.default.post(.init(name: LocalNotifications.fpsCounterSettingChanged))
		}
	}
	private(set) var frameRateSetting: FrameRateSetting
	private(set) var alwaysLandscapeMode: Bool
	private(set) var relativeMouseModeSetting: RelativeMouseModeSetting
	private(set) var relativeMouseTapToClick: Bool
	private(set) var secondFingerClick: Bool
	private(set) var secondFingerSwipe: Bool
	private(set) var bootInHoverMode: Bool
	private(set) var rightClickSetting: RightClickSetting
	private(set) var hoverJustAboveOffsetModifier: Float
	private(set) var gammaSetting: GammaSetting

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
		showHints = true
		iPadMousePassthrough = false
		gestureHapticFeedback = true
		mouseHapticFeedback = true
		keyHapticFeedback = true
		soundDisabled = false
		fpsCounterEnabled = false
		if UIScreen.supportsHighRefreshRate {
			frameRateSetting = .f75hz
		} else {
			frameRateSetting = .f60hz
		}
		alwaysLandscapeMode = false
		relativeMouseModeSetting = .manual
		relativeMouseTapToClick = true
		secondFingerClick = true
		secondFingerSwipe = false
		bootInHoverMode = false
		rightClickSetting = .control
		hoverJustAboveOffsetModifier = 1
		gammaSetting = .osDefined
	}

	@MainActor
	static var current: MiscellaneousSettings = {
		if let data = Storage.shared.load(from: .miscellaneous),
		   let settings = try? JSONDecoder().decode(MiscellaneousSettings.self, from: data) {
			settings.updateCachedResponses()
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
	func updateCachedResponses() {
		MiscellaneousCachedSettings.isRelativeMouseTapToClickOn = relativeMouseTapToClick
		MiscellaneousCachedSettings.framesPerSecond = frameRateSetting.frameRate
		MiscellaneousCachedSettings.isMouseHapticFeedbackOn = mouseHapticFeedback
		MiscellaneousCachedSettings.rightClickSetting = rightClickSetting
	}

	@MainActor
	func set(showHints: Bool) {
		self.showHints = showHints

		saveAsCurrent()
	}

	@MainActor
	func set(iPadMousePassthrough: Bool) {
		self.iPadMousePassthrough = iPadMousePassthrough

		NotificationCenter.default.post(name: LocalNotifications.iPadMousePassthroughChanged, object: nil)

		objc_ADBSetTouchInput(!iPadMousePassthrough)

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

		updateCachedResponses()
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

		updateCachedResponses()
		saveAsCurrent()
	}

	@MainActor
	func set(alwaysLandscapeMode: Bool) {
		self.alwaysLandscapeMode = alwaysLandscapeMode
		if alwaysLandscapeMode {
			InformationConsumption.current.reportHasDisplayedPortraitModeWarning()
		}

		saveAsCurrent()
	}

	@MainActor
	func set(relativeMouseModeSetting: RelativeMouseModeSetting) {
		self.relativeMouseModeSetting = relativeMouseModeSetting
		
		if relativeMouseModeSetting != .manual {
			InformationConsumption.current.reportHasDisplayedFirstRelativeMouseDetectionDialogue()
		}

		saveAsCurrent()
	}

	@MainActor
	func set(relativeMouseTapToClick: Bool) {
		self.relativeMouseTapToClick = relativeMouseTapToClick

		updateCachedResponses()
		saveAsCurrent()
	}

	@MainActor
	func set(secondFingerClick: Bool) {
		self.secondFingerClick = secondFingerClick

		saveAsCurrent()
	}

	@MainActor
	func set(secondFingerSwipe: Bool) {
		self.secondFingerSwipe = secondFingerSwipe

		saveAsCurrent()
	}

	@MainActor
	func set(bootInHoverMode: Bool) {
		self.bootInHoverMode = bootInHoverMode

		saveAsCurrent()
	}

	@MainActor
	func set(rightClickSetting: RightClickSetting) {
		self.rightClickSetting = rightClickSetting

		updateCachedResponses()
		saveAsCurrent()
	}

	@MainActor
	func set(hoverJustAboveOffsetModifier: Float) {
		self.hoverJustAboveOffsetModifier = hoverJustAboveOffsetModifier

		saveAsCurrent()
	}

	@MainActor
	func set(gammaSetting: GammaSetting) {
		self.gammaSetting = gammaSetting

		saveAsCurrent()
	}
}

class MiscellaneousCachedSettings {
	nonisolated(unsafe) static var isRelativeMouseTapToClickOn = true
	nonisolated(unsafe) static var framesPerSecond: Int = 75
	nonisolated(unsafe) static var isMouseHapticFeedbackOn = false
	nonisolated(unsafe) static var rightClickSetting: RightClickSetting = .control
}

@objcMembers
public class MiscellaneousSettingsObjC: NSObject {
	@MainActor
	static func isIPadMousePassthroughOn() -> Bool {
		MiscellaneousSettings.current.iPadMousePassthrough
	}

	@MainActor
	static func getFrameRateSetting() -> Int {
		MiscellaneousSettings.current.frameRateSetting.frameRate
	}

	@MainActor
	static func isRelateiveMouseModeSettingAlwaysOn() -> Bool {
		MiscellaneousSettings.current.relativeMouseModeSetting == .alwaysOn
	}

	@MainActor
	static func isRelateiveMouseModeSettingAutomatic() -> Bool {
		MiscellaneousSettings.current.relativeMouseModeSetting == .automatic
	}

	@MainActor
	static func isSoundDisabled() -> Bool {
		MiscellaneousSettings.current.soundDisabled
	}

	static func isRelativeMouseTapToClickOn() -> Bool {
		MiscellaneousCachedSettings.isRelativeMouseTapToClickOn
	}

	static func isMouseHapticFeedbackOn() -> Bool {
		MiscellaneousCachedSettings.isMouseHapticFeedbackOn
	}

	@MainActor
	static func isLinearGammaEnabled() -> Bool {
		MiscellaneousSettings.current.gammaSetting == .linear
	}
}
