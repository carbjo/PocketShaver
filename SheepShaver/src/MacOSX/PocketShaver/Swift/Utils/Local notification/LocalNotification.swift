//
//  LocalNotification.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-13.
//

import NotificationCenter

enum LocalNotification: String {
	case performanceCounterSettingChanged
	case relativeMouseModeEnabled
	case relativeMouseModeDisabled
	case relativeMouseModeSettingChanged
	case relativeMouseModeCapabilityFound
	case iPadMousePassthroughChanged
	case audioEnabledChanged
	case jaggyCursorResolutionSelected
	case gotIpAddress
	case displayPreferencesRequested
	case enteredKeyboardModeWhileUsingHardwareKeyboard

	static func send(_ notification: LocalNotification, object: Any? = nil) {
		NotificationCenter.default.post(
			.init(
				name: NSNotification.Name(notification.rawValue),
				object: object
			)
		)
	}

	static func observe(_ notification: LocalNotification, _ observer: Any, _ selector: Selector) {
		NotificationCenter.default.addObserver(
			observer,
			selector: selector,
			name: NSNotification.Name(notification.rawValue),
			object: nil
		)
	}
}


@objcMembers
class LocalNotificationObjCProxy: NSObject {
	static func sendRelativeMouseModeEnabled() {
		LocalNotification.send(.relativeMouseModeEnabled)
	}

	static func sendRelativeMouseModeDisabled() {
		LocalNotification.send(.relativeMouseModeDisabled)
	}

	static func sendRelativeMouseModeCapabilityFound() {
		LocalNotification.send(.relativeMouseModeCapabilityFound)
	}

	static func sendJaggyCursorResolutionSelected() {
		LocalNotification.send(.jaggyCursorResolutionSelected)
	}

	static func sendDisplayPreferencesRequested() {
		LocalNotification.send(.displayPreferencesRequested)
	}
}
