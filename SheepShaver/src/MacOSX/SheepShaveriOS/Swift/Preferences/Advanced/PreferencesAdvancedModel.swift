//
//  PreferencesAdvancedModel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-15.
//

import Foundation
import Combine

class PreferencesAdvancedModel {
	private let changeSubject: PassthroughSubject<PreferencesChange, Never>

	@MainActor
	var hasRomFile: Bool {
		RomManager.shared.hasRomFile
	}

	@MainActor
	var currentRomFileDescription: String? {
		RomManager.shared.currentRomFileVersion?.description
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
	var showFpsCounterEnabled: Bool {
		get {
			MiscellaneousSettings.current.fpsCounterEnabled
		}
		set {
			MiscellaneousSettings.current.set(fpsCounterEnabled: newValue)
		}
	}

	@MainActor
	var frameRateSetting: FrameRateSetting {
		get {
			MiscellaneousSettings.current.frameRateSetting
		}
		set {
			MiscellaneousSettings.current.set(frameRateSetting: newValue)

			changeSubject.send(.changeRequiringRestartBeforeBootMade)
		}
	}

	init(changeSubject: PassthroughSubject<PreferencesChange, Never>) {
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

	var label: String {
		"\(ramInMB) MB"
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
