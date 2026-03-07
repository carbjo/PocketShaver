//
//  DragInteractionModel.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-01.
//

import UIKit

struct ThreeFingerReleaseResult {
	enum GamepadChange {
		case none
		case next
		case previous
	}

	let state: OverlayState
	let gamepadChange: GamepadChange
	let willTranslateInLongAxis: Bool
}

enum HoverOffsetModeTransition {
	case none
	case up
	case upRight
	case right
	case downRight
	case down
	case downLeft
	case left
	case upLeft
}

struct SecondFingerReleaseResult {
	enum FirstFingerSide {
		case left
		case right
	}

	let swipeResult: HoverOffsetModeTransition
	let firstFingerSide: FirstFingerSide
}

@MainActor
class DragInteractionModel {
	private var threeFingerGestureDragDelta: CGVector = .zero
	private var threeFingerGestureDragDeltaSinceLatestHapticFeedback: CGVector = .zero

	private var sdlViewVerticalOffset: CGFloat = .zero
	private var twoFingerGestureDragDeltaSinceLatestHapticFeedback: CGFloat = .zero

	private var secondFingerGestureDragDelta: CGVector = .zero

	private let dragHapticFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

	private let fetchState: () -> OverlayState
	private let fetchFrameSize: () -> CGSize
	private let transformMainGamepadLayoutView: (CGAffineTransform) -> Void
	private let transformAllGamepadLayoutViews: (CGAffineTransform) -> Void
	private let transformSDLView: (CGAffineTransform) -> Void

	var hasDraggedSecondFingerOverThreshold: ((SecondFingerReleaseResult) -> Void)?
	private var hasReportedDraggedSecondFingerOverThreshold = false

	private var state: OverlayState {
		fetchState()
	}

	init(
		fetchState: @escaping () -> OverlayState,
		fetchFrameSize: @escaping  () -> CGSize,
		transformMainGamepadLayoutView: @escaping (CGAffineTransform) -> Void,
		transformAllGamepadLayoutViews: @escaping (CGAffineTransform) -> Void,
		transformSDLView: @escaping (CGAffineTransform) -> Void
	) {
		self.fetchState = fetchState
		self.fetchFrameSize = fetchFrameSize
		self.transformMainGamepadLayoutView = transformMainGamepadLayoutView
		self.transformAllGamepadLayoutViews = transformAllGamepadLayoutViews
		self.transformSDLView = transformSDLView
	}

	func handleThreeFingerDragProgress(_ delta: CGVector) {
		threeFingerGestureDragDelta += delta
		threeFingerGestureDragDeltaSinceLatestHapticFeedback += delta

		if threeFingerGestureDragDeltaSinceLatestHapticFeedback.abs > 60 {
			triggerDragHapticFeedback()
		}

		switch state {
		case .normal:
			let x = threeFingerGestureDragDelta.dx
			let y = threeFingerGestureDragDelta.dy - fetchFrameSize().width
			transformMainGamepadLayoutView(.init(translationX: x, y: y))
		case .showingGamepad:
			let x = threeFingerGestureDragDelta.dx
			let y = threeFingerGestureDragDelta.dy
			transformMainGamepadLayoutView(.init(translationX: x, y: y))
		case .editingGamepad:
			let x = threeFingerGestureDragDelta.dx
			let y = threeFingerGestureDragDelta.dy
			transformMainGamepadLayoutView(.init(translationX: x, y: y))
		default:
			break
		}
	}

	func handleReleaseThreeFingerGesture() -> ThreeFingerReleaseResult {
		var gamepadChange: ThreeFingerReleaseResult.GamepadChange = .none

		let threshold = min(fetchFrameSize().height / 6, 67)

		var willTranslateInLongAxis = false
		if state == .showingGamepad {
			let absDx = abs(threeFingerGestureDragDelta.dx)
			let absDy = abs(threeFingerGestureDragDelta.dy)
			willTranslateInLongAxis = UIScreen.isPortraitMode ? absDx < absDy : absDx > absDy
		}

		let resultingState: OverlayState
		switch state {
		case .normal:
			if threeFingerGestureDragDelta.dy > threshold {
				resultingState = .showingGamepad
			} else if threeFingerGestureDragDelta.dy < -threshold {
				resultingState = .showingKeyboard
			} else {
				resultingState = .normal
			}
		case .showingGamepad:
			if abs(threeFingerGestureDragDelta.dy) > abs(threeFingerGestureDragDelta.dx) {
				if threeFingerGestureDragDelta.dy > threshold {
					resultingState = .editingGamepad
				} else if threeFingerGestureDragDelta.dy < -threshold {
					resultingState = .normal
				} else {
					resultingState = .showingGamepad
				}
			} else {
				if threeFingerGestureDragDelta.dx > threshold {
					gamepadChange = .previous
				} else if threeFingerGestureDragDelta.dx < -threshold {
					gamepadChange = .next
				}
				resultingState = .showingGamepad
			}
		case .showingKeyboard:
			resultingState = .showingKeyboard
		case .editingGamepad:
			if threeFingerGestureDragDelta.dy < -threshold {
				resultingState = .showingGamepad
			} else {
				resultingState = .editingGamepad
			}
		}

		threeFingerGestureDragDelta = .zero
		hasReportedDraggedSecondFingerOverThreshold = false

		return .init(
			state: resultingState,
			gamepadChange: gamepadChange,
			willTranslateInLongAxis: willTranslateInLongAxis
		)
	}

