//
//  GamepadSideButtonConfiguration.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-29.
//

import UIKit

@MainActor
enum GamepadSideButtonLayout: String, Codable, CaseIterable {
	case topLeft
	case bottomLeft
	case topRight
	case bottomRight

	struct LayoutBasis {
		let verticalDistance: CGFloat
		let spacing: CGFloat
		let numberOfSlots: Int
	}

	static var isSupported: Bool {
		if UIDevice.isIPadIdiom {
			return false
		}
		if !UIScreen.hasNotch {
			return false
		}
		return true
	}

	static var isAvailable: Bool {
		isSupported && !UIScreen.isPortraitMode
	}

	var centerXOffset: CGFloat {
		let safeAreaInset: CGFloat
		if UIApplication.safeAreaInsets.left > 0 {
			safeAreaInset = UIApplication.safeAreaInsets.left
		} else {
			// Thumbnail mode
			safeAreaInset = 62
		}
		let sideMargin: CGFloat = UIScreen.sideMarginForButtons
		let offsetToNormalButtons = safeAreaInset + sideMargin
		let offset = offsetToNormalButtons / 2

		switch self {
		case .topLeft, .bottomLeft:
			return offset
		case .topRight, .bottomRight:
			return -offset
		}
	}

	var centerYOffset: CGFloat {
		switch self {
		case .topLeft, .topRight:
			return Self.layoutBasis.verticalDistance
		case .bottomLeft, .bottomRight:
			return -Self.layoutBasis.verticalDistance
		}
	}

	static var numberOfSlots: Int {
		Self.topLeft.numberOfSlots
	}

	var numberOfSlots: Int {
		guard Self.isSupported else {
			return 0
		}
		return Self.layoutBasis.numberOfSlots
	}

	var spacing: CGFloat {
		return Self.layoutBasis.spacing
	}
}

extension GamepadSideButtonLayout {
	@MainActor
	static var layoutBasis: LayoutBasis {
		let screenHeight: CGFloat = UIScreen.landscapeModeSize.height

		let modelName = UIDevice.modelName.replacingOccurrences(of: "Simulator ", with: "")

		switch modelName {
		case "iPhone X",
			"iPhone XR", "iPhone XS", "iPhone XS Max",
			"iPhone 11", "iPhone 11 Pro", "iPhone 11 Pro Max",
			"iPhone 12", "iPhone 12 Pro", "iPhone 12 Pro Max",
			"iPhone 12 mini":
			return .init(
				verticalDistance: screenHeight / 4 - 45,
				spacing: 2,
				numberOfSlots: isMaxSize ? 2 : 1
			)

		case "iPhone 13", "iPhone 13 Pro", "iPhone 13 Pro Max", "iPhone 13 mini",
			"iPhone 14", "iPhone 14 Plus",
			"iPhone 16e":
			let isIPhone13Mini = UIDevice.modelName == "iPhone 13 mini"
			return .init(
				verticalDistance: screenHeight / 4 - 30,
				spacing: isMaxSize ? 8 : 3,
				numberOfSlots: isIPhone13Mini ? 1 : 2
			)
		case "iPhone 14 Pro", "iPhone 14 Pro Max",
			"iPhone 15", "iPhone 15 Plus", "iPhone 15 Pro", "iPhone 15 Pro Max",
			"iPhone 16", "iPhone 16 Plus", "iPhone 16 Pro", "iPhone 16 Pro Max",
			"iPhone 17", "iPhone 17 Pro", "iPhone 17 Pro Max",
			"iPhone Air":
			return .init(
				verticalDistance: screenHeight / 4 - 22,
				spacing: isMaxSize ? 14 : 8,
				numberOfSlots: 2
			)
		default:
			// Best guess is future models will have at least as much space
			return .init(
				verticalDistance: screenHeight / 4 - 22,
				spacing: 8,
				numberOfSlots: 2
			)
		}
	}

	@MainActor
	private static var isMaxSize: Bool {
		return UIDevice.modelName.contains("Max") || UIDevice.modelName.contains("Plus")
	}
}
