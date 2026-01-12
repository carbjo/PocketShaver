//
//  SpecialButton.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-02.
//

import Foundation

@objc public enum SpecialButton: Int, Codable, CaseIterable {
	case hover
	case hoverAbove
	case hoverBelow
	case mouseClick
	case cmdW
	case hoverDiagonallyToggle
	case hoverSidewaysToggle
	case hoverAboveToggle
	case rightClick

	var label: String {
		switch self {
		case .hover: return "Hover"
		case .hoverAbove: return "Hover above"
		case .hoverBelow: return "Hover below"
		case .hoverDiagonallyToggle: return "Hover diagonally (toggle)"
		case .mouseClick: return "Mouse click"
		case .cmdW: return "Cmd-W"
		case .hoverSidewaysToggle: return "Hover sideways (toggle)"
		case .hoverAboveToggle: return "Hover above (toggle)"
		case .rightClick: return "Right click"
		}
	}
}
