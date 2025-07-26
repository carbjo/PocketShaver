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
}
