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

enum TwoFingerSteeringSetting: String, Codable, CaseIterable, Hashable {
	case off
	case click
	case clickPlusSwipe
	case clickPlusSwipePlusBootInHoverMode
}

enum RelativeMouseModeSetting: String, Codable, CaseIterable {
	case manual
	case automatic
	case alwaysOn
}

enum RelativeMouseModeClickGestureSetting: String, Codable, CaseIterable {
	case off
	case tap
	case secondFingerClick
}

enum RightClickSetting: String, Codable, CaseIterable {
	case control
	case command
}

enum KeyboardAutoOffsetSetting: String, Codable, CaseIterable {
	case top // none
	case middle
	case bottom
}

enum GammaRampSetting: String, Codable, CaseIterable {
	case osDefined
	case linear
}

class MiscellaneousSettings: Codable {
	private(set) var showHints: Bool
	private(set) var iPadMousePassthrough: Bool
	private(set) var gestureHapticFeedback: Bool
	private(set) var mouseHapticFeedback: Bool
	private(set) var keyHapticFeedback: Bool
	private(set) var audioEnabled: Bool {
		didSet {
			NotificationCenter.default.post(.init(name: LocalNotifications.audioEnabledChanged))
		}
	}
	private(set) var fpsReporting: Bool {
		didSet {
			NotificationCenter.default.post(.init(name: LocalNotifications.performanceCounterSettingChanged))
		}
	}
	private(set) var networkTransferRateReportingEnabled: Bool {
		didSet {
			NotificationCenter.default.post(.init(name: LocalNotifications.performanceCounterSettingChanged))
		}
	}
	private(set) var frameRateSetting: FrameRateSetting
	private(set) var alwaysLandscapeMode: Bool
	private(set) var twoFingerSteeringSetting: TwoFingerSteeringSetting
	private(set) var relativeMouseModeSetting: RelativeMouseModeSetting
	private(set) var relativeMouseModeClickGestureSetting: RelativeMouseModeClickGestureSetting
	private(set) var rightClickSetting: RightClickSetting
	private(set) var keyboardAutoOffsetSetting: KeyboardAutoOffsetSetting
	private(set) var hoverJustAboveOffsetModifier: Float
	private(set) var gammaRampSetting: GammaRampSetting
	private(set) var bootInRelativeMouseMode: Bool

	var secondFingerClick: Bool {
		twoFingerSteeringSetting != .off
	}

	var secondFingerSwipe: Bool {
		twoFingerSteeringSetting == .clickPlusSwipe ||
		twoFingerSteeringSetting == .clickPlusSwipePlusBootInHoverMode
	}

	var shouldBootInHoverMode: Bool {
		twoFingerSteeringSetting == .clickPlusSwipePlusBootInHoverMode
	}

	var relativeMouseModeSecondFingerClick: Bool {
		relativeMouseModeClickGestureSetting == .secondFingerClick
	}

	var shouldBootInRelativeMouseMode: Bool {
		if relativeMouseModeSetting == .alwaysOn {
			return true
		}

		if UIDevice.deviceType == .mac ||
			(UIDevice.deviceType == .iPad && iPadMousePassthrough),
		   bootInRelativeMouseMode {
			return true
		}
		return false
	}

	private static var shouldDisplayAlwaysLandscapeModeOption: Bool {
		if #available(iOS 16, *) {
			return true
		} else {
			// Solution does not work in iOS 15.x
			return false
		}
	}

	var shouldDisplayAlwaysLandscapeModeOption: Bool {
		Self.shouldDisplayAlwaysLandscapeModeOption
	}

	@MainActor
	init() {
		showHints = true
		iPadMousePassthrough = UIDevice.deviceType == .mac
		gestureHapticFeedback = true
		mouseHapticFeedback = true
		keyHapticFeedback = true
		audioEnabled = true
		fpsReporting = false
		networkTransferRateReportingEnabled = false
		if UIScreen.supportsHighRefreshRate {
			frameRateSetting = .f120hz
		} else {
			frameRateSetting = .f60hz
		}
		alwaysLandscapeMode = Self.shouldDisplayAlwaysLandscapeModeOption
		twoFingerSteeringSetting = .off
		relativeMouseModeSetting = .manual
		relativeMouseModeClickGestureSetting = .tap
		rightClickSetting = .control
		keyboardAutoOffsetSetting = .middle
		hoverJustAboveOffsetModifier = 1
		gammaRampSetting = .osDefined
		bootInRelativeMouseMode = UIDevice.deviceType == .mac
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
		MiscellaneousCachedSettings.isRelativeMouseTapToClickOn = relativeMouseModeClickGestureSetting == .tap
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
	func set(audioEnabled: Bool) {
		self.audioEnabled = audioEnabled

		saveAsCurrent()
	}

	@MainActor
	func set(fpsCounterEnabled: Bool) {
		self.fpsReporting = fpsCounterEnabled

		saveAsCurrent()
	}

	@MainActor
	func set(networkTransferRateReportingEnabled: Bool) {
		self.networkTransferRateReportingEnabled = networkTransferRateReportingEnabled

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
	func set(relativeMouseModeClickGestureSetting: RelativeMouseModeClickGestureSetting) {
		self.relativeMouseModeClickGestureSetting = relativeMouseModeClickGestureSetting

		updateCachedResponses()
		saveAsCurrent()
	}

	@MainActor
	func set(twoFingerSteeringSetting: TwoFingerSteeringSetting) {
		self.twoFingerSteeringSetting = twoFingerSteeringSetting

		saveAsCurrent()
	}

	@MainActor
	func set(rightClickSetting: RightClickSetting) {
		self.rightClickSetting = rightClickSetting

		updateCachedResponses()
		saveAsCurrent()
	}

	@MainActor
	func set(keyboardAutoOffsetSetting: KeyboardAutoOffsetSetting) {
		self.keyboardAutoOffsetSetting = keyboardAutoOffsetSetting

		saveAsCurrent()
	}

	@MainActor
	func set(hoverJustAboveOffsetModifier: Float) {
		self.hoverJustAboveOffsetModifier = hoverJustAboveOffsetModifier

		saveAsCurrent()
	}

	@MainActor
	func set(gammaRampSetting: GammaRampSetting) {
		self.gammaRampSetting = gammaRampSetting

		saveAsCurrent()
	}

	@MainActor
	func set(bootInRelativeMouseMode: Bool) {
		self.bootInRelativeMouseMode = bootInRelativeMouseMode

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
	static func isAudioEnabled() -> Bool {
		MiscellaneousSettings.current.audioEnabled
	}

	static func isRelativeMouseTapToClickOn() -> Bool {
		MiscellaneousCachedSettings.isRelativeMouseTapToClickOn
	}

	static func isMouseHapticFeedbackOn() -> Bool {
		MiscellaneousCachedSettings.isMouseHapticFeedbackOn
	}

	@MainActor
	static func isLinearGammaEnabled() -> Bool {
		MiscellaneousSettings.current.gammaRampSetting == .linear
	}

	@MainActor
	static func shouldBootInRelativeMouseMode() -> Bool {
		MiscellaneousSettings.current.shouldBootInRelativeMouseMode
	}
}
