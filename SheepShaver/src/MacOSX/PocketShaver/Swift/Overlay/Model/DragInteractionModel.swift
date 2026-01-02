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

@MainActor
class DragInteractionModel {
	var threeFingerGestureDragDelta: CGVector = .zero
	var threeFingerGestureDragDeltaSinceLatestHapticFeedback: CGVector = .zero

	var sdlViewVerticalOffset: CGFloat = .zero
	var twoFingerGestureDragDeltaSinceLatestHapticFeedback: CGFloat = .zero

	private let dragHapticFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

	private let fetchState: () -> OverlayState
	private let fetchFrameSize: () -> CGSize
	private let transformMainGamepadLayoutView: (CGAffineTransform) -> Void
	private let transformAllGamepadLayoutViews: (CGAffineTransform) -> Void
	private let transformSDLView: (CGAffineTransform) -> Void

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

		let threshold = fetchFrameSize().height / 6

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

	func resetSdlViewVerticalOffset() {
		sdlViewVerticalOffset = .zero
	}

	private func triggerDragHapticFeedback() {
		if MiscellaneousSettings.current.gestureHapticFeedback {
			self.dragHapticFeedbackGenerator.impactOccurred()
		}

		twoFingerGestureDragDeltaSinceLatestHapticFeedback = .zero
		threeFingerGestureDragDeltaSinceLatestHapticFeedback = .zero
	}
}
