//
//  GamepadManager.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-09.
//

import UIKit

class GamepadConfig: Codable {
	private(set) var name: String
	private(set) var mappings: [GamepadButtonMapping]
	private(set) var sideButtonMappings: [GamepadSideButtonMapping]?
	private(set) var visibilitySetting: GamepadVisibilitySetting


	// MARK: Main buttons

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

	// MARK: Side buttons

	@MainActor
	func replace(with key: SDLKey, at position: GamepadSideButtonPosition) {
		removeAssignment(at: position)
		if sideButtonMappings == nil {
			sideButtonMappings = []
		}
		sideButtonMappings!.append(.init(position: position, assignment: .key(key)))

		saveChanges()
	}

	@MainActor
	func replace(with specialButton: SpecialButton, at position: GamepadSideButtonPosition) {
		removeAssignment(at: position)
		if sideButtonMappings == nil {
			sideButtonMappings = []
		}
		sideButtonMappings!.append(.init(position: position, assignment: .specialButton(specialButton)))

		saveChanges()
	}

	@MainActor
	func removeAssignment(at position: GamepadSideButtonPosition) {
		guard let sideButtonMappings else {
			return
		}

		if let oldIndex = sideButtonMappings.firstIndex(where: { $0.position == position }) {
			self.sideButtonMappings!.remove(at: oldIndex)
		}

		saveChanges()
	}

	// MARK: Config

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
	func updateSlotPositionsIfNeeded() -> Bool {
		guard let sideButtonMappings else {
			// Nothing needs updating
			return false
		}

		var didPerformChanges = false

		for layout in GamepadSideButtonLayout.allCases {
			let firstIndexPosition = GamepadSideButtonPosition(
				layout: layout,
				index: 0
			)
			let secondIndexPosition = GamepadSideButtonPosition(
				layout: layout,
				index: 1
			)
			if let secondIndex = sideButtonMappings.firstIndex(where: { $0.position == secondIndexPosition }),
			   sideButtonMappings.firstIndex(where: { $0.position == firstIndexPosition }) == nil {
				let assigment = sideButtonMappings[secondIndex].assignment
				removeAssignment(at: secondIndexPosition)

				let newMapping = GamepadSideButtonMapping(
					position: firstIndexPosition,
					assignment: assigment
				)
				self.sideButtonMappings!.append(newMapping)

				didPerformChanges = true
			}
		}

		return didPerformChanges
	}

	@MainActor
	func saveAsCurrent() {
		GamepadManager.shared.setAsCurrentConfig(self)
	}

	@MainActor
	private func saveChanges() {
		if name == Self.emptyLayout.name {
			name = "Saved Layout"
		}

		GamepadManager.shared.save(self)
	}

	init(
		name: String,
		mappings: [GamepadButtonMapping],
		sideButtonMappings: [GamepadSideButtonMapping]? = nil,
		visibilitySetting: GamepadVisibilitySetting
	) {
		self.name = name
		self.mappings = mappings
		self.sideButtonMappings = sideButtonMappings
		self.visibilitySetting = visibilitySetting
	}
}

private class GamepadSettings: Codable {
	var portraitConfigIndex: Int
	var landscapeConfigIndex: Int
	var configurations: [GamepadConfig]

	@MainActor
	init() {
		portraitConfigIndex = 0
		landscapeConfigIndex = 0

		switch SideButtonAvailability.value {
		case .none:
			configurations = [
				.exampleArcadeGameLayout,
				.exampleFpsGameLayout
			]
		case .single:
			configurations = [
				.exampleArcadeGameSideButtonLayout,
				.exampleRpgGameSingleSideButtonLayout
			]
		case .double:
			configurations = [
				.exampleArcadeGameSideButtonLayout,
				.exampleRpgGameDoubleSideButtonLayout,
				.exampleFpsGameDoubleSideButtonLayout
			]
		}
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

	private var beginningEmptyLayoutConfig = GamepadConfig.emptyLayout
	private var endEmptyLayoutConfig = GamepadConfig.emptyLayout

	private lazy var settings: GamepadSettings = {
		guard let data = Storage.shared.load(from: .gamepad),
			  let settings = try? JSONDecoder().decode(GamepadSettings.self, from: data) else {
			return GamepadSettings()
		}

		return settings
	}()

	private var portraitConfig: GamepadConfig {
		if settings.portraitConfigIndex < 0 {
			return beginningEmptyLayoutConfig
		} else if settings.portraitConfigIndex >= settings.configurations.count {
			return endEmptyLayoutConfig
		} else {
			return settings.configurations[settings.portraitConfigIndex]
		}
	}

	private var landscapeConfig: GamepadConfig {
		if settings.landscapeConfigIndex < 0 {
			return beginningEmptyLayoutConfig
		} else if settings.landscapeConfigIndex >= settings.configurations.count {
			return endEmptyLayoutConfig
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
			} ?? endEmptyLayoutConfig
		} else {
			return savedConfigAfterIndexMatching(settings.landscapeConfigIndex) { config in
				config.visibilitySetting != .portraitOnly
			} ?? endEmptyLayoutConfig
		}
	}

	var previousConfig: GamepadConfig {
		if UIScreen.isPortraitMode {
			return savedConfigBeforeIndexMatching(settings.portraitConfigIndex) { config in
				config.visibilitySetting != .landscapeOnly
			} ?? beginningEmptyLayoutConfig
		} else {
			return savedConfigBeforeIndexMatching(settings.landscapeConfigIndex) { config in
				config.visibilitySetting != .portraitOnly
			} ?? beginningEmptyLayoutConfig
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
		if config === beginningEmptyLayoutConfig {
			modifyAndRetainIndices {
				settings.configurations.insert(beginningEmptyLayoutConfig, at: 0)
				beginningEmptyLayoutConfig = GamepadConfig.emptyLayout
			}
		} else if config === endEmptyLayoutConfig {
			modifyAndRetainIndices {
				settings.configurations.append(endEmptyLayoutConfig)
				endEmptyLayoutConfig = GamepadConfig.emptyLayout
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
		if config === beginningEmptyLayoutConfig {
			index = -1
		} else if config === endEmptyLayoutConfig {
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
		config === beginningEmptyLayoutConfig || config === endEmptyLayoutConfig
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

fileprivate enum SideButtonAvailability {
	case none
	case single
	case double

	@MainActor
	static var value: Self {
		let isSideButtonLayoutSupported = UIScreen.hasNotch && !UIDevice.isIPad
		if isSideButtonLayoutSupported {
			let hasDoubleSlots = GamepadSideButtonLayout.layoutBasis.numberOfSlots > 1
			return hasDoubleSlots ? .double : .single
		} else {
			return .none
		}
	}
}
