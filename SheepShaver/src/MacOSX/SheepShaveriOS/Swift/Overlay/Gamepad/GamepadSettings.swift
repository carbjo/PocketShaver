//
//  GamepadConfig.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-28.
//

import UIKit

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

enum GamepadVisibilitySetting: Codable, Equatable {
	case both
	case portraitOnly
	case landscapeOnly
}

struct GamepadConfig: Codable, Equatable {
	let name: String
	let mappings: [GamepadButtonMapping]
	let visibilitySetting: GamepadVisibilitySetting

	init(
		name: String,
		mappings: [GamepadButtonMapping],
		visibilitySetting: GamepadVisibilitySetting
	) {
		self.name = (name == Self.exampleConfig.name) ? "Saved layout" : name
		self.mappings = mappings
		self.visibilitySetting = visibilitySetting
	}

	func replacing(with key: SDLKey, at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = removingAssignment(at: position).mappings
		assignments.append(.init(position: position, assignment: .key(key)))

		return .init(
			name: name,
			mappings: assignments,
			visibilitySetting: visibilitySetting
		)
	}

	func replacing(with specialButton: SpecialButton, at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = removingAssignment(at: position).mappings
		assignments.append(.init(position: position, assignment: .specialButton(specialButton)))

		return .init(
			name: name,
			mappings: assignments,
			visibilitySetting: visibilitySetting
		)
	}

	func removingAssignment(at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = mappings
		if let oldIndex = assignments.firstIndex(where: { $0.position == position }) {
			assignments.remove(at: oldIndex)
		}

		return .init(
			name: name,
			mappings: assignments,
			visibilitySetting: visibilitySetting
		)
	}

	func renaming(_ newName: String) -> GamepadConfig {
		.init(
			name: newName,
			mappings: mappings,
			visibilitySetting: visibilitySetting
		)
	}

	func withVisbility(_ newVisiblitySetting: GamepadVisibilitySetting) -> GamepadConfig {
		.init(
			name: name,
			mappings: mappings,
			visibilitySetting: newVisiblitySetting
		)
	}

	static var exampleConfig: GamepadConfig {
		GamepadConfig()
	}

	private init() {
		name = "Example layout"
		mappings = [
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
		visibilitySetting = .both
	}
}

struct GamepadSettings: Codable {
	let currentPortraitConfigIndex: Int
	let currentLandscapeConfigIndex: Int
	let configurations: [GamepadConfig]

	@MainActor
	var currentConfigIndex: Int {
		if UIScreen.isPortraitMode {
			currentPortraitConfigIndex
		} else {
			currentLandscapeConfigIndex
		}
	}

	@MainActor
	static var current: GamepadSettings {
		
		if let data = Storage.shared.load(from: .gamepad),
		   let settings = try? JSONDecoder().decode(Self.self, from: data) {

			if settings.config.visibilitySetting == .landscapeOnly && UIScreen.isPortraitMode {
				if let compatibleConfigIndex = settings.configurations.firstIndex(where: { $0.visibilitySetting == .both || $0.visibilitySetting == .portraitOnly }) {
					return .init(
						currentPortraitConfigIndex: compatibleConfigIndex,
						currentLandscapeConfigIndex: settings.currentLandscapeConfigIndex,
						configurations: settings.configurations
					)
				} else {
					return .init(
						currentPortraitConfigIndex: 0,
						currentLandscapeConfigIndex: settings.currentLandscapeConfigIndex,
						configurations: settings.configurations
					)
				}
			} else if settings.config.visibilitySetting == .portraitOnly && !UIScreen.isPortraitMode {
				if let compatibleConfigIndex = settings.configurations.firstIndex(where: { $0.visibilitySetting == .both || $0.visibilitySetting == .landscapeOnly }) {
					return .init(
						currentPortraitConfigIndex: settings.currentPortraitConfigIndex,
						currentLandscapeConfigIndex: compatibleConfigIndex,
						configurations: settings.configurations
					)
				} else {
					return .init(
						currentPortraitConfigIndex: settings.currentPortraitConfigIndex,
						currentLandscapeConfigIndex: 0,
						configurations: settings.configurations
					)
				}
			}

			return settings
		}

		return .init(currentPortraitConfigIndex: 0, currentLandscapeConfigIndex: 0, configurations: [])
	}

	@MainActor
	var previoius: GamepadSettings {
		if currentConfigIndex == -1 {
			return self
		}

		let isPortrait = UIScreen.isPortraitMode

		let previous = GamepadSettings(
			currentPortraitConfigIndex: currentPortraitConfigIndex - (isPortrait ? 1 : 0),
			currentLandscapeConfigIndex: currentLandscapeConfigIndex - (isPortrait ? 0 : 1),
			configurations: configurations
		)

		if (isPortrait && previous.config.visibilitySetting == .landscapeOnly) ||
			(!isPortrait && previous.config.visibilitySetting == .portraitOnly) {
			// Keep searching recursively
			return previous.previoius
		}

		return previous
	}

	@MainActor
	var next: GamepadSettings {
		if currentConfigIndex == configurations.count {
			return self
		}

		let isPortrait = UIScreen.isPortraitMode

		let next = GamepadSettings(
			currentPortraitConfigIndex: currentPortraitConfigIndex + (isPortrait ? 1 : 0),
			currentLandscapeConfigIndex: currentLandscapeConfigIndex + (isPortrait ? 0 : 1),
			configurations: configurations
		)

		if (isPortrait && next.config.visibilitySetting == .landscapeOnly) ||
			(!isPortrait && next.config.visibilitySetting == .portraitOnly) {
			// Keep searching recursively
			return next.next
		}

		return next
	}

