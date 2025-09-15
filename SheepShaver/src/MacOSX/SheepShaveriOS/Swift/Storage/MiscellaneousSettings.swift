//
//  MiscellaneousSettings.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-17.
//

class MiscellaneousSettings: Codable {
	var hasDismissedSetupInstructions: Bool

	init() {
		hasDismissedSetupInstructions = false
	}

	private init(
		hasDismissedSetupInstructions: Bool
	) {
		self.hasDismissedSetupInstructions = hasDismissedSetupInstructions
	}

	@MainActor
	static var current: MiscellaneousSettings {
		if let data = Storage.shared.load(from: .miscellaneous),
		   let settings = try? JSONDecoder().decode(Self.self, from: data) {
			return settings
		}

		return MiscellaneousSettings()
	}

	@MainActor
	func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .miscellaneous)
		} catch {}
	}

	@MainActor
	func reportHasDismissedSetupInstructions() {
		hasDismissedSetupInstructions = true

		saveAsCurrent()
	}
}
