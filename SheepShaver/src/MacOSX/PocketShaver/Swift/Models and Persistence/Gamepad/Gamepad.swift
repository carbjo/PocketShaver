//
//  Gamepad.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-28.
//

import UIKit

enum GamepadSide: Codable, Equatable, Hashable {
	case left
	case right
}

struct GamepadButtonPosition: Codable, Equatable, Hashable {
	let side: GamepadSide
	let row: Int
	let index: Int
}

enum GamepadButtonAssignment: Codable, Equatable, Hashable {
	case key(SDLKey)
	case specialButton(SpecialButton)
	case joystick(JoystickType)
}

struct GamepadButtonMapping: Codable, Equatable, Hashable {
	let position: GamepadButtonPosition
	let assignment: GamepadButtonAssignment
}

enum GamepadVisibilitySetting: Codable, Equatable, Hashable {
	case both
	case portraitOnly
	case landscapeOnly
}

struct GamepadSideButtonPosition: Codable, Equatable, Hashable {
	let layout: GamepadSideButtonLayout
	let index: Int
}

struct GamepadSideButtonMapping: Codable, Equatable, Hashable {
	let position: GamepadSideButtonPosition
	let assignment: GamepadButtonAssignment
}

enum GamepadConfigError: Error {
	case joystickHasNoLayoutSpace
	case joystickAtBottomRow
	case joystickAtRightEdge
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

extension GamepadConfig {
	static var emptyLayout: GamepadConfig {
		GamepadConfig(
			name: "Empty layout",
			mappings: [],
			visibilitySetting: .both
		)
	}

	static var exampleArcadeGameLayout: GamepadConfig {
		GamepadConfig(
			name: "Example arcade game layout",
			mappings: [
				.init(position: .init(side: .left, row: 0, index: 0), assignment: .key(.left)),
				.init(position: .init(side: .left, row: 0, index: 1), assignment: .key(.down)),
				.init(position: .init(side: .left, row: 0, index: 2), assignment: .key(.right)),
				.init(position: .init(side: .left, row: 1, index: 1), assignment: .key(.up)),
				.init(position: .init(side: .left, row: 3, index: 0), assignment: .key(.escape)),
				.init(position: .init(side: .right, row: 0, index: 1), assignment: .key(.a)),
				.init(position: .init(side: .right, row: 0, index: 0), assignment: .key(.b)),
				.init(position: .init(side: .right, row: 3, index: 0), assignment: .key(.enter))
			],
			visibilitySetting: .both
		)
	}

	static var exampleArcadeGameSideButtonLayout: GamepadConfig {
		GamepadConfig(
			name: "Example arcade game layout",
			mappings: [
				.init(position: .init(side: .left, row: 0, index: 0), assignment: .key(.left)),
				.init(position: .init(side: .left, row: 0, index: 1), assignment: .key(.down)),
				.init(position: .init(side: .left, row: 0, index: 2), assignment: .key(.right)),
				.init(position: .init(side: .left, row: 1, index: 1), assignment: .key(.up)),
				.init(position: .init(side: .right, row: 0, index: 1), assignment: .key(.a)),
				.init(position: .init(side: .right, row: 0, index: 0), assignment: .key(.b))
			],
			sideButtonMappings: [
				.init(position: .init(layout: .topLeft, index: 0), assignment: .key(.escape)),
				.init(position: .init(layout: .topRight, index: 0), assignment: .key(.enter))
			],
			visibilitySetting: .both
		)
	}

	static var exampleFpsGameLayout: GamepadConfig {
		GamepadConfig(
			name: "Example FPS game layout",
			mappings: [
				.init(position: .init(side: .left, row: 1, index: 0), assignment: .joystick(.wasd8way)),
				.init(position: .init(side: .left, row: 2, index: 0), assignment: .specialButton(.mouseClick)),
				.init(position: .init(side: .left, row: 3, index: 0), assignment: .key(.escape)),
				.init(position: .init(side: .right, row: 1, index: 1), assignment: .joystick(.mouse)),
				.init(position: .init(side: .right, row: 2, index: 0), assignment: .key(.space)),
				.init(position: .init(side: .right, row: 3, index: 0), assignment: .key(.enter))
			],
			visibilitySetting: .both
		)
	}

