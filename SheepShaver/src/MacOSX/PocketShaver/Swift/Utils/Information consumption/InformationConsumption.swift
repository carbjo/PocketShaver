//
//  InformationConsumption.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-24.
//

import Foundation

class InformationConsumption: Codable {
	private(set) var hasDismissedSetupInstructions: Bool
	private(set) var hasDisplayedPortraitModeWarning: Bool
	private(set) var hasDisplayedFirstRelativeMouseDetectionDialogue: Bool

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
		hasDismissedSetupInstructions = false
		hasDisplayedPortraitModeWarning = false
		hasDisplayedFirstRelativeMouseDetectionDialogue = false
	}

	@MainActor
	private func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .informationConsumption)
		} catch {}
	}

	@MainActor
	func reportHasDismissedSetupInstructions() {
		hasDismissedSetupInstructions = true

		saveAsCurrent()
	}


	@MainActor
	func reportHasDisplayedPortraitModeWarning() {
		hasDisplayedPortraitModeWarning = true

		saveAsCurrent()
	}

	@MainActor
	func reportHasDisplayedFirstRelativeMouseDetectionDialogue() {
		hasDisplayedFirstRelativeMouseDetectionDialogue = true

		saveAsCurrent()
	}
}
