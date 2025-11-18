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
	private let changeSubject: PassthroughSubject<PreferencesChange, Never>

	@MainActor
	var hasDismissedSetupInstructions: Bool {
		MiscellaneousSettings.current.hasDismissedSetupInstructions
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
			MiscellaneousSettings.current.gestureHapticFeedback
		}
		set {
			MiscellaneousSettings.current.set(gestureHapticFeedback: newValue)
		}
	}

	@MainActor
	var isMouseHapticFeedbackOn: Bool {
		get {
			MiscellaneousSettings.current.mouseHapticFeedback
		}
		set {
			MiscellaneousSettings.current.set(mouseHapticFeedback: newValue)
		}
	}

	@MainActor
	var isKeyHapticFeedbackOn: Bool {
		get {
			MiscellaneousSettings.current.keyHapticFeedback
		}
		set {
			MiscellaneousSettings.current.set(keyHapticFeedback: newValue)
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
