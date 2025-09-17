//
//  PreferencesAdvancedModel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-15.
//

import Foundation

class PreferencesAdvancedModel {
	struct Option {
		let title: String
		let prefsIdentifier: String
	}

	struct OptionInitialState {
		let option: Option
		let isOn: Bool
	}

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

	init() {
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

		self.optionsInitialStates = optionsInitialStates
	}

	@MainActor
	func didSelectRomCandidate(url: URL) async throws {
		try await RomManager.shared.didSelectRomCandidate(url: url)
	}

	@MainActor
	func forceSelectTmpRom() throws {
		try RomManager.shared.forceSelectTmpRom()
	}

	func didSet(option: Option, isOn: Bool) {
		objc_replaceBool(option.prefsIdentifier, isOn)
	}
}
