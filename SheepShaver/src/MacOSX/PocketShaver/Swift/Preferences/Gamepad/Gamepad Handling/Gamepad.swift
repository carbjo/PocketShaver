//
//  Gamepad.swift
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
	case joystick(JoystickType)
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

enum GamepadConfigError: Error {
	case joystickHasNoLayoutSpace
	case joystickAtBottomRow
	case joystickAtRightEdge
}

class GamepadConfig: Codable {
	private(set) var name: String
	private(set) var mappings: [GamepadButtonMapping]
	private(set) var visibilitySetting: GamepadVisibilitySetting

	@MainActor
	func replace(with key: SDLKey, at position: GamepadButtonPosition) {
		removeAssignment(at: position)
		mappings.append(.init(position: position, assignment: .key(key)))

		saveChanges()
	}

	@MainActor
	func replace(with specialButton: SpecialButton, at position: GamepadButtonPosition) {
		removeAssignment(at: position)
		mappings.append(.init(position: position, assignment: .specialButton(specialButton)))

		saveChanges()
	}

	@MainActor
	func replace(with joystickType: JoystickType, at position: GamepadButtonPosition) throws {
		guard position.row != 0 else {
			throw GamepadConfigError.joystickAtBottomRow
		}
		if position.side == .right {
			guard position.index > 0 else {
				throw GamepadConfigError.joystickAtRightEdge
			}
		}
		let indexToTheRight = position.side == .left ? 1 : -1
		guard mappings.firstIndex(where: { $0.position == .init(side: position.side, row: position.row - 1, index: position.index) }) == nil,
		mappings.firstIndex(where: { $0.position == .init(side: position.side, row: position.row, index: position.index + indexToTheRight) }) == nil,
		mappings.firstIndex(where: { $0.position == .init(side: position.side, row: position.row - 1, index: position.index + indexToTheRight) }) == nil else {
			throw GamepadConfigError.joystickHasNoLayoutSpace
		}

		removeAssignment(at: position)
		mappings.append(.init(position: position, assignment: .joystick(joystickType)))

		saveChanges()
	}

	@MainActor
	func removeAssignment(at position: GamepadButtonPosition) {
		if let oldIndex = mappings.firstIndex(where: { $0.position == position }) {
			mappings.remove(at: oldIndex)
		}

		saveChanges()
	}

	@MainActor
	func set(name: String) {
		self.name = name

		saveChanges()
	}

	@MainActor
	func set(visibilitySetting: GamepadVisibilitySetting) {
		self.visibilitySetting = visibilitySetting

		GamepadManager.shared.updateIndicesForVisibility()
	}

	@MainActor
	func saveAsCurrent() {
		GamepadManager.shared.setAsCurrentConfig(self)
	}

	@MainActor
	private func saveChanges() {
		if name == Self.exampleLayoutName {
			name = "Saved Layout"
		}

		GamepadManager.shared.save(self)
	}

	private static let exampleLayoutName = "Example layout"

	fileprivate init() {
		name = Self.exampleLayoutName
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

private class GamepadSettings: Codable {
	var portraitConfigIndex: Int
	var landscapeConfigIndex: Int
	var configurations: [GamepadConfig]

	init() {
		portraitConfigIndex = 0
		landscapeConfigIndex = 0
		configurations = []
	}

	@MainActor
	func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .gamepad)
		} catch {}
	}
}

@MainActor
class GamepadManager {

	static let shared = GamepadManager()

	private var beginningExampleLayoutConfig = GamepadConfig()
	private var endExampleLayoutConfig = GamepadConfig()

	private lazy var settings: GamepadSettings = {
		guard let data = Storage.shared.load(from: .gamepad),
			  let settings = try? JSONDecoder().decode(GamepadSettings.self, from: data) else {
			return GamepadSettings()
		}

		return settings
	}()

	private var portraitConfig: GamepadConfig {
		if settings.portraitConfigIndex < 0 {
			return beginningExampleLayoutConfig
		} else if settings.portraitConfigIndex >= settings.configurations.count {
			return endExampleLayoutConfig
		} else {
			return settings.configurations[settings.portraitConfigIndex]
		}
	}

	private var landscapeConfig: GamepadConfig {
		if settings.landscapeConfigIndex < 0 {
			return beginningExampleLayoutConfig
		} else if settings.landscapeConfigIndex >= settings.configurations.count {
			return endExampleLayoutConfig
		} else {
			return settings.configurations[settings.landscapeConfigIndex]
		}
	}

	var config: GamepadConfig {
		if UIScreen.isPortraitMode {
			portraitConfig
		} else {
			landscapeConfig
		}
	}

	var nextConfig: GamepadConfig {
		if UIScreen.isPortraitMode {
			return savedConfigAfterIndexMatching(settings.portraitConfigIndex) { config in
				config.visibilitySetting != .landscapeOnly
			} ?? endExampleLayoutConfig
		} else {
			return savedConfigAfterIndexMatching(settings.landscapeConfigIndex) { config in
				config.visibilitySetting != .portraitOnly
			} ?? endExampleLayoutConfig
		}
	}

	var previousConfig: GamepadConfig {
		if UIScreen.isPortraitMode {
			return savedConfigBeforeIndexMatching(settings.portraitConfigIndex) { config in
				config.visibilitySetting != .landscapeOnly
			} ?? beginningExampleLayoutConfig
		} else {
			return savedConfigBeforeIndexMatching(settings.landscapeConfigIndex) { config in
				config.visibilitySetting != .portraitOnly
			} ?? beginningExampleLayoutConfig
		}
	}

