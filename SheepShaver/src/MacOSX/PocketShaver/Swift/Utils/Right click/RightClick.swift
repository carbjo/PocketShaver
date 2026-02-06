//
//  RightClick.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-12.
//

import Foundation

@objcMembers
public class RightClick: NSObject {
	static func performRightClick() {
		let key: SDLKey
		switch MiscellaneousCachedSettings.rightClickSetting {
		case .control: key = .ctrl
		case .command: key = .cmd
		}

		objc_ADBKeyDown(key.enValue)

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
			objc_ADBMouseClick(0)

			DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
				objc_ADBKeyUp(key.enValue)
			}
		}
	}
}
