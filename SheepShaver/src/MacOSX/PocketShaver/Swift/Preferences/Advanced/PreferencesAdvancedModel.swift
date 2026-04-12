//
//  PreferencesAdvancedModel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-15.
//

import Foundation
import Combine
import CoreHaptics

class PreferencesAdvancedModel {
	let changeSubject: PassthroughSubject<PreferencesChange, Never>

	let mode: PreferencesLaunchMode

	@MainActor
	private var miscSettings: MiscellaneousSettings {
		.current
	}

	var ramSetting: PreferencesGeneralRamSetting {
		get {
			PreferencesGeneralRamSetting.current
		}
		set {
			PreferencesGeneralRamSetting.current = newValue

			changeSubject.send(.changeRequiringRestartBeforeBootMade)
		}
	}

	@MainActor
	var fpsReportingEnabled: Bool {
		get {
			miscSettings.fpsReporting
		}
		set {
			miscSettings.set(fpsCounterEnabled: newValue)
		}
	}

	@MainActor
	var networkTransferRateReportingEnabled: Bool {
		get {
			miscSettings.networkTransferRateReportingEnabled
		}
		set {
			miscSettings.set(networkTransferRateReportingEnabled: newValue)
		}
	}

	@MainActor
	var alwaysLandscapeMode: Bool {
		get {
			miscSettings.alwaysLandscapeMode
		}
		set {
			miscSettings.set(alwaysLandscapeMode: newValue)

			changeSubject.send(.alwaysLandscapeModeOptionToggled)
		}
	}

	@MainActor
	var hoverJustAboveOffsetModifier: Float {
		get {
			miscSettings.hoverJustAboveOffsetModifier
		}
		set {
			miscSettings.set(hoverJustAboveOffsetModifier: newValue)
		}
	}

	@MainActor
	var shouldDisplayAlwaysLandscapeModeOption: Bool {
		miscSettings.shouldDisplayAlwaysLandscapeModeOption
	}

	@MainActor
	var reportIpAddressAssignment: Bool {
		get {
			NetworkSettings.current.reportIpAddressAssignment
		}
		set {
			NetworkSettings.current.set(reportIpAddressAssignment: newValue)
		}
	}

	@MainActor
	var relativeMouseModeSetting: RelativeMouseModeSetting {
		get {
			miscSettings.relativeMouseModeSetting
		}
		set {
			miscSettings.set(relativeMouseModeSetting: newValue)

			switch newValue {
			case .automatic:
				cpp_setRelativeMouseModeAutomatic();
			case .alwaysOn:
				cpp_setRelativeMouseMode(true);
			default: break
			}

			NotificationCenter.default.post(name: LocalNotifications.relativeMouseModeSettingChanged, object: nil)
		}
	}

	@MainActor
	var isIPadMouseEnabled: Bool {
		miscSettings.iPadMousePassthrough
	}

	@MainActor
	var bootInRelativeMouseMode: Bool {
		get {
			miscSettings.bootInRelativeMouseMode
		}
		set {
			miscSettings.set(bootInRelativeMouseMode: newValue)
		}
	}

	@MainActor
	var relativeMouseModeClickGestureSetting: RelativeMouseModeClickGestureSetting {
		get {
			miscSettings.relativeMouseModeClickGestureSetting
		}
		set {
			miscSettings.set(relativeMouseModeClickGestureSetting: newValue)
		}
	}

	@MainActor
	var hasRomFile: Bool {
		RomManager.shared.hasRomFile
	}

	@MainActor
	var currentRomFileDescription: String? {
		RomManager.shared.currentRomFileVersion?.description
	}

	lazy var supportsHaptics: Bool = {
		CHHapticEngine.capabilitiesForHardware().supportsHaptics
	}()

	@MainActor
	var isGestureHapticFeedbackOn: Bool {
		get {
			miscSettings.gestureHapticFeedback
		}
		set {
			miscSettings.set(gestureHapticFeedback: newValue)
		}
	}

	@MainActor
	var isMouseHapticFeedbackOn: Bool {
		get {
			miscSettings.mouseHapticFeedback
		}
		set {
			miscSettings.set(mouseHapticFeedback: newValue)
		}
	}

	@MainActor
	var isKeyHapticFeedbackOn: Bool {
		get {
			miscSettings.keyHapticFeedback
		}
		set {
			miscSettings.set(keyHapticFeedback: newValue)
		}
	}

	@MainActor
	var gammaRampSetting: GammaRampSetting {
		get {
			miscSettings.gammaRampSetting
		}
		set {
			miscSettings.set(gammaRampSetting: newValue)
		}
	}

	init(
		mode: PreferencesLaunchMode,
		changeSubject: PassthroughSubject<PreferencesChange, Never>
	) {
		self.mode = mode
		self.changeSubject = changeSubject
	}

	@MainActor
	func didSelectMacOsInstallDiskCandidate(url: URL) async -> RomValidationResult {
		let result = await RomManager.shared.didSelectMacOsInstallDiskCandidate(url: url)
		changeSubject.send(.changeRequiringRestartAfterBootMade)
		return result
	}
}

extension PreferencesGeneralRamSetting {

	static var current: Self {
		get {
			let persistedRamInMbValue = objc_findInt32("ramsize")
			return .init(ramInMB: persistedRamInMbValue)
		}
		set {
			objc_replaceInt32("ramsize", newValue.ramInMB)
		}
	}

	var ramInMB: Int {
		switch self {
		case .n32: 32
		case .n64: 64
		case .n128: 128
		case .n256: 256
		case .n512: 512
		}
	}

	init(ramInMB: Int) {
		if ramInMB >= Self.n512.ramInMB {
			self = .n512
		} else if ramInMB >= Self.n256.ramInMB {
			self = .n256
		} else if ramInMB >= Self.n128.ramInMB {
			self = .n128
		} else if ramInMB >= Self.n64.ramInMB {
			self = .n64
		} else {
			self = .n32
		}
	}
}
