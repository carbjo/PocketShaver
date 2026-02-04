//
//  Fonts.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-04.
//

import UIKit

enum Fonts: String {
	case geneva = "Geneva"

	func ofSize(_ size: CGFloat) -> UIFont? {
		guard registerFont(named: rawValue) else {
			return nil
		}

		return UIFont(name: rawValue, size: size)
	}
}

private func registerFont(named name: String) -> Bool {
	if UIFont(name: name, size: 12) != nil {
		return true
	}
	guard let asset = NSDataAsset(name: "Fonts/\(name)", bundle: Bundle.main),
		  let provider = CGDataProvider(data: asset.data as NSData),
		  let font = CGFont(provider) else {
		return false
	}

	var error: Unmanaged<CFError>?
	if !CTFontManagerRegisterGraphicsFont(font, &error) {
		return false
	}

	return true
}
