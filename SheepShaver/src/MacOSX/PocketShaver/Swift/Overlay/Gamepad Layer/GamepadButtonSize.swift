//
//  GamepadButtonSize.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-27.
//

import UIKit

enum GamepadButtonSize {
	case regular
	case small

	@MainActor
	var length: CGFloat {
		if self == .small {
			return 44
		}
		if UIScreen.isSESize {
			return 65
		}
		if UIScreen.isSmallSize {
			return 76
		}
		if UIScreen.isPortraitMode {
			return 78
		}
		return 80
	}
}
