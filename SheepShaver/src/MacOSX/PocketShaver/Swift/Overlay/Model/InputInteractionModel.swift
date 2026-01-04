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
		case hoverOffsetModeChanged(HoverOffsetMode)
	}

	private let keyDownFeedbackGenerator = UIImpactFeedbackGenerator(style: .soft)
	private(set) var isRelativeMouseModeEnabled = false

	private var offsetMode: HoverOffsetMode = MiscellaneousSettings.current.bootInHoverMode ? HoverOffsetModeHoverNoOffset : HoverOffsetModeOff

	private var secondFingerGestureStartTime: Date?
	private var isHoverModeClicking = false
	private var hoverModeClickIfStilTimer: Timer?
	private var hoverModeClickIfHaveNotMovedEnoughTimer: Timer?

	private var hoverOffsetModeTransitionAnimator: HoverOffsetModeTransitionAnimator?

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
			objc_ADBSetHoverOffsetMode(HoverOffsetModeHoverNoOffset)
		case .hoverAbove:
			if isDown {
				objc_ADBSetHoverOffsetMode(HoverOffsetModeAbove)
			} else {
				objc_ADBSetHoverOffsetMode(HoverOffsetModeHoverNoOffset)
			}
		case .hoverBelow:
			if isDown {
				objc_ADBSetHoverOffsetMode(HoverOffsetModeBelow)
			} else {
				objc_ADBSetHoverOffsetMode(HoverOffsetModeHoverNoOffset)
			}
		case .hoverSidewaysToggle:
			if !isDown {
				toggleHoverOffsetMode(HoverOffsetModeSideways)
			}
		case .hoverAboveToggle:
			if !isDown {
				toggleHoverOffsetMode(HoverOffsetModeAbove)
			}
		case .hoverDiagonallyToggle:
			if !isDown {
				toggleHoverOffsetMode(HoverOffsetModeDiagonallyAbove)
			}
		case .mouseClick:
			if isDown {
				objc_ADBWriteMouseDown(0)

				Task { @MainActor in
					if MiscellaneousSettings.current.keyHapticFeedback {
						objc_mousedownHapticFeedback() // Same haptic feedback as mouse click
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

	func beginSecondFingerClickIfEligible() {
		guard objc_ADBHoversOnMouseDown() else {
			return
		}

		secondFingerGestureStartTime = Date()

		if MiscellaneousSettings.current.mouseHapticFeedback {
			objc_mousedownHapticFeedback()
		}

		let delay = MiscellaneousSettings.current.secondFingerSwipe ? 0.03 : 0
		hoverModeClickIfStilTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
			Task { @MainActor [weak self] in
				await self?.beginSecondFingerClick()
			}
		}
	}

	func endSecondFingerClickIfEligible(mustPerformClick: Bool = true) {
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
		guard let secondFingerGestureStartTime,
			  Date().timeIntervalSince(secondFingerGestureStartTime) < 0.4 else {
			return
		}
		
		endSecondFingerClickIfEligible(mustPerformClick: false)

		guard objc_ADBHoversOnMouseDown() else {
			return
		}

		switch result.swipeResult {
		case .up:
			if offsetMode == HoverOffsetModeHoverNoOffset {
				setHoverOffsetMode(HoverOffsetModeAbove, .up)
			} else if offsetMode == HoverOffsetModeSideways {
				setHoverOffsetMode(HoverOffsetModeDiagonallyAbove, .up)
			}
		case .upRight:
			switch result.firstFingerSide {
			case .left:
				if offsetMode == HoverOffsetModeHoverNoOffset {
					setHoverOffsetMode(HoverOffsetModeDiagonallyAbove, .upRight)
				} else if offsetMode == HoverOffsetModeAbove {
					setHoverOffsetMode(HoverOffsetModeDiagonallyAbove, .right)
				} else if offsetMode == HoverOffsetModeSideways {
					setHoverOffsetMode(HoverOffsetModeDiagonallyAbove, .up)
				}
			case .right:
				if offsetMode == HoverOffsetModeSideways {
					setHoverOffsetMode(HoverOffsetModeAbove, .upRight)
				} else if offsetMode == HoverOffsetModeDiagonallyAbove {
					setHoverOffsetMode(HoverOffsetModeAbove, .right)
				} else if offsetMode == HoverOffsetModeHoverNoOffset {
					setHoverOffsetMode(HoverOffsetModeAbove, .up)
				}
			}
		case .right:
			switch result.firstFingerSide {
			case .left:
				if offsetMode == HoverOffsetModeHoverNoOffset {
					setHoverOffsetMode(HoverOffsetModeSideways, .right)
				} else if offsetMode == HoverOffsetModeAbove {
					setHoverOffsetMode(HoverOffsetModeDiagonallyAbove, .right)
				}
			case .right:
				if offsetMode == HoverOffsetModeSideways {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .right)
				} else if offsetMode == HoverOffsetModeDiagonallyAbove {
					setHoverOffsetMode(HoverOffsetModeAbove, .right)
				}
			}
		case .downRight:
			switch result.firstFingerSide {
			case .left:
				if offsetMode == HoverOffsetModeAbove {
					setHoverOffsetMode(HoverOffsetModeSideways, .downRight)
				} else if offsetMode == HoverOffsetModeHoverNoOffset {
					setHoverOffsetMode(HoverOffsetModeSideways, .right)
				} else if offsetMode == HoverOffsetModeDiagonallyAbove {
					setHoverOffsetMode(HoverOffsetModeSideways, .down)
				}

			case .right:
				if offsetMode == HoverOffsetModeDiagonallyAbove {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .downRight)
				} else if offsetMode == HoverOffsetModeAbove {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .down)
				} else if offsetMode == HoverOffsetModeSideways {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .right)
				}
			}
		case .down:
			if offsetMode == HoverOffsetModeAbove {
				setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .down)
			} else if offsetMode == HoverOffsetModeDiagonallyAbove {
				setHoverOffsetMode(HoverOffsetModeSideways, .down)
			}
		case .downLeft:
			switch result.firstFingerSide {
			case .left:
				if offsetMode == HoverOffsetModeDiagonallyAbove {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .downLeft)
				} else if offsetMode == HoverOffsetModeAbove {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .down)
				} else if offsetMode == HoverOffsetModeSideways {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .left)
				}
			case .right:
				if offsetMode == HoverOffsetModeAbove {
					setHoverOffsetMode(HoverOffsetModeSideways, .downLeft)
				} else if offsetMode == HoverOffsetModeDiagonallyAbove {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .down)
				} else if offsetMode == HoverOffsetModeHoverNoOffset {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .left)
				}
			}
		case .left:
			switch result.firstFingerSide {
			case .left:
				if offsetMode == HoverOffsetModeSideways {
					setHoverOffsetMode(HoverOffsetModeHoverNoOffset, .left)
				} else if offsetMode == HoverOffsetModeDiagonallyAbove {
					setHoverOffsetMode(HoverOffsetModeAbove, .left)
				}
			case .right:
				if offsetMode == HoverOffsetModeHoverNoOffset {
					setHoverOffsetMode(HoverOffsetModeSideways, .left)
				} else if offsetMode == HoverOffsetModeAbove {
					setHoverOffsetMode(HoverOffsetModeDiagonallyAbove, .left)
				}
			}
		case .upLeft:
			switch result.firstFingerSide {
			case .left:
				if offsetMode == HoverOffsetModeSideways {
					setHoverOffsetMode(HoverOffsetModeAbove, .upLeft)
				} else if offsetMode == HoverOffsetModeHoverNoOffset {
					setHoverOffsetMode(HoverOffsetModeAbove, .up)
				} else if offsetMode == HoverOffsetModeDiagonallyAbove {
					setHoverOffsetMode(HoverOffsetModeAbove, .left)
				}
			case .right:
				if offsetMode == HoverOffsetModeHoverNoOffset {
					setHoverOffsetMode(HoverOffsetModeDiagonallyAbove, .upLeft)
				} else if offsetMode == HoverOffsetModeSideways {
					setHoverOffsetMode(HoverOffsetModeDiagonallyAbove, .up)
				} else if offsetMode == HoverOffsetModeAbove {
					setHoverOffsetMode(HoverOffsetModeDiagonallyAbove, .left)
				}
			}
		case .none: break
		}
	}

	func toggleRelativeMouseMode() {
		if isRelativeMouseModeEnabled {
			objc_setRelativeMouseMode(false)
		} else {
			objc_setRelativeMouseMode(true)
		}
	}

	private func beginSecondFingerClick() async {
		resetHoverModeClickTimers()

		let wasHoverModeClicking = isHoverModeClicking

		await reportIsHoverModeClicing()

		if !wasHoverModeClicking {
			objc_ADBWriteMouseDown(0)
		}
	}

	private func toggleHoverOffsetMode(_ offsetMode: HoverOffsetMode) {
		if self.offsetMode == offsetMode {
			self.offsetMode = HoverOffsetModeOff
		} else {
			self.offsetMode = offsetMode
		}

		objc_ADBSetHoverOffsetMode(self.offsetMode)
		changeSubject.send(.hoverOffsetModeChanged(self.offsetMode))
	}

	private func setHoverOffsetMode(
		_ offsetMode: HoverOffsetMode,
		_ resultingTransition: HoverOffsetModeTransition
	) {
		self.offsetMode = offsetMode

		if MiscellaneousSettings.current.mouseHapticFeedback {
			let timeSinceMousedownHapticFeedback = Date().timeIntervalSince(objc_getLatestMouseDownHapticFeedbackTimestamp())
			if timeSinceMousedownHapticFeedback > 0.12 {
				objc_mousedownHapticFeedback()
			}
		}

		hoverOffsetModeTransitionAnimator = HoverOffsetModeTransitionAnimator(resultingTransition)

		objc_ADBSetHoverOffsetMode(offsetMode)
		changeSubject.send(.hoverOffsetModeChanged(offsetMode))
	}

	private func reportIsHoverModeClicing() async {
		isHoverModeClicking = true
	}

	private func resetHoverModeClickTimers () {
		hoverModeClickIfStilTimer?.invalidate()
		hoverModeClickIfStilTimer = nil
		hoverModeClickIfHaveNotMovedEnoughTimer?.invalidate()
		hoverModeClickIfHaveNotMovedEnoughTimer = nil
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

private class HoverOffsetModeTransitionAnimator {
	private let transition: HoverOffsetModeTransition
	private var timers = [Timer]()
	private let totalSteps: Int
	private let totalTime: TimeInterval = 0.107 // Get 8 steps with 75hz
	private let stepTime: TimeInterval

	private let beginAnimationState: ADBBeginAnimationState

	private var startTime: Date!

	init(_ transition: HoverOffsetModeTransition) {
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
		let stepX = Int(CGFloat(beginAnimationState.offset_x) * ratio)
		let stepY = Int(CGFloat(beginAnimationState.offset_y) * ratio)

		var x = beginAnimationState.x
		var y = beginAnimationState.y

		switch transition {
		case .up:
			y -= stepY
		case .upRight:
			x += stepX
			y -= stepY
		case .right:
			x += stepX
		case .downRight:
			x += stepX
			y += stepY
		case .down:
			y += stepY
		case .downLeft:
			x -= stepX
			y += stepY
		case .left:
			x -= stepX
		case .upLeft:
			x -= stepX
			y -= stepY
		default:
			break
		}

		objc_ADBAnimateMove(x, y)
	}
}
