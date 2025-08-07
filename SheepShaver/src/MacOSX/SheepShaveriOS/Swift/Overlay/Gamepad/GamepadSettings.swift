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

struct GamepadButtonAssignment: Codable, Equatable {
	let position: GamepadButtonPosition
	let key: SDLKey
}

struct GamepadConfig: Codable, Equatable {
	let name: String
	let assignments: [GamepadButtonAssignment]

	func replacing(key: SDLKey, at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = removingAssignment(at: position).assignments
		assignments.append(.init(position: position, key: key))

		return .init(
			name: name,
			assignments: assignments
		)
	}

	func removingAssignment(at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = assignments
		if let oldIndex = assignments.firstIndex(where: { $0.position == position }) {
			assignments.remove(at: oldIndex)
		}

		return .init(
			name: name,
			assignments: assignments
		)
	}

	func renaming(_ newName: String) -> GamepadConfig {
		.init(
			name: newName,
			assignments: assignments
		)
	}

	static var exampleConfig: GamepadConfig {
		.init(
			name: "Example layout",
			assignments: [
				.init(position: .init(side: .left, row: 0, index: 0), key: .down),
				.init(position: .init(side: .left, row: 0, index: 1), key: .up),
				.init(position: .init(side: .left, row: 0, index: 2), key: .space),
				.init(position: .init(side: .left, row: 1, index: 0), key: .q),
				.init(position: .init(side: .right, row: 0, index: 2), key: .tab),
				.init(position: .init(side: .right, row: 0, index: 1), key: .left),
				.init(position: .init(side: .right, row: 0, index: 0), key: .right),
				.init(position: .init(side: .right, row: 1, index: 1), key: .alt),
				.init(position: .init(side: .right, row: 1, index: 0), key: .cmd)
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