	@MainActor
	var config: GamepadConfig {
		if currentConfigIndex >= 0,
		   currentConfigIndex < configurations.count {
			return configurations[currentConfigIndex]
		} else {
			return .exampleConfig
		}
	}

	@MainActor @discardableResult
	func move(from: Int, to: Int) -> GamepadSettings {
		let gamepadSettings = moving(from: from, to: to)
		gamepadSettings.saveAsCurrent()
		return gamepadSettings
	}

	@MainActor @discardableResult
	func replaceCurrentConfig(with config: GamepadConfig) -> GamepadSettings {
		let gamepadSettings = replacingCurrentConfig(with: config)
		gamepadSettings.saveAsCurrent()
		return gamepadSettings
	}

	@MainActor @discardableResult
	func replace(_ config: GamepadConfig, with newConfig: GamepadConfig) -> GamepadSettings {
		let gamepadSettings = replacing(config, with: newConfig)
		gamepadSettings.saveAsCurrent()
		return gamepadSettings
	}

	@MainActor @discardableResult
	func remove(at index: Int) -> GamepadSettings {
		let gamepadSettings = removing(at: index)
		gamepadSettings.saveAsCurrent()
		return gamepadSettings
	}

	@MainActor
	func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .gamepad)
		} catch {}
	}

	@MainActor
	private func moving(from: Int, to: Int) -> GamepadSettings {
		var enumeratedConfigurations = configurations.enumerated().map({ ($0,$1) })
		let originalCurrentPortraitConfigIndex = currentPortraitConfigIndex
		let originalCurrentLandscapeConfigIndex = currentLandscapeConfigIndex

		let entry = enumeratedConfigurations.remove(at: from)
		enumeratedConfigurations.insert(entry, at: to)

		let currentPortraitConfigIndex = enumeratedConfigurations.firstIndex(where: { $0.0 == originalCurrentPortraitConfigIndex })!
		let currentLandscapeConfigIndex = enumeratedConfigurations.firstIndex(where: { $0.0 == originalCurrentLandscapeConfigIndex })!
		let configurations = enumeratedConfigurations.map({ $1 })

		return .init(
			currentPortraitConfigIndex: currentPortraitConfigIndex,
			currentLandscapeConfigIndex: currentLandscapeConfigIndex,
			configurations: configurations
		)
	}

	private func replacing(_ config: GamepadConfig, with newConfig: GamepadConfig) -> GamepadSettings {
		guard let configIndex = configurations.firstIndex(where: { $0 == config }) else {
			return self
		}

		var configurations = configurations
		configurations.remove(at: configIndex)
		configurations.insert(newConfig, at: configIndex)

		return .init(
			currentPortraitConfigIndex: currentPortraitConfigIndex,
			currentLandscapeConfigIndex: currentLandscapeConfigIndex,
			configurations: configurations
		)
	}

	@MainActor
	private func replacingCurrentConfig(with config: GamepadConfig) -> GamepadSettings {
		guard config != .exampleConfig else {
			return self
		}

		let isPortrait = UIScreen.isPortraitMode

		var configurations = configurations
		if currentConfigIndex == -1 {
			// Save as new layout in the beginning of the array
			configurations.insert(config, at: 0)

			if isPortrait {
				return .init(
					currentPortraitConfigIndex: -1,
					currentLandscapeConfigIndex: currentLandscapeConfigIndex + 1,
					configurations: configurations
				)
			} else {
				return .init(
					currentPortraitConfigIndex: currentPortraitConfigIndex + 1,
					currentLandscapeConfigIndex: -1,
					configurations: configurations
				)
			}
		} else if currentConfigIndex == configurations.count {
			// Save as new layout in the end of the array
			configurations.append(config)

			if isPortrait {
				return .init(
					currentPortraitConfigIndex: configurations.count - 1,
					currentLandscapeConfigIndex: currentLandscapeConfigIndex,
					configurations: configurations
				)
			} else {
				return .init(
					currentPortraitConfigIndex: currentPortraitConfigIndex,
					currentLandscapeConfigIndex: configurations.count - 1,
					configurations: configurations
				)
			}
		} else {
			// Changed a previously saved layout
			configurations[currentConfigIndex] = config

			return .init(
				currentPortraitConfigIndex: currentPortraitConfigIndex,
				currentLandscapeConfigIndex: currentLandscapeConfigIndex,
				configurations: configurations
			)
		}
	}

	@MainActor
	private func removing(at index: Int) -> GamepadSettings {
		let currentPortraitConfigIndex: Int

		if GamepadSettings.current.currentPortraitConfigIndex <= 0 {
			currentPortraitConfigIndex = GamepadSettings.current.currentPortraitConfigIndex
		} else if index < GamepadSettings.current.currentPortraitConfigIndex {
			currentPortraitConfigIndex = index
		} else {
			currentPortraitConfigIndex = index - 1
		}

		let currentLandscapeConfigIndex: Int
		if GamepadSettings.current.currentLandscapeConfigIndex <= 0 {
			currentLandscapeConfigIndex = GamepadSettings.current.currentLandscapeConfigIndex
		} else if index < GamepadSettings.current.currentLandscapeConfigIndex {
			currentLandscapeConfigIndex = index
		} else {
			currentLandscapeConfigIndex = index - 1
		}

		var configurations = GamepadSettings.current.configurations
		configurations.remove(at: index)

		return .init(
			currentPortraitConfigIndex: currentPortraitConfigIndex,
			currentLandscapeConfigIndex: currentLandscapeConfigIndex,
			configurations: configurations
		)
	}
}

extension GamepadVisibilitySetting {
	var label: String {
		switch self {
		case .both:
			"Both modes"
		case .portraitOnly:
			"Portrait only"
		case .landscapeOnly:
			"Landscape only"
		}
	}
}
