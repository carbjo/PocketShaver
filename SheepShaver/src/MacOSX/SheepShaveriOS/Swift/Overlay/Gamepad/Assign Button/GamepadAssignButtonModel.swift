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

class GamepadAssignButtonModel {
	private let originalList: [GamepadButtonAssignment]
	private(set) var results: [GamepadButtonAssignment]
	private(set) var searchString = ""

	init() {
		let specialKeys = SpecialButton.allCases.map({ GamepadButtonAssignment.specialButton($0) })
		let sdlKeys = SDLKey.allCases.map({ GamepadButtonAssignment.key($0) })
		originalList = specialKeys + sdlKeys
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
			case .tab: return "TAB"
			case .return: return "RETURN"
			case .backspace: return "BACKSPACE"
			case .delete: return "DELETE"
			case .shift: return "SHIFT"
			case .cmd: return "CMD"
			case .capslock: return "CAPSLOCK"
			case .up: return "UP"
			case .down: return "DOWN"
			case .left: return "LEFT"
			case .right: return "RIGHT"
			case .kp0: return "0 (KEYPAD)"
			case .kp1: return "1 (KEYPAD)"
			case .kp2: return "2 (KEYPAD)"
			case .kp3: return "3 (KEYPAD)"
			case .kp4: return "4 (KEYPAD)"
			case .kp5: return "5 (KEYPAD)"
			case .kp6: return "6 (KEYPAD)"
			case .kp7: return "7 (KEYPAD)"
			case .kp8: return "8 (KEYPAD)"
			case .kp9: return "9 (KEYPAD)"
			case .kpPeriod: return ". (KEYPAD)"
			case .kpPlus: return "+ (KEYPAD)"
			case .kpMinus: return "- (KEYPAD)"
			case .kpMultiply: return "* (KEYPAD)"
			case .kpDivide: return "/ (KEYPAD)"
			case .kpEquals: return "= (KEYPAD)"
			case .kpEnter: return "ENTER (KEYPAD)"
			case .paragraph: return "PARAGRAPH"
			default:
				return sdlKey.label
			}
		case .specialButton(let specialButton):
			switch specialButton {
			case .hover:
				return "Hover"
			case .hoverAbove:
				return "Hover above"
			case .hoverBelow:
				return "Hover below"
			}
		}
	}

	var description: String {
		switch self {
		case .key:
			return "The key \(identifier)."
		case .specialButton(let specialButton):
			switch specialButton{
			case .hover:
				return "Touch input hovers mouse cursor without clicking. Hold button while using (not a toggle)."
			case .hoverAbove:
				return "Touch input hovers mouse cursor without clicking, offset above the touch point, for visibility. Hold button while using (not a toggle)."
			case .hoverBelow:
				return "Touch input hovers mouse cursor without clicking, offset below the touch point, for visibility. Hold button while using (not a toggle)."
			}
		}
	}
}
