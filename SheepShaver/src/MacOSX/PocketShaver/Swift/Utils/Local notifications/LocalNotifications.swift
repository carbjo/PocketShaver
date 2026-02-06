//
//  LocalNotifications.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-13.
//

import NotificationCenter

enum LocalNotifications {
	static let fpsCounterSettingChanged = NSNotification.Name("fpsCounterSettingChanged")

	static let relativeMouseModeEnabled = NSNotification.Name("relativeMouseModeEnabled")
	static let relativeMouseModeDisabled = NSNotification.Name("relativeMouseModeDisabled")
	static let relativeMouseModeSettingChanged = NSNotification.Name("relativeMouseModeSettingChanged")
	static let relativeMouseModeCapabilityFound = NSNotification.Name("relativeMouseModeCapabilityFound")

	static let iPadMousePassthroughChanged = NSNotification.Name("iPadMousePassthroughChanged")

	static let jaggyCursorResolutionSelected = NSNotification.Name("jaggyCursorResolutionSelected")
}


@objcMembers
class LocalNotificationsObjCProxy: NSObject {
	static func sendRelativeMouseModeEnabled() {
		NotificationCenter.default.post(name: LocalNotifications.relativeMouseModeEnabled, object: nil)
	}

	static func sendRelativeMouseModeDisabled() {
		NotificationCenter.default.post(name: LocalNotifications.relativeMouseModeDisabled, object: nil)
	}

	static func sendRelativeMouseModeCapabilityFound() {
		NotificationCenter.default.post(name: LocalNotifications.relativeMouseModeCapabilityFound, object: nil)
	}

	static func sendJaggyCursorResolutionSelected() {
		NotificationCenter.default.post(name: LocalNotifications.jaggyCursorResolutionSelected, object: nil)
	}
}
