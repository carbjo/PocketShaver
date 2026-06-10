//
//  PreferencesGraphicsModel.swift
//  (C) 2026 Sierra Burkhart (sierra760)
//

import Foundation
import Combine

enum RenderingFilterMode: String, Codable, CaseIterable {
	case bilinear
	case nearestNeighbor
}

class PreferencesGraphicsModel {

	struct FrameRateState: Hashable {
		let setting: FrameRateSetting
		let hasChanged: Bool
	}

	struct MonitorResolutionsState: Hashable {
		let enabledResolutions: [MonitorResolutionOption]
		let willBootFromCD: Bool
	}

	private let changeSubject: PassthroughSubject<PreferencesChange, Never>

	let mode: PreferencesLaunchMode

	// MARK: - Monitor Resolutions

	@MainActor
	var monitorResolutionsState: MonitorResolutionsState {
		return .init(
			enabledResolutions: MonitorResolutionManager.shared.enabledResolutions,
			willBootFromCD: DiskManager.shared.willBootFromCD
		)
	}

	// MARK: - Frame Rate Setting

	@MainActor
	private let originalFrameRateSetting = MiscellaneousSettings.current.frameRateSetting

	@MainActor
	var frameRateSetting: FrameRateSetting {
		get {
			MiscellaneousSettings.current.frameRateSetting
		}
		set {
			MiscellaneousSettings.current.set(frameRateSetting: newValue)

			if mode == .startup {
				cpp_updateFrameRateHz()
			}

			changeSubject.send(.frameRateSettingChanged)
			changeSubject.send(.changeRequiringRestartAfterBootMade)
		}
	}

	@MainActor
	var frameRateState: FrameRateState {
		.init(
			setting: frameRateSetting,
			hasChanged: frameRateSetting != originalFrameRateSetting
		)
	}

	// MARK: - Gamma Ramp Setting

	@MainActor
	var gammaRampSetting: GammaRampSetting {
		get {
			MiscellaneousSettings.current.gammaRampSetting
		}
		set {
			MiscellaneousSettings.current.set(gammaRampSetting: newValue)
		}
	}

	// MARK: - Graphics Acceleration

	var nqdAccelEnabled: Bool {
		get {
			objc_findBool("nqdaccel")
		}
		set {
			objc_replaceBool("nqdaccel", newValue)
			changeSubject.send(.changeRequiringRestartBeforeBootMade)
		}
	}

	var raveAccelEnabled: Bool {
		get {
			objc_findBool("raveaccel")
		}
		set {
			objc_replaceBool("raveaccel", newValue)
			changeSubject.send(.changeRequiringRestartBeforeBootMade)
		}
	}

	var glAccelEnabled: Bool {
		get {
			objc_findBool("glaccel")
		}
		set {
			objc_replaceBool("glaccel", newValue)
			changeSubject.send(.changeRequiringRestartBeforeBootMade)
		}
	}

	var dspAccelEnabled: Bool {
		get {
			objc_findBool("dspaccel")
		}
		set {
			objc_replaceBool("dspaccel", newValue)
			changeSubject.send(.changeRequiringRestartBeforeBootMade)
		}
	}

	// MARK: - Rendering Filter Mode

	var renderingFilterMode: RenderingFilterMode {
		get {
			let useNearest = objc_findBool("scale_nearest")
			return useNearest ? .nearestNeighbor : .bilinear
		}
		set {
			let useNearest = newValue == .nearestNeighbor
			objc_replaceBool("scale_nearest", useNearest)
		}
	}

	// MARK: - Initialization

	init(
		mode: PreferencesLaunchMode,
		changeSubject: PassthroughSubject<PreferencesChange, Never>
	) {
		self.mode = mode
		self.changeSubject = changeSubject
	}
}
