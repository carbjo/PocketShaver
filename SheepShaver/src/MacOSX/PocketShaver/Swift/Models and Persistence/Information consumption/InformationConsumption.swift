//
//  InformationConsumption.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-24.
//

import Foundation

class InformationConsumption: Codable {
	private(set) var hasReadSetupInstructions: Bool
	private(set) var hasDismissedSetupInstructions: Bool
	private(set) var hasDisplayedFirstRelativeMouseDetectionDialogue: Bool
	private(set) var hasDisplayedJaggyCursorWarningDialogue: Bool

	@MainActor
	static var current: InformationConsumption = {
		if let data = Storage.shared.load(from: .informationConsumption),
		   let settings = try? JSONDecoder().decode(InformationConsumption.self, from: data) {
			return settings
		}

		return InformationConsumption()
	}()

	@MainActor
	init() {
		hasReadSetupInstructions = false
		hasDismissedSetupInstructions = false
		hasDisplayedFirstRelativeMouseDetectionDialogue = false
		hasDisplayedJaggyCursorWarningDialogue = false
	}

	@MainActor
	private func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .informationConsumption)
		} catch {}
	}

	@MainActor
	func reportHasReadSetupInstructions() {
		hasReadSetupInstructions = true

		saveAsCurrent()
	}

	@MainActor
	func reportHasDismissedSetupInstructions() {
		hasDismissedSetupInstructions = true

		saveAsCurrent()
	}

	@MainActor
	func reportHasDisplayedFirstRelativeMouseDetectionDialogue() {
		hasDisplayedFirstRelativeMouseDetectionDialogue = true

		saveAsCurrent()
	}

	@MainActor
	func reportHasDisplayedJaggyCursorWarningDialogue() {
		hasDisplayedJaggyCursorWarningDialogue = true

		saveAsCurrent()
	}
}
