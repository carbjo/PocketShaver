//
//  GamepadAssignButtonModel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-14.
//

import Foundation

enum GamepadAssignResult {
	case assignment(GamepadButtonAssignment)
	case unassign
	case cancel
}

struct GamepadAssignEntry {
	let identifier: String
	let assignment: GamepadButtonAssignment
}

class GamepadAssignButtonModel {
	private let originalList: [GamepadAssignEntry]
	private(set) var results: [GamepadAssignEntry]
	private(set) var searchString = ""

	init(
		gamepadButtonSize: GamepadButtonSize
	) {
		let joystick: [GamepadButtonAssignment]
		switch gamepadButtonSize {
		case .regular:
			joystick = [
				GamepadButtonAssignment.joystick(.mouse),
				GamepadButtonAssignment.joystick(.wasd4way),
				GamepadButtonAssignment.joystick(.wasd8way)
			]
		case .small:
			joystick = []
		}

		let specialKeys = SpecialButton.allCases.map({ GamepadButtonAssignment.specialButton($0) })
		let sdlKeys = SDLKey.allCases.map({ GamepadButtonAssignment.key($0) })
		originalList = (joystick + specialKeys + sdlKeys).map(GamepadAssignEntry.init) + alternativeNames
		results = originalList
	}

	func input(searchString: String) {
		self.searchString = searchString

		if searchString.isEmpty {
			results = originalList
			return
		}

		results = originalList
			.filter({ $0.identifier.lowercased().hasPrefix(searchString) })
			.sorted(by: { lhs, rhs in
				lhs.identifier.count < rhs.identifier.count
			})
	}
}

extension GamepadButtonAssignment {
	var identifier: String {
		switch self {
		case .key(let sdlKey):
			switch sdlKey {
			case .tab: return "Tab"
			case .enter: return "Enter"
			case .space: return "Space"
			case .backspace: return "Backspace"
			case .delete: return "Delete"
			case .shift: return "Shift"
			case .cmd: return "Cmd"
			case .capslock: return "Capslock"
			case .up: return "Up"
			case .down: return "Down"
			case .left: return "Left"
			case .right: return "Right"
			case .kp0: return "0 (keypad)"
			case .kp1: return "1 (keypad)"
			case .kp2: return "2 (keypad)"
			case .kp3: return "3 (keypad)"
			case .kp4: return "4 (keypad)"
			case .kp5: return "5 (keypad)"
			case .kp6: return "6 (keypad)"
			case .kp7: return "7 (keypad)"
			case .kp8: return "8 (keypad)"
			case .kp9: return "9 (keypad)"
			case .kpPeriod: return ". (keypad)"
			case .kpPlus: return "+ (keypad)"
			case .kpMinus: return "- (keypad)"
			case .kpMultiply: return "* (keypad)"
			case .kpDivide: return "/ (keypad)"
			case .kpEquals: return "= (keypad)"
			case .kpEnter: return "Enter (keypad)"
			case .paragraph: return "Paragraph"
			default:
				return sdlKey.label
			}
		case .specialButton(let specialButton):
			return specialButton.label
		case .joystick(let joystickType):
			switch joystickType {
			case .mouse:
				return "Joystick (mouse)"
			case .wasd4way:
				return "Joystick (WASD, 4-way)"
			case .wasd8way:
				return "Joystick (WASD, 8-way)"
			}
		}
	}

	var description: String {
		switch self {
		case .key:
			return "The key \(identifier)."
		case .specialButton(let specialButton):
			switch specialButton{
			case .hoverJustAboveToggle:
				return "Touch input hovers mouse cursor without clicking, offset slightly above the of the touch point. This makes content easier to interact with, while avoiding to obscure the content itelf with your finger. Recommended to use in combination with Second finger click functionality or a Mouse click gamepad button."
			case .hoverSidewaysToggle:
				return "Touch input hovers mouse cursor without clicking, offset sideways of the touch point. Sideways to the right if touch on the left side of the screen and vice versa. This makes content near the bottom of the screen on the opposite side easier to interact with, while avoiding to obscure the content itelf with your finger. Recommended to use in combination with Second finger click functionality or a Mouse click gamepad button."
			case .hoverFarAboveToggle:
				return "Touch input hovers mouse cursor without clicking, offset above the touch point. This makes content near the top of the screen easier to interact with, while avoiding to obscure the content itelf with your finger. Recommended to use in combination with Second finger click functionality or a Mouse click gamepad button."
			case .hoverDiagonallyToggle:
				return "Touch input hovers mouse cursor without clicking, offset diagnoally above the touch point. Diagnonally to the right if touch on the left side of the screen and vice versa. This makes content near the middle of the screen easier to interact with, while avoiding to obscure the content itelf with your finger. Recommended to use in combination with Second finger click functionality or a Mouse click gamepad button."
			case .mouseClick:
				return "Mouse click."
			case .cmdW:
				return "Key combination Cmd-W. For closing windows."
			case .rightClick:
				return "Click with right mouse button. Configure in Preferences what this means."
			}
		case .joystick(let joystickType):
			switch joystickType {
			case .mouse:
				return "Joystick emulating moving mouse. Only works in relative mouse mode (and games and apps that use that mode)."
			case .wasd4way:
				return "Joystick emulating pressing keys WASD. 4-directional (W, A, S, D)."
			case .wasd8way:
				return "Joystick emulating pressing keys WASD. 8-directional (W, WA, A, AS, S, SD, D, WD)."
			}
		}
	}
}

extension GamepadAssignEntry {
	init(_ buttonAssignment: GamepadButtonAssignment) {
		identifier = buttonAssignment.identifier
		self.assignment = buttonAssignment
	}
}

private let alternativeNames: [GamepadAssignEntry] = [
	.init(identifier: "Return", assignment: .key(.enter)),
	.init(identifier: "Blankspace", assignment: .key(.space)),
	.init(identifier: "Command", assignment: .key(.cmd)),
	.init(identifier: "Apple key", assignment: .key(.cmd)),
	.init(identifier: "Dot", assignment: .key(.kpPeriod)),
	.init(identifier: "Period", assignment: .key(.kpPeriod)),
	.init(identifier: "Plus", assignment: .key(.kpPlus)),
	.init(identifier: "Minus", assignment: .key(.kpMinus)),
	.init(identifier: "Star", assignment: .key(.kpMultiply)),
	.init(identifier: "Multiply", assignment: .key(.kpMultiply)),
	.init(identifier: "Slash", assignment: .key(.kpDivide)),
	.init(identifier: "Forwardslash", assignment: .key(.kpDivide)),
	.init(identifier: "Equals", assignment: .key(.kpEquals)),
	.init(identifier: "Control", assignment: .key(.ctrl)),
	.init(identifier: "Opt", assignment: .key(.alt)),
	.init(identifier: "Option", assignment: .key(.alt)),
	.init(identifier: "Escape", assignment: .key(.alt)),
	.init(identifier: "Scrollock", assignment: .key(.scrollock)),
	.init(identifier: "Less than", assignment: .key(.lessThan)),
	.init(identifier: "Click", assignment: .specialButton(.mouseClick)),
	.init(identifier: "Left click", assignment: .specialButton(.mouseClick)),
	.init(identifier: "Right mouse click", assignment: .specialButton(.mouseClick))
]
