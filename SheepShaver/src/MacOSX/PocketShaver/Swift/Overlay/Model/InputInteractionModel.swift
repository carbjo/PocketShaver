//
//  InputInteractionModel.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-31.
//

import UIKit
import Combine

@MainActor
class InputInteractionModel {
	enum Change {
		case relativeMouseModeChanged(isEnabled: Bool)
		case canToggleRelativeMouseModeChanged(isEnabled: Bool)
	}

	private let keyDownFeedbackGenerator = UIImpactFeedbackGenerator(style: .soft)
	private(set) var isRelativeMouseModeEnabled = false

	var canToggleRelativeMouseMode: Bool {
		MiscellaneousSettings.current.relativeMouseModeSetting == .manual ||
		MiscellaneousSettings.current.relativeMouseModeSetting == .automatic
	}

	let changeSubject = PassthroughSubject<Change, Never>()

	init() {
		NotificationCenter.default.addObserver(self, selector: #selector(handleRelativeMouseModeEnabled), name: LocalNotifications.relativeMouseModeEnabled, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleRelativeMouseModeDisabled), name: LocalNotifications.relativeMouseModeDisabled, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleRelativeMouseModeSettingChanged), name: LocalNotifications.relativeMouseModeSettingChanged, object: nil)
	}

	func handle(_ key: SDLKey, isDown: Bool, hapticAllowed: Bool) {
		// TODO: Which value is dependent on keyboard layout is chosen in simlated OS.
		// Should not assume EN layout, specifically
		if isDown {
			objc_ADBKeyDown(key.enValue)
		} else {
			objc_ADBKeyUp(key.enValue)
		}

		if isDown,
		   hapticAllowed,
		   MiscellaneousSettings.current.keyHapticFeedback {
			keyDownFeedbackGenerator.impactOccurred()
		}
	}

	func handle(_ button: SpecialButton, isDown: Bool) {
		switch button {
		case .hover:
			objc_ADBSetHover(isDown)
		case .hoverAbove:
			objc_ADBSetHover(isDown)
			if isDown {
				objc_ADBSetHoverMode(HoverModeAbove)
			} else {
				objc_ADBSetHoverMode(HoverModeRegular)
			}
		case .hoverBelow:
			objc_ADBSetHover(isDown)
			if isDown {
				objc_ADBSetHoverMode(HoverModeBelow)
			} else {
				objc_ADBSetHoverMode(HoverModeRegular)
			}
		case .mouseClick:
			if isDown {
				objc_ADBWriteMouseDown(0)

				Task { @MainActor in
					if MiscellaneousSettings.current.keyHapticFeedback {
						objc_keyHapticFeedback() // Same haptic feedback as mouse click
					}
				}
			} else {
				objc_ADBWriteMouseUp(0);
			}
		case .cmdW:
			if !isDown {
				objc_ADBKeyDown(SDLKey.cmd.enValue)
				objc_ADBKeyDown(SDLKey.w.enValue)

				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					objc_ADBKeyUp(SDLKey.w.enValue)
					objc_ADBKeyUp(SDLKey.cmd.enValue)
				}
			}
		}
	}

	func handleFireMouseJoystick(with delta: CGVector) {
		let x = Int(round(delta.dx))
		let y = Int(round(delta.dy))
		objc_ADBMouseMoved(x, y)
	}

	func handle(_ hiddenInputFieldOutput: HiddenInputFieldOutput) {
		if hiddenInputFieldOutput.withShift {
			handle(SDLKey.shift, isDown: true, hapticAllowed: false)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
				self?.handle(hiddenInputFieldOutput.key, isDown: true, hapticAllowed: false)
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
				self?.handle(SDLKey.shift, isDown: false, hapticAllowed: false)
				self?.handle(hiddenInputFieldOutput.key, isDown: false, hapticAllowed: false)
			}
		} else {
			handle(hiddenInputFieldOutput.key, isDown: true, hapticAllowed: false)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
				self?.handle(hiddenInputFieldOutput.key, isDown: false, hapticAllowed: false)
			}
		}
	}

	func toggleRelativeMouseMode() {
		if isRelativeMouseModeEnabled {
			objc_setRelativeMouseMode(false)
		} else {
			objc_setRelativeMouseMode(true)
		}
	}

	func setRelativeMouseModeEnabled() -> Bool {
		guard !isRelativeMouseModeEnabled else {
			return false
		}

		isRelativeMouseModeEnabled = true

		return true
	}

	func setRelativeMouseModeDisabled() -> Bool {
		guard isRelativeMouseModeEnabled else {
			return false
		}

		isRelativeMouseModeEnabled = false

		return true
	}

	@objc
	private func handleRelativeMouseModeEnabled() {
		guard !isRelativeMouseModeEnabled else {
			return
		}

		isRelativeMouseModeEnabled = true

		changeSubject.send(.relativeMouseModeChanged(isEnabled: true))
	}

	@objc
	private func handleRelativeMouseModeDisabled() {
		guard isRelativeMouseModeEnabled else {
			return
		}

		isRelativeMouseModeEnabled = false

		changeSubject.send(.relativeMouseModeChanged(isEnabled: false))
	}

	@objc
	private func handleRelativeMouseModeSettingChanged() {
		changeSubject.send(.canToggleRelativeMouseModeChanged(isEnabled: canToggleRelativeMouseMode))
	}
}
