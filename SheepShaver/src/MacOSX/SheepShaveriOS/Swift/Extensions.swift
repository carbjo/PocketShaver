//
//  Extensions.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

extension UIView {
	static func withoutConstraints() -> Self {
		let view = Self()
		view.translatesAutoresizingMaskIntoConstraints = false
		return view
	}
}

extension NSObject {
	var ptrString: String {
		"\(Unmanaged.passUnretained(self).toOpaque())"
	}
}

extension UIDevice {
	static var hasNotch: Bool {
		let screenHeight = UIScreen.main.nativeBounds.height
		let notchlessDevicesHeights: [CGFloat] = [480, 960, 1136, 1334, 1920, 2208]

		return !notchlessDevicesHeights.contains(screenHeight)
	}

	static var isPortraitMode: Bool {
		!current.orientation.isLandscape
	}

	static var sideMarginForButtons: CGFloat {
		if isPortraitMode {
			return 8
		} else {
			return hasNotch ? 64 : 8
		}
	}
}

extension CGVector {
	static func +(lhs: Self, rhs: Self) -> Self {
		.init(dx: lhs.dx + rhs.dx, dy: lhs.dy + rhs.dy)
	}

	static func +=(lhs: inout Self, rhs: Self) {
		lhs = lhs + rhs
	}

	var abs: CGFloat {
		sqrt(dx*dx + dy*dy)
	}
}

extension UIButton.Configuration {
	static var defaultConfig: Self {
		var configuration = UIButton.Configuration.filled()
		configuration.baseForegroundColor = .white
		configuration.baseBackgroundColor = .lightGray.withAlphaComponent(0.5)
		configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
		configuration.background.cornerRadius = 8
		return configuration
	}
}