	static var exampleFpsGameSingleSideButtonLayout: GamepadConfig {
		GamepadConfig(
			name: "Example FPS game layout",
			mappings: [
				.init(position: .init(side: .left, row: 1, index: 0), assignment: .joystick(.wasd8way)),
				.init(position: .init(side: .left, row: 2, index: 0), assignment: .specialButton(.mouseClick)),
				.init(position: .init(side: .right, row: 1, index: 1), assignment: .joystick(.mouse)),
				.init(position: .init(side: .right, row: 2, index: 0), assignment: .key(.space))
			],
			sideButtonMappings: [
				.init(position: .init(layout: .topLeft, index: 0), assignment: .key(.escape)),
				.init(position: .init(layout: .topRight, index: 0), assignment: .specialButton(.relativeMouseModeEnabled)),
				.init(position: .init(layout: .bottomLeft, index: 0), assignment: .key(.enter)),
				.init(position: .init(layout: .bottomRight, index: 0), assignment: .key(.down))
			],
			visibilitySetting: .both
		)
	}

	static var exampleFpsGameDoubleSideButtonLayout: GamepadConfig {
		GamepadConfig(
			name: "Example FPS game layout",
			mappings: [
				.init(position: .init(side: .left, row: 1, index: 0), assignment: .joystick(.wasd8way)),
				.init(position: .init(side: .left, row: 2, index: 0), assignment: .specialButton(.mouseClick)),
				.init(position: .init(side: .right, row: 1, index: 1), assignment: .joystick(.mouse)),
				.init(position: .init(side: .right, row: 2, index: 0), assignment: .key(.space))
			],
			sideButtonMappings: [
				.init(position: .init(layout: .topLeft, index: 0), assignment: .key(.escape)),
				.init(position: .init(layout: .topLeft, index: 1), assignment: .specialButton(.relativeMouseModeEnabled)),
				.init(position: .init(layout: .topRight, index: 0), assignment: .key(.y)),
				.init(position: .init(layout: .topRight, index: 1), assignment: .key(.enter)),
				.init(position: .init(layout: .bottomLeft, index: 0), assignment: .key(.F1)),
				.init(position: .init(layout: .bottomRight, index: 0), assignment: .key(.right)),
				.init(position: .init(layout: .bottomRight, index: 1), assignment: .key(.down))
			],
			visibilitySetting: .both
		)
	}

	static var exampleRpgGameDoubleSideButtonLayout: GamepadConfig {
		GamepadConfig(
			name: "Example RPG game layout",
			mappings: [
				.init(position: .init(side: .left, row: 3, index: 0), assignment: .specialButton(.rightClick)),
				.init(position: .init(side: .right, row: 3, index: 0), assignment: .specialButton(.rightClick))
			],
			sideButtonMappings: [
				.init(position: .init(layout: .topLeft, index: 0), assignment: .key(.n1)),
				.init(position: .init(layout: .topLeft, index: 1), assignment: .key(.n2)),
				.init(position: .init(layout: .topRight, index: 0), assignment: .key(.n3)),
				.init(position: .init(layout: .topRight, index: 1), assignment: .key(.n4)),
				.init(position: .init(layout: .bottomLeft, index: 0), assignment: .key(.escape)),
				.init(position: .init(layout: .bottomLeft, index: 1), assignment: .key(.i)),
				.init(position: .init(layout: .bottomRight, index: 0), assignment: .key(.r)),
				.init(position: .init(layout: .bottomRight, index: 1), assignment: .key(.tab))
			],
			visibilitySetting: .landscapeOnly
		)
	}

	static var exampleRpgGameSingleSideButtonLayout: GamepadConfig {
		GamepadConfig(
			name: "Example RPG game layout",
			mappings: [
				.init(position: .init(side: .left, row: 3, index: 0), assignment: .specialButton(.rightClick)),
				.init(position: .init(side: .right, row: 3, index: 0), assignment: .specialButton(.rightClick))
			],
			sideButtonMappings: [
				.init(position: .init(layout: .topLeft, index: 0), assignment: .key(.n1)),
				.init(position: .init(layout: .topRight, index: 0), assignment: .key(.n2)),
				.init(position: .init(layout: .bottomLeft, index: 0), assignment: .key(.n3)),
				.init(position: .init(layout: .bottomRight, index: 0), assignment: .key(.n4))
			],
			visibilitySetting: .landscapeOnly
		)
	}
}