	var allConfigs: [GamepadConfig] {
		settings.configurations
	}

	func move(from: Int, to: Int) {
		modifyAndRetainIndices {
			let entry = settings.configurations.remove(at: from)
			settings.configurations.insert(entry, at: to)
		}

		saveChanges()
	}

	func remove(at index: Int) {
		modifyAndRetainIndices {
			settings.configurations.remove(at: index)
		}

		saveChanges()
	}

	func updateIndicesForVisibility() {
		let currentProfileConfig = settings.configurations[settings.portraitConfigIndex]
		let currentLandscapeConfig = settings.configurations[settings.landscapeConfigIndex]

		if currentProfileConfig.visibilitySetting == .landscapeOnly {
			let matchFunction: ((GamepadConfig) -> Bool) = { config in
				config.visibilitySetting == .both || config.visibilitySetting == .portraitOnly
			}
			if let validConfigBefore = savedConfigBeforeIndexMatching(settings.portraitConfigIndex, matchFunction: matchFunction) {
				settings.portraitConfigIndex = settings.configurations.firstIndex(where: { $0 === validConfigBefore })!
			} else if let validConfigAfter = savedConfigAfterIndexMatching(settings.portraitConfigIndex, matchFunction: matchFunction) {
				settings.portraitConfigIndex = settings.configurations.firstIndex(where: { $0 === validConfigAfter })!
			} else {
				settings.portraitConfigIndex = -1
			}
		}

		if currentLandscapeConfig.visibilitySetting == .portraitOnly {
			let matchFunction: ((GamepadConfig) -> Bool) = { config in
				config.visibilitySetting == .both || config.visibilitySetting == .landscapeOnly
			}
			if let validConfigBefore = savedConfigBeforeIndexMatching(settings.landscapeConfigIndex, matchFunction: matchFunction) {
				settings.landscapeConfigIndex = settings.configurations.firstIndex(where: { $0 === validConfigBefore })!
			} else if let validConfigAfter = savedConfigAfterIndexMatching(settings.landscapeConfigIndex, matchFunction: matchFunction) {
				settings.landscapeConfigIndex = settings.configurations.firstIndex(where: { $0 === validConfigAfter })!
			} else {
				settings.landscapeConfigIndex = -1
			}
		}

		saveChanges()
	}

	fileprivate func save(_ config: GamepadConfig) {
		if config === beginningExampleLayoutConfig {
			modifyAndRetainIndices {
				settings.configurations.insert(beginningExampleLayoutConfig, at: 0)
				beginningExampleLayoutConfig = GamepadConfig()
			}
		} else if config === endExampleLayoutConfig {
			modifyAndRetainIndices {
				settings.configurations.append(endExampleLayoutConfig)
				endExampleLayoutConfig = GamepadConfig()
			}
		} else {
			guard settings.configurations.contains(where: { $0 === config }) else {
				assert(false) // Should never happen
				return
			}
		}

		saveChanges()
	}

	private func saveChanges() {
		settings.saveAsCurrent()
	}

	fileprivate func setAsCurrentConfig(_ config: GamepadConfig) {
		let index: Int
		if config === beginningExampleLayoutConfig {
			index = -1
		} else if config === endExampleLayoutConfig {
			index = settings.configurations.count
		} else if let configurationArrayIndex = settings.configurations.firstIndex(where: { $0 === config }) {
			index = configurationArrayIndex
		} else {
			assert(false) // Should never happen
			return
		}

		if UIScreen.isPortraitMode {
			settings.portraitConfigIndex = index
		} else {
			settings.landscapeConfigIndex = index
		}

		saveChanges()
	}

	private func savedConfigBeforeIndexMatching(_ referenceIndex: Int, matchFunction: ((GamepadConfig) -> Bool)) -> GamepadConfig? {
		for index in stride(from: referenceIndex - 1, to: -1, by: -1) {
			let config = settings.configurations[index]
			if matchFunction(config) {
				return config
			}
		}
		return nil
	}

	private func savedConfigAfterIndexMatching(_ referenceIndex: Int, matchFunction: ((GamepadConfig) -> Bool)) -> GamepadConfig? {
		for index in stride(from: referenceIndex + 1, to: settings.configurations.count, by: 1) {
			let config = settings.configurations[index]
			if matchFunction(config) {
				return config
			}
		}
		return nil
	}

	private func isExampleConfig(_ config: GamepadConfig) -> Bool {
		config === beginningExampleLayoutConfig || config === endExampleLayoutConfig
	}

	private func modifyAndRetainIndices(_ block: () -> Void) {
		let portraitConfig = portraitConfig
		let landscapeConfig = landscapeConfig

		block()

		if !isExampleConfig(portraitConfig),
		let newPortraitConfigIndex = settings.configurations.firstIndex(where: { $0 === portraitConfig }) {
			settings.portraitConfigIndex = newPortraitConfigIndex
		}

		if !isExampleConfig(landscapeConfig),
		   let newLandscapeConfigIndex = settings.configurations.firstIndex(where: { $0 === landscapeConfig }) {
			settings.landscapeConfigIndex = newLandscapeConfigIndex
		}
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
