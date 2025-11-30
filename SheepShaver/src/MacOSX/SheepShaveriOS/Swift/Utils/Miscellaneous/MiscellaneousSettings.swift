//
//  MiscellaneousSettings.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-17.
//

import NotificationCenter

enum MiscellaneousNotifications {
	static let fpsCounterSettingChanged = NSNotification.Name("fpsCounterSettingChanged")
}

class MiscellaneousSettings: Codable {
	private(set) var hasDismissedSetupInstructions: Bool
	private(set) var showHints: Bool
	private(set) var iPadMousePassthrough: Bool {
		didSet {
			objc_replaceBool("ipadmousepassthrough", iPadMousePassthrough)
		}
	}
	private(set) var gestureHapticFeedback: Bool
	private(set) var mouseHapticFeedback: Bool
	private(set) var keyHapticFeedback: Bool
	private(set) var soundDisabled: Bool {
		didSet {
			objc_replaceBool("nosound", soundDisabled)
		}
	}
	private(set) var fpsCounterEnabled: Bool {
		didSet {
			NotificationCenter.default.post(.init(name: MiscellaneousNotifications.fpsCounterSettingChanged))
		}
	}

	init() {
		hasDismissedSetupInstructions = false
		showHints = true
		iPadMousePassthrough = false
		gestureHapticFeedback = true
		mouseHapticFeedback = true
		keyHapticFeedback = true
		soundDisabled = objc_findBool("nosound")
		fpsCounterEnabled = false
	}

	@MainActor
	static var current: MiscellaneousSettings = {
		if let data = Storage.shared.load(from: .miscellaneous),
		   let settings = try? JSONDecoder().decode(MiscellaneousSettings.self, from: data) {
			return settings
		}

		return MiscellaneousSettings()
	}()

	@MainActor
	func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .miscellaneous)
		} catch {}
	}

	@MainActor
	func reportHasDismissedSetupInstructions() {
		hasDismissedSetupInstructions = true

		saveAsCurrent()
	}

	@MainActor
	func set(showHints: Bool) {
		self.showHints = showHints

		saveAsCurrent()
	}

	@MainActor
	func set(iPadMousePassthrough: Bool) {
		self.iPadMousePassthrough = iPadMousePassthrough

		saveAsCurrent()
	}

	@MainActor
	func set(gestureHapticFeedback: Bool) {
		self.gestureHapticFeedback = gestureHapticFeedback

		saveAsCurrent()
	}

	@MainActor
	func set(mouseHapticFeedback: Bool) {
		self.mouseHapticFeedback = mouseHapticFeedback

		objc_setMouseHapticFeedbackEnabled(mouseHapticFeedback)

		saveAsCurrent()
	}

	@MainActor
	func set(keyHapticFeedback: Bool) {
		self.keyHapticFeedback = keyHapticFeedback

		saveAsCurrent()
	}

	@MainActor
	func set(soundDisabled: Bool) {
		self.soundDisabled = soundDisabled

		saveAsCurrent()
	}

	@MainActor
	func set(fpsCounterEnabled: Bool) {
		self.fpsCounterEnabled = fpsCounterEnabled

		saveAsCurrent()
	}
}

@objcMembers
public class MiscellaneousSettingsObjC: NSObject {

	@MainActor
	static func isKeyHapticFeedbackOn() -> Bool {
		MiscellaneousSettings.current.keyHapticFeedback
	}
}
