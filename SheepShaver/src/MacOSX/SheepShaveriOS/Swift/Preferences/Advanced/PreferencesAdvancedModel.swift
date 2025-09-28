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
	struct Option {
		let title: String
		let prefsIdentifier: String
	}

	struct OptionInitialState {
		let option: Option
		let isOn: Bool
	}

	private let changeSubject: PassthroughSubject<PreferencesChange, Never>

	let optionsInitialStates: [OptionInitialState]

	@MainActor
	var hasDismissedSetupInstructions: Bool {
		MiscellaneousSettings.current.hasDismissedSetupInstructions
	}

	@MainActor
	var hasRomFile: Bool {
		RomManager.shared.hasRomFile
	}

	@MainActor
	var currentRomFileType: RomType {
		RomManager.shared.currentRomFileType
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
		let options: [Option] = [
			.init(title: "Allow CPU To Idle", prefsIdentifier: "idlewait"),
			.init(title: "Ignore Illegal Instructions", prefsIdentifier: "ignoreillegal"),
			.init(title: "Ignore Illegal Memory", prefsIdentifier: "ignoresegv")
			]
		var optionsInitialStates = [OptionInitialState]()

		for option in options {
			optionsInitialStates.append(
				.init(
					option: option,
					isOn: objc_findBool(option.prefsIdentifier)
				)
			)
		}

		self.changeSubject = changeSubject
		self.optionsInitialStates = optionsInitialStates
	}

	@MainActor
	func didSelectRomCandidate(url: URL) async throws {
		try await RomManager.shared.didSelectRomCandidate(url: url)
		changeSubject.send(.changeRequiringRestartAfterBootMade)
	}

	@MainActor
	func forceSelectTmpRom() throws {
		try RomManager.shared.forceSelectTmpRom()
		changeSubject.send(.changeRequiringRestartAfterBootMade)
	}

	func didSet(option: Option, isOn: Bool) {
		objc_replaceBool(option.prefsIdentifier, isOn)
		changeSubject.send(.changeRequiringRestartAfterBootMade)
	}
}
