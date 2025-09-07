//
//  GamepadConfig.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-28.
//

import Foundation

enum GamepadSide: Codable, Equatable {
	case left
	case right
}

struct GamepadButtonPosition: Codable, Equatable {
	let side: GamepadSide
	let row: Int
	let index: Int
}

enum GamepadButtonAssignment: Codable, Equatable {
	case key(SDLKey)
	case specialButton(SpecialButton)
}

struct GamepadButtonMapping: Codable, Equatable {
	let position: GamepadButtonPosition
	let assignment: GamepadButtonAssignment
}

struct GamepadConfig: Codable, Equatable {
	let name: String
	let mappings: [GamepadButtonMapping]

	func replacing(with key: SDLKey, at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = removingAssignment(at: position).mappings
		assignments.append(.init(position: position, assignment: .key(key)))

		return .init(
			name: name,
			mappings: assignments
		)
	}

	func replacing(with specialButton: SpecialButton, at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = removingAssignment(at: position).mappings
		assignments.append(.init(position: position, assignment: .specialButton(specialButton)))

		return .init(
			name: name,
			mappings: assignments
		)
	}

	func removingAssignment(at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = mappings
		if let oldIndex = assignments.firstIndex(where: { $0.position == position }) {
			assignments.remove(at: oldIndex)
		}

		return .init(
			name: name,
			mappings: assignments
		)
	}

	func renaming(_ newName: String) -> GamepadConfig {
		.init(
			name: newName,
			mappings: mappings
		)
	}

	static var exampleConfig: GamepadConfig {
		.init(
			name: "Example layout",
			mappings: [
				.init(position: .init(side: .left, row: 0, index: 0), assignment: .key(.down)),
				.init(position: .init(side: .left, row: 0, index: 1), assignment: .key(.up)),
				.init(position: .init(side: .left, row: 0, index: 2), assignment: .key(.space)),
				.init(position: .init(side: .left, row: 1, index: 0), assignment: .key(.q)),
				.init(position: .init(side: .right, row: 0, index: 2), assignment: .key(.tab)),
				.init(position: .init(side: .right, row: 0, index: 1), assignment: .key(.left)),
				.init(position: .init(side: .right, row: 0, index: 0), assignment: .key(.right)),
				.init(position: .init(side: .right, row: 1, index: 1), assignment: .key(.alt)),
				.init(position: .init(side: .right, row: 1, index: 0), assignment: .key(.cmd))
			]
		)
	}
}

struct GamepadSettings: Codable {
	private let currentConfigIndex: Int
	private let configurations: [GamepadConfig]

	@MainActor static var current: GamepadSettings {
		if let data = Storage.shared.load(from: .gamepad) {
			do {
				let config = try JSONDecoder().decode(Self.self, from: data)
				return config
			} catch {}
		}

		return .init(currentConfigIndex: 0, configurations: [])
	}

	var previoius: GamepadSettings {
		if currentConfigIndex == -1 {
			return self
		}

		return .init(currentConfigIndex: currentConfigIndex - 1, configurations: configurations)
	}

	var next: GamepadSettings {
		if currentConfigIndex == configurations.count {
			return self
		}

		return .init(currentConfigIndex: currentConfigIndex + 1, configurations: configurations)
	}

	@MainActor var config: GamepadConfig {
		if currentConfigIndex >= 0,
		   currentConfigIndex < configurations.count {
			return configurations[currentConfigIndex]
		} else {
			return .exampleConfig
		}
	}

	@MainActor func replaceCurrentConfig(with config: GamepadConfig) -> GamepadSettings {
		let gamepadSettings = replacingCurrentConfig(with: config)
		gamepadSettings.saveAsCurrent()
		return gamepadSettings
	}

	@MainActor func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .gamepad)
		} catch {}
	}

	private func replacingCurrentConfig(with config: GamepadConfig) -> GamepadSettings {
		guard config != .exampleConfig else {
			return self
		}

		var configurations = configurations
		if currentConfigIndex == -1 {
			configurations.insert(config, at: 0)

			return .init(currentConfigIndex: 0, configurations: configurations)
		} else if currentConfigIndex == configurations.count {
			configurations.append(config)

			return .init(currentConfigIndex: configurations.count - 1, configurations: configurations)
		} else {
			configurations[currentConfigIndex] = config

			return .init(currentConfigIndex: currentConfigIndex, configurations: configurations)
		}
	}
}
