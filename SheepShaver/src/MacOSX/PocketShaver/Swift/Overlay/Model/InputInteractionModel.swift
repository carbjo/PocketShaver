//
//  InputInteractionModel.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-31.
//

import UIKit
import Combine
import AVFoundation

enum HoverOffsetMode {
	case off
	case justAbove
	case farAbove
	case sideways
	case diagonallyAbove
}

@MainActor
class InputInteractionModel {
	enum Change {
		case relativeMouseModeChanged(isEnabled: Bool)
		case canToggleRelativeMouseModeChanged(isEnabled: Bool)
		case hoverOffsetModeChanged(HoverOffsetMode)
		case iPadMousePassthroughChanged(isEnabled: Bool)
		case audioConfigurationChanged(Bool, HostAudioVolume)
	}

	fileprivate struct OffsetConfig {
		let x: CGFloat
		let y: CGFloat
	}

	enum HostAudioVolume {
		case low
		case mid
		case high
	}

	private let keyDownFeedbackGenerator = UIImpactFeedbackGenerator(style: .soft)
	private(set) var isRelativeMouseModeEnabled = false
	private var silenceRelativeMouseModeChanges = false

	private var hostAudioVolumeChangeObservation: NSKeyValueObservation!

	private(set) var hoverOffsetMode: HoverOffsetMode = MiscellaneousSettings.current.bootInHoverMode ? .justAbove : .off {
		didSet {
			updateADBHoverOffset()
		}
	}
	private var offsetConfig: OffsetConfig = .init(x: 0, y: 0)

	private var secondFingerGestureStartTime: Date?
	private var isHoverModeClicking = false
	private var hoverModeClickIfStilTimer: Timer?
	private var hoverModeClickIfHaveNotMovedEnoughTimer: Timer?
	private var hoverOffsetModeTransitionAnimator: HoverOffsetModeTransitionAnimator?
	private var isSecondFingerDragging = false

	private var hoverOffsetModeBeforeSecondFingerDrag: HoverOffsetMode?
	private var hoverOffsetModeBeforeShowKeyboardState: HoverOffsetMode?
	private var hoverOffsetModeBeforeRelativeMouseMode: HoverOffsetMode?

	var showWarning: ((String) -> Void)?

	var miscSettings: MiscellaneousSettings {
		.current
	}

	var canToggleRelativeMouseMode: Bool {
		miscSettings.relativeMouseModeSetting == .manual ||
		miscSettings.relativeMouseModeSetting == .automatic
	}

	var iPadMousePassthrough: Bool {
		miscSettings.iPadMousePassthrough
	}

	var isAudioEnabled: Bool {
		miscSettings.audioEnabled
	}

	var hostAudioVolume: HostAudioVolume {
		let hostAudioVolumeRaw = AVAudioSession.sharedInstance().outputVolume
		if hostAudioVolumeRaw >= 0.66 {
			return .high
		} else if hostAudioVolumeRaw >= 0.33 {
			return .mid
		} else {
			return .low
		}
	}

	let changeSubject = PassthroughSubject<Change, Never>()

	static let shared = InputInteractionModel()

	init() {
		NotificationCenter.default.addObserver(self, selector: #selector(handleRelativeMouseModeEnabled), name: LocalNotifications.relativeMouseModeEnabled, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleRelativeMouseModeDisabled), name: LocalNotifications.relativeMouseModeDisabled, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleRelativeMouseModeSettingChanged), name: LocalNotifications.relativeMouseModeSettingChanged, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleIPadMousePassthroughChanged), name: LocalNotifications.iPadMousePassthroughChanged, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleAudioConfigurationChanged), name: LocalNotifications.audioEnabledChanged, object: nil)
		hostAudioVolumeChangeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] _, _ in
			Task { @MainActor in
				self?.handleAudioConfigurationChanged()
			}
		}