	func handleTwoFingerDragProgress(_ verticalDelta: CGFloat) {
		guard state == .showingKeyboard else {
			return
		}
		
		sdlViewVerticalOffset += verticalDelta
		twoFingerGestureDragDeltaSinceLatestHapticFeedback += verticalDelta

		if abs(twoFingerGestureDragDeltaSinceLatestHapticFeedback) > 60 {
			triggerDragHapticFeedback()
		}

		let screenHeight = UIScreen.main.bounds.height
		let limit = -screenHeight * (2/3)
		let y: CGFloat
		if sdlViewVerticalOffset > 0 {
			y = 0
		} else if sdlViewVerticalOffset < limit {
			y = limit
		} else {
			y = sdlViewVerticalOffset
		}

		let transform = CGAffineTransform(translationX: 0, y: y)

		transformSDLView(transform)
	}

	func handleSecondFingerDragProgress(_ delta: CGVector) {
		guard MiscellaneousSettings.current.secondFingerSwipe,
			  !MiscellaneousSettings.current.iPadMousePassthrough,
			  !hasReportedDraggedSecondFingerOverThreshold else {
			return
		}

		secondFingerGestureDragDelta += delta

		let threshold: CGFloat = 50
		
		if secondFingerGestureDragDelta.abs > threshold {
			hasReportedDraggedSecondFingerOverThreshold = true
			let result = getSecondFingerReleaseResult()
			secondFingerGestureDragDelta = .zero
			hasDraggedSecondFingerOverThreshold?(result)
		}
	}

	func handleFinishTwoFingerGesture() {
		hasReportedDraggedSecondFingerOverThreshold = false
	}

	private func getSecondFingerReleaseResult() -> SecondFingerReleaseResult {
		let twoPi = CGFloat.pi * 2
		let angle = atan2(secondFingerGestureDragDelta.dy, secondFingerGestureDragDelta.dx)

		let firstFingerSide: SecondFingerReleaseResult.FirstFingerSide
		if objc_ADBHoverGestureStartWasLeftSide() {
			firstFingerSide = .left
		} else {
			firstFingerSide = .right
		}

		var swipeResult: HoverOffsetModeTransition = .none
		if angle > twoPi * (-1/16),
		   angle < twoPi * (1/16) {
			swipeResult = .right
		} else if angle >= twoPi * (1/16),
				  angle < twoPi * (3/16) {
			swipeResult = .downRight
		} else if angle >= twoPi * (3/16),
				  angle < twoPi * (5/16) {
			swipeResult = .down
		} else if angle >= twoPi * (5/16),
				  angle < twoPi * (7/16) {
			swipeResult = .downLeft
		} else if angle > twoPi * (7/16) ||
					angle < twoPi * (-7/16) {
			swipeResult = .left
		} else if angle > twoPi * (-7/16) &&
					angle < twoPi * (-5/16) {
			swipeResult = .upLeft
		} else if angle > twoPi * (-5/16) &&
					angle < twoPi * (-3/16) {
			swipeResult = .up
		} else if angle > twoPi * (-3/16) &&
					angle < twoPi * (-1/16) {
			swipeResult = .upRight
		}

		return .init(swipeResult: swipeResult, firstFingerSide: firstFingerSide)
	}

	func resetSdlViewVerticalOffset() {
		sdlViewVerticalOffset = .zero
	}

	func set(sdlViewVerticalOffset: CGFloat) {
		self.sdlViewVerticalOffset = sdlViewVerticalOffset
	}

	private func triggerDragHapticFeedback() {
		if MiscellaneousSettings.current.gestureHapticFeedback {
			self.dragHapticFeedbackGenerator.impactOccurred()
		}

		twoFingerGestureDragDeltaSinceLatestHapticFeedback = .zero
		threeFingerGestureDragDeltaSinceLatestHapticFeedback = .zero
	}
}
