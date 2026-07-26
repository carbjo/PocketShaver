//
//  SpecialButton.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-02.
//

import Foundation

enum SpecialButton: String, Codable, CaseIterable {
	case mouseClick
	case rightClick
	case cmdW
	case hoverJustAboveToggle
	case hoverDiagonallyToggle
	case hoverSidewaysToggle
	case hoverFarAboveToggle
	case audioEnabled
	case relativeMouseModeEnabled
	case copyClipboardHostToGuest
	case copyClipboardGuestToHost

	var label: String {
		switch self {
		case .hoverJustAboveToggle: "Hover just above (toggle)"
		case .hoverFarAboveToggle: "Hover far above (toggle)"
		case .hoverSidewaysToggle: "Hover sideways (toggle)"
		case .hoverDiagonallyToggle: "Hover diagonally (toggle)"
		case .mouseClick: "Mouse click"
		case .cmdW: "Cmd-W"
		case .rightClick: "Right click"
		case .audioEnabled: "Audio enabled"
		case .relativeMouseModeEnabled: "Relative mouse mode enabled (toggle)"
		case .copyClipboardHostToGuest: "Copy iOS clipboard to Classic Mac OS"
		case .copyClipboardGuestToHost: "Copy Classic Mac OS clipboard to iOS"
		}
	}
}

extension SpecialButton { // Temporary, to avoid breaking change when migrating from build <= 8
	enum OldKey: Int {
		case hover
		case hoverAbove
		case hoverBelow
		case mouseClick
	}

	init(from decoder: any Decoder) throws {
		let contanier = try decoder.singleValueContainer()

		if let contanier = try? decoder.singleValueContainer(),
		   let intValue = try? contanier.decode(Int.self),
		   let buttonType = OldKey(rawValue: intValue) {
			// This SpecialButton was defined in old system. Migrate.
			switch buttonType {
			case .hover:
				self = .hoverJustAboveToggle
			case .hoverAbove:
				self = .hoverFarAboveToggle
			case .hoverBelow:
				self = .hoverSidewaysToggle
			case .mouseClick:
				self = .mouseClick
			}
			return
		}

		let stringValue = try contanier.decode(String.self)
		guard let decodedCase = SpecialButton(rawValue: stringValue) else {
			throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: decoder.codingPath.debugDescription))
		}
		self = decodedCase
	}
}