		if miscSettings.relativeMouseModeSetting == .alwaysOn {
			objc_setRelativeMouseMode(true)
			handleRelativeMouseModeEnabled()
		}
		if (miscSettings.bootInHoverMode &&
			!miscSettings.iPadMousePassthrough &&
			miscSettings.relativeMouseModeSetting != .alwaysOn) {
			hoverOffsetMode = .diagonallyAbove
		}
	}

	func configure(offsetX: CGFloat, offsetY: CGFloat) {
		offsetConfig = .init(x: offsetX, y: offsetY)
		updateADBHoverOffset()
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
		   miscSettings.keyHapticFeedback {
			keyDownFeedbackGenerator.impactOccurred()
		}
	}

	func handle(_ button: SpecialButton, isDown: Bool) {
		switch button {
		case .hoverJustAboveToggle:
			if !isDown {
				guard !warnIfRelativeMouseMode(), !warnIfIPadMousePassthroughMode() else { return }
				toggleHoverOffsetMode(.justAbove)
			}
		case .hoverSidewaysToggle:
			if !isDown {
				guard !warnIfRelativeMouseMode(), !warnIfIPadMousePassthroughMode() else { return }
				toggleHoverOffsetMode(.sideways)
			}
		case .hoverFarAboveToggle:
			if !isDown {
				guard !warnIfRelativeMouseMode(), !warnIfIPadMousePassthroughMode() else { return }
				toggleHoverOffsetMode(.farAbove)
			}
		case .hoverDiagonallyToggle:
			if !isDown {
				guard !warnIfRelativeMouseMode(), !warnIfIPadMousePassthroughMode() else { return }
				toggleHoverOffsetMode(.diagonallyAbove)
			}
		case .mouseClick:
			if isDown {
				objc_ADBWriteMouseDown(0)

				Task { @MainActor in
					if miscSettings.keyHapticFeedback {
						objc_mousedownHapticFeedback() // Same haptic feedback as mouse click
					}
				}
			} else {
				objc_ADBWriteMouseUp(0)
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
		case .rightClick:
			if !isDown {
				RightClick.performRightClick()
			}
		case .audioEnabled:
			if !isDown {
				let newValue = !miscSettings.audioEnabled
				miscSettings.set(audioEnabled: newValue)
				objc_update_audio_enabled_setting(newValue)
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

	func beginSecondFingerClickIfEligible() {
		guard objc_ADBHoversOnMouseDown(),
		!miscSettings.iPadMousePassthrough else {
			return
		}

		secondFingerGestureStartTime = Date()

		if miscSettings.mouseHapticFeedback {
			objc_mousedownHapticFeedback()
		}

		let delay = miscSettings.secondFingerSwipe ? 0.03 : 0
		hoverModeClickIfStilTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
			Task { @MainActor [weak self] in
				await self?.beginSecondFingerClick()
			}
		}
	}

	func handleFinishTwoFingerGesture() {
		endSecondFingerClickIfEligible(mustPerformClick: true)

		if isSecondFingerDragging {
			isSecondFingerDragging = false

			self.silenceRelativeMouseModeChanges = true
			objc_setRelativeMouseMode(false)
			objc_ADBSetHoverGestureDragging(false)
			self.silenceRelativeMouseModeChanges = false

			if let offsetModeBeforeSecondFingerDrag = self.hoverOffsetModeBeforeSecondFingerDrag {
				self.setHoverOffsetMode(offsetModeBeforeSecondFingerDrag)
				changeSubject.send(.hoverOffsetModeChanged(hoverOffsetMode))
				self.hoverOffsetModeBeforeSecondFingerDrag = nil
			}
		}
	}

	func handleSecondFingerDragDuringTwoFingerGesture() {
		if hoverModeClickIfStilTimer != nil {

			hoverModeClickIfStilTimer?.invalidate()
			hoverModeClickIfStilTimer = nil

			hoverModeClickIfHaveNotMovedEnoughTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
				Task { @MainActor [weak self] in
					await self?.beginSecondFingerClick()
				}
			}
		}
	}

	func handleSecondFingerReleaseResultIfEligible(_ result: SecondFingerReleaseResult) {
		guard !isRelativeMouseModeEnabled,
			  let secondFingerGestureStartTime,
			  Date().timeIntervalSince(secondFingerGestureStartTime) < 0.4 else {
			return
		}

		endSecondFingerClickIfEligible(mustPerformClick: false)

		guard objc_ADBHoversOnMouseDown() else {
			return
		}

		switch result.swipeResult {
		case .up:
			if hoverOffsetMode == .justAbove {
				setHoverOffsetMode(.farAbove)
			} else if hoverOffsetMode == .sideways {
				setHoverOffsetMode(.diagonallyAbove)
			}
		case .upRight:
			switch result.firstFingerSide {
			case .left:
				if hoverOffsetMode == .justAbove {
					setHoverOffsetMode(.diagonallyAbove)
				} else if hoverOffsetMode == .farAbove {
					setHoverOffsetMode(.diagonallyAbove)
				} else if hoverOffsetMode == .sideways {
					setHoverOffsetMode(.diagonallyAbove)
				}
			case .right:
				if hoverOffsetMode == .sideways {
					setHoverOffsetMode(.farAbove)
				} else if hoverOffsetMode == .diagonallyAbove {
					setHoverOffsetMode(.farAbove)
				} else if hoverOffsetMode == .justAbove {
					setHoverOffsetMode(.farAbove)
				}
			}
		case .right:
			switch result.firstFingerSide {
			case .left:
				if hoverOffsetMode == .justAbove {
					setHoverOffsetMode(.sideways)
				} else if hoverOffsetMode == .farAbove {
					setHoverOffsetMode(.diagonallyAbove)
				}
			case .right:
				if hoverOffsetMode == .sideways {
					setHoverOffsetMode(.justAbove)
				} else if hoverOffsetMode == .diagonallyAbove {
					setHoverOffsetMode(.farAbove)
				}
			}
		case .downRight:
			switch result.firstFingerSide {
			case .left:
				if hoverOffsetMode == .farAbove {
					setHoverOffsetMode(.sideways)
				} else if hoverOffsetMode == .justAbove {
					setHoverOffsetMode(.sideways)
				} else if hoverOffsetMode == .diagonallyAbove {
					setHoverOffsetMode(.sideways)
				}

			case .right:
				if hoverOffsetMode == .diagonallyAbove {
					setHoverOffsetMode(.justAbove)
				} else if hoverOffsetMode == .farAbove {
					setHoverOffsetMode(.justAbove)
				} else if hoverOffsetMode == .sideways {
					setHoverOffsetMode(.justAbove)
				}
			}
		case .down:
			if hoverOffsetMode == .farAbove {
				setHoverOffsetMode(.justAbove)
			} else if hoverOffsetMode == .diagonallyAbove {
				setHoverOffsetMode(.sideways)
			}
		case .downLeft:
			switch result.firstFingerSide {
			case .left:
				if hoverOffsetMode == .diagonallyAbove {
					setHoverOffsetMode(.justAbove)
				} else if hoverOffsetMode == .farAbove {
					setHoverOffsetMode(.justAbove)
				} else if hoverOffsetMode == .sideways {
					setHoverOffsetMode(.justAbove)
				}
			case .right:
				if hoverOffsetMode == .farAbove {
					setHoverOffsetMode(.sideways)
				} else if hoverOffsetMode == .diagonallyAbove {
					setHoverOffsetMode(.justAbove)
				} else if hoverOffsetMode == .justAbove {
					setHoverOffsetMode(.justAbove)
				}
			}
		case .left:
			switch result.firstFingerSide {
			case .left:
				if hoverOffsetMode == .sideways {
					setHoverOffsetMode(.justAbove)
				} else if hoverOffsetMode == .diagonallyAbove {
					setHoverOffsetMode(.farAbove)
				}
			case .right:
				if hoverOffsetMode == .justAbove {
					setHoverOffsetMode(.sideways)
				} else if hoverOffsetMode == .farAbove {
					setHoverOffsetMode(.diagonallyAbove)
				}
			}
		case .upLeft:
			switch result.firstFingerSide {
			case .left:
				if hoverOffsetMode == .sideways {
					setHoverOffsetMode(.farAbove)
				} else if hoverOffsetMode == .justAbove {
					setHoverOffsetMode(.farAbove)
				} else if hoverOffsetMode == .diagonallyAbove {
					setHoverOffsetMode(.farAbove)
				}
			case .right:
				if hoverOffsetMode == .justAbove {
					setHoverOffsetMode(.diagonallyAbove)
				} else if hoverOffsetMode == .sideways {
					setHoverOffsetMode(.diagonallyAbove)
				} else if hoverOffsetMode == .farAbove {
					setHoverOffsetMode(.diagonallyAbove)
				}
			}
		case .none: break
		}
	}

	func handleFirstFingerReleaseDuringTwoFingerGesture() {
		guard !isRelativeMouseModeEnabled else {
			return
		}

		isSecondFingerDragging = true
		hoverOffsetModeBeforeSecondFingerDrag = hoverOffsetMode
		silenceRelativeMouseModeChanges = true
		objc_setRelativeMouseMode(true)
		objc_ADBSetHoverGestureDragging(true)
		silenceRelativeMouseModeChanges = false
	}

	func toggleRelativeMouseMode() {
		if isRelativeMouseModeEnabled {
			objc_setRelativeMouseMode(false)
		} else {
			objc_setRelativeMouseMode(true)
		}
	}

	func handleKeyboardShown(_ isShown: Bool) {
		if isShown {
			if hoverOffsetMode != .off {
				hoverOffsetModeBeforeShowKeyboardState = hoverOffsetMode
				hoverOffsetMode = .off
			}
		} else {
			if let hoverOffsetModeBeforeShowKeyboardState {
				hoverOffsetMode = hoverOffsetModeBeforeShowKeyboardState
				self.hoverOffsetModeBeforeShowKeyboardState = nil
			}
		}
	}

	// MARK: - Private functions

	private func beginSecondFingerClick() async {
		resetHoverModeClickTimers()

		let wasHoverModeClicking = isHoverModeClicking

		await reportIsHoverModeClicking()

		if !wasHoverModeClicking {
			objc_ADBWriteMouseDown(0)
		}
	}

	private func endSecondFingerClickIfEligible(mustPerformClick: Bool) {
		resetHoverModeClickTimers()

		guard objc_ADBHoversOnMouseDown(),
		secondFingerGestureStartTime != nil else {
			return
		}

		secondFingerGestureStartTime = nil

		if isHoverModeClicking {
			objc_ADBWriteMouseUp(0)
		} else if mustPerformClick {
			objc_ADBMouseClick(0)
		}

		isHoverModeClicking = false
	}

	private func toggleHoverOffsetMode(_ hoverOffsetMode: HoverOffsetMode) {
		if self.hoverOffsetMode == hoverOffsetMode {
			setHoverOffsetMode(.off)
		} else {
			setHoverOffsetMode(hoverOffsetMode)
		}
	}

	private func setHoverOffsetMode(
		_ hoverOffsetMode: HoverOffsetMode
	) {
		let prevOffset = offsetConfig.offsetFor(mode: self.hoverOffsetMode)
		let prevOffsetMode = self.hoverOffsetMode

		let firstFingerOnLeftSide = objc_ADBHoverGestureStartWasLeftSide()
		let resultingTransition: HoverOffsetModeTransition
		switch (prevOffsetMode, hoverOffsetMode) {
		case (.justAbove, .farAbove),
			(.sideways, .diagonallyAbove):
			resultingTransition = .up
		case (.farAbove, .justAbove),
			(.diagonallyAbove, .sideways):
			resultingTransition = .down
		case (.justAbove, .sideways),
			(.farAbove, .diagonallyAbove):
			resultingTransition = firstFingerOnLeftSide ? .right : .left
		case (.sideways, .justAbove),
			(.diagonallyAbove, .farAbove):
			resultingTransition = firstFingerOnLeftSide ? .left : .right
		case (.justAbove, .diagonallyAbove):
			resultingTransition = firstFingerOnLeftSide ? .upRight : .upLeft
		case (.diagonallyAbove, .justAbove):
			resultingTransition = firstFingerOnLeftSide ? .downLeft : .downRight
		case (.farAbove, .sideways):
			resultingTransition = firstFingerOnLeftSide ? .downRight : .downLeft
		case (.sideways, .farAbove):
			resultingTransition = firstFingerOnLeftSide ? .upLeft : .upRight
		default:
			resultingTransition = .none
		}

		self.hoverOffsetMode = hoverOffsetMode

		if miscSettings.mouseHapticFeedback,
		   let latestMouseDownHapticFeedbackTimestamp = objc_getLatestMouseDownHapticFeedbackTimestamp() {
			let timeSinceMousedownHapticFeedback = Date().timeIntervalSince(latestMouseDownHapticFeedbackTimestamp)
			if timeSinceMousedownHapticFeedback > 0.12 {
				objc_mousedownHapticFeedback()
			}
		}

		if resultingTransition != .none {
			let newOffset = offsetConfig.offsetFor(mode: hoverOffsetMode)
			let transition = CGVector(dx: newOffset.0 - prevOffset.0, dy: newOffset.1 - prevOffset.1)
			hoverOffsetModeTransitionAnimator = HoverOffsetModeTransitionAnimator(transition)
		}

		changeSubject.send(.hoverOffsetModeChanged(hoverOffsetMode))
	}

	private func reportIsHoverModeClicking() async {
		isHoverModeClicking = true
	}

	private func resetHoverModeClickTimers () {
		hoverModeClickIfStilTimer?.invalidate()
		hoverModeClickIfStilTimer = nil
		hoverModeClickIfHaveNotMovedEnoughTimer?.invalidate()
		hoverModeClickIfHaveNotMovedEnoughTimer = nil
	}

	private func updateADBHoverOffset() {
		if self.hoverOffsetMode == .off {
			objc_ADBDisableHoverMode()
		} else {
			let (offsetX, offsetY) = offsetConfig.offsetFor(mode: hoverOffsetMode)
			objc_ADBEnableHoverModeWith(offsetX, offsetY)
		}
	}

	// MARK: - Handlers

	@objc
	private func handleRelativeMouseModeEnabled() {
		guard !isRelativeMouseModeEnabled else {
			return
		}

		if hoverOffsetMode != .off {
			hoverOffsetModeBeforeRelativeMouseMode = hoverOffsetMode
		}

		isRelativeMouseModeEnabled = true
		hoverOffsetMode = .off

		if !silenceRelativeMouseModeChanges {
			changeSubject.send(.relativeMouseModeChanged(isEnabled: true))
		}
	}

	@objc
	private func handleRelativeMouseModeDisabled() {
		guard isRelativeMouseModeEnabled else {
			return
		}

		isRelativeMouseModeEnabled = false

		if !silenceRelativeMouseModeChanges {
			changeSubject.send(.relativeMouseModeChanged(isEnabled: false))
		}

		if let hoverOffsetModeBeforeRelativeMouseMode {
			setHoverOffsetMode(hoverOffsetModeBeforeRelativeMouseMode)
			self.hoverOffsetModeBeforeRelativeMouseMode = nil
		}
	}

	@objc
	private func handleRelativeMouseModeSettingChanged() {
		changeSubject.send(.canToggleRelativeMouseModeChanged(isEnabled: canToggleRelativeMouseMode))
	}

	@objc
	private func handleIPadMousePassthroughChanged() {
		let isEnabled = miscSettings.iPadMousePassthrough
		if isEnabled {
			hoverOffsetMode = .off
		}
		
		changeSubject.send(.iPadMousePassthroughChanged(isEnabled: isEnabled))
	}

	@objc
	private func handleAudioConfigurationChanged() {
		changeSubject.send(.audioConfigurationChanged(isAudioEnabled, hostAudioVolume))
	}
}

private extension InputInteractionModel {
	func warnIfRelativeMouseMode() -> Bool {
		if isRelativeMouseModeEnabled {
			showWarning?("Not possible while relative mouse is on")
			return true
		}
		return false
	}

	func warnIfIPadMousePassthroughMode() -> Bool {
		if iPadMousePassthrough {
			showWarning?("Not possible while mouse input is used")
			return true
		}
		return false
	}
}

private class HoverOffsetModeTransitionAnimator {
	private let transition: CGVector
	private var timers = [Timer]()
	private let totalSteps: Int
	private let totalTime: TimeInterval = 0.107 // Get 8 steps with 75hz
	private let stepTime: TimeInterval

	private let beginAnimationState: ADBBeginAnimationState

	private var startTime: Date!

	init(_ transition: CGVector) {
		self.transition = transition

		let fps = MiscellaneousCachedSettings.framesPerSecond
		totalSteps = Int(totalTime * CGFloat(fps))
		stepTime = totalTime / CGFloat(totalSteps)
		beginAnimationState = objc_ADBStartAnimation()

		startTime = Date()

		for i in 0...totalSteps {
			let ratio = CGFloat(i) / CGFloat(totalSteps)
			timers.append(Timer.scheduledTimer(withTimeInterval: totalTime * ratio, repeats: false) { [weak self] _ in
				self?.runStep(i)
			})
		}

		timers.append(Timer.scheduledTimer(withTimeInterval: totalTime, repeats: false) { _ in
			objc_ADBEndAnimation()
		})
	}

	private func runStep(_ step: Int) {
		let ratio = CGFloat(step) / CGFloat(totalSteps)
		let xSign: CGFloat = objc_ADBHoverGestureStartWasLeftSide() ? 1 : -1
		let stepX = Int(xSign * transition.dx * ratio)
		let stepY = Int(transition.dy * ratio)

		let x = beginAnimationState.x + stepX
		let y = beginAnimationState.y + stepY

		objc_ADBAnimateMove(x, y)
	}
}

private extension InputInteractionModel.OffsetConfig {
	@MainActor
	func offsetFor(mode: HoverOffsetMode) -> (CGFloat, CGFloat) {
		var x: CGFloat = 0
		var y: CGFloat = 0

		let hoverJustAboveOffsetModifier = CGFloat(MiscellaneousSettings.current.hoverJustAboveOffsetModifier)

		switch mode {
		case .diagonallyAbove:
			x = self.x
			y = -self.y
		case .farAbove:
			y = -self.y * 1.25
		case .justAbove:
			y = -self.y * 0.43 * hoverJustAboveOffsetModifier
		case .sideways:
			x = self.x
			y = self.y * 0.4
		default: break
		}

		return (x,y)
	}
}

@objcMembers
class InputInteractionModelObjC: NSObject {
	public static func configure(offsetX: CGFloat, offsetY: CGFloat) {
		Task {
			await InputInteractionModel.shared.configure(offsetX: offsetX, offsetY: offsetY)
		}
	}
}
