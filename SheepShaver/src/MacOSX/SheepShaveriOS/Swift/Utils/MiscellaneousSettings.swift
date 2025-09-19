//
//  MiscellaneousSettings.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-17.
//

class MiscellaneousSettings: Codable {
	private(set) var hasDismissedSetupInstructions: Bool
	private(set) var showHints: Bool

	init() {
		hasDismissedSetupInstructions = false
		showHints = true
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

	@MainActor
	func set(showHints: Bool) {
		self.showHints = showHints

		saveAsCurrent()
	}
}
