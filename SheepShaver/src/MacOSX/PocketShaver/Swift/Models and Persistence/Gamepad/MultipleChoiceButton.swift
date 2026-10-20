//
//  MultipleChoiceButton.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-10-10.
//

import Foundation

struct SelectionWheelButtonConfig: Codable, Equatable, Hashable {
	let buttonName: String
	let assignments: [SelectionWheelButtonAssignment]
}

enum SelectionWheelButtonAssignment: Codable, Equatable, Hashable {
	case sdlKey(SDLKey)
	case specialButton(SpecialButton)

	var label: String {
		switch self {
		case .sdlKey(let sdlKey):
			sdlKey.label
		case .specialButton(let specialButton):
			specialButton.label
		}
	}
}
