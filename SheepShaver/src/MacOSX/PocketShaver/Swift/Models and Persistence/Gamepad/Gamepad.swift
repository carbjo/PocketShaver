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

struct GamepadSideButtonPosition: Codable, Equatable {
	let layout: GamepadSideButtonLayout
	let index: Int
}

struct GamepadSideButtonMapping: Codable, Equatable {
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
}
