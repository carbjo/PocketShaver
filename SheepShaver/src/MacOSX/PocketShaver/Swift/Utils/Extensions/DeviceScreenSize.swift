//
//  DeviceScreenSize.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-27.
//

import UIKit

enum DeviceScreenSize {
	case normal
	case small
	case tiny
}

extension UIScreen {
	static var deviceScreenSize: DeviceScreenSize {
		if isSESize,
		   isPortraitMode {
			return .tiny
		} else if !UIDevice.isIPad,
				  isPortraitMode {
			return .small
		} else {
			return .normal
		}
	}
}

