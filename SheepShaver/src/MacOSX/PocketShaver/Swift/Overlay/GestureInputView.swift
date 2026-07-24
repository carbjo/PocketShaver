//
//  GestureInputView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class GestureInputView: UIView {
	enum DraggingMode {
		case none
		case twoFingers
		case threeFingers
	}

	enum TwoFingerGestureFingerRelease {
		case firstFinger
		case secondFinger
		case both
	}

	private var touchDictionary = [UITouch: CGPoint]()
	private var draggingMode: DraggingMode = .none
	private var secondFingerTouch: UITouch?
	private var state: OverlayState

	var isDragging: Bool {
		draggingMode != .none
	}

	var reportTwoFingerDragProgress: ((CGFloat) -> Void)?
	var reportThreeFingerDragProgress: ((CGVector) -> Void)?
	var reportSecondFingerDragProgress: ((CGVector) -> Void)?
	var didBeginThreeFingerGesture: (() -> Void)?
	var didReleaseThreeFingerGesture: (() -> Void)?
	var didBeginTwoFingerGesture: (() -> Void)?
	var didReleaseTwoFingerGesture: (() -> Void)?
	var didReleaseOneFingerDuringTwoFingerGesture: ((TwoFingerGestureFingerRelease) -> Void)?

	init(state: OverlayState) {
		self.state = state

		super.init(frame: .zero)

		isMultipleTouchEnabled = true
		backgroundColor = .darkGray.withAlphaComponent(0)

	}

#if targetEnvironment(macCatalyst)
	// Mac Catalyst mouse-position bypass. SDL's Catalyst window transposes to
	// portrait on unfocus/refocus and clamps mouse-x, so the guest cursor is
	// driven from the real UIKit pointer location instead. Buttons continue to
	// flow through SDL. Hover covers button-up moves; touchesMoved (below) covers
	// button-down drags.
	private weak var catalystHover: UIHoverGestureRecognizer?

	override func didMoveToWindow() {
		super.didMoveToWindow()
		// Attach the hover recognizer to the WINDOW, not this view: the compositor
		// keeps the window at the true full size, but SDL's transposed view
		// geometry could shrink this view's width and clip the pointer at the same
		// wrong edge we're trying to escape.
		if let window, catalystHover == nil {
			let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleCatalystPointerHover(_:)))
			window.addGestureRecognizer(hover)
			catalystHover = hover
		}
	}

	@objc private func handleCatalystPointerHover(_ recognizer: UIHoverGestureRecognizer) {
		guard state != .editingGamepad, let window else { return }
		let p = recognizer.location(in: window)
		objc_ADBMouseMovedFromWindowPoint(p.x, p.y)
	}
#endif
	
	required init?(coder: NSCoder) { fatalError() }

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		if state != .editingGamepad {
			super.touchesBegan(touches, with: event)
		}

		if touchDictionary.count == 1,
		   secondFingerTouch == nil {
			secondFingerTouch = Array(touches).first!
		}

		for touch in touches {
			touchDictionary[touch] = touch.location(in: self)
		}

		if touchDictionary.count >= 3 {
			draggingMode = .threeFingers
			didBeginThreeFingerGesture?()
		} else if touchDictionary.count >= 2 {
			draggingMode = .twoFingers
			didBeginTwoFingerGesture?()
		 }

#if !targetEnvironment(macCatalyst)
		// iOS: snap the guest cursor to the steering finger the instant it lands
		// (draggingMode is set above so the three-finger guard applies here too).
		// Inert outside hover mode — VideoMapWindowPointToGuestAndMove no-ops.
		forwardSteeringTouchPosition(from: touches)
#endif
	}

#if !targetEnvironment(macCatalyst)
	// Forwards the steering finger's absolute window position to the guest cursor
	// so it tracks that finger. The steering finger is the tracked finger that is
	// not the second (click) finger, chosen with a STABLE ordering (min hashValue)
	// so the pick never alternates between fingers within a gesture — otherwise a
	// simultaneous two-finger landing (which never populates secondFingerTouch)
	// would flip between fingers and reintroduce the bounce. Only the steering
	// finger drives the cursor, so a resting/clicking second finger never moves
	// it; three-finger gestures (gamepad switching) don't move it at all. The C++
	// side ignores SDL's own synthesized touch motion while hover mode owns the
	// cursor, so this is the single cursor driver during two-finger steering.
	private func forwardSteeringTouchPosition(from touches: Set<UITouch>) {
		guard state != .editingGamepad, draggingMode != .threeFingers, let window else {
			return
		}
		let steeringTouch = touchDictionary.keys
			.filter { $0 != secondFingerTouch }
			.min { $0.hashValue < $1.hashValue }
		guard let steeringTouch, touches.contains(steeringTouch) else {
			return
		}
		let p = steeringTouch.location(in: window)
		objc_ADBMouseMovedFromWindowPoint(p.x, p.y)
	}
#endif

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesMoved(touches, with: event)

#if targetEnvironment(macCatalyst)
		// A Catalyst mouse drag (button held) arrives as a single touch; feed its
		// position through the same bypass as hover (UIHoverGestureRecognizer only
		// fires with no button pressed).
		if state != .editingGamepad, touchDictionary.count == 1,
		   let touch = touches.first, let window {
			let p = touch.location(in: window)
			objc_ADBMouseMovedFromWindowPoint(p.x, p.y)
		}
#endif

#if !targetEnvironment(macCatalyst)
		// iOS: drive the guest cursor from the steering finger only (see above).
		forwardSteeringTouchPosition(from: touches)
#endif

		if let secondFingerTouch,
		   let prevSecondFingerPos = touchDictionary[secondFingerTouch] {
			let newSecondFingerPos = secondFingerTouch.location(in: self)
			let secondFingerTouchDelta = CGVector(
				dx: newSecondFingerPos.x - prevSecondFingerPos.x,
				dy: newSecondFingerPos.y - prevSecondFingerPos.y
			)
			if secondFingerTouchDelta != .zero {
				reportSecondFingerDragProgress?(secondFingerTouchDelta)
			}
		}

		if draggingMode != .none {
			var totalDeltaXUp: CGFloat = 0
			var totalDeltaXDown: CGFloat = 0
			var totalDeltaYUp: CGFloat = 0
			var totalDeltaYDown: CGFloat = 0

			for touch in touches {
				guard let previousPos = touchDictionary[touch] else {
					print("-- unexpected")
					continue
				}
				let newXPos = touch.location(in: self).x
				let deltaX = newXPos - previousPos.x
				if deltaX < 0 {
					totalDeltaXUp = min(deltaX, totalDeltaXUp)
				} else {
					totalDeltaXDown = max(deltaX, totalDeltaXDown)
				}

				let newYPos = touch.location(in: self).y
				let deltaY = newYPos - previousPos.y
				if deltaY < 0 {
					totalDeltaYUp = min(deltaY, totalDeltaYUp)
				} else {
					totalDeltaYDown = max(deltaY, totalDeltaYDown)
				}

				touchDictionary[touch] = .init(x: newXPos, y: newYPos)
			}
			
			let totalDeltaX = totalDeltaXUp + totalDeltaXDown
			let totalDeltaY = totalDeltaYUp + totalDeltaYDown

			switch draggingMode {
			case .twoFingers:
				reportTwoFingerDragProgress?(totalDeltaY)
			case .threeFingers:
				reportThreeFingerDragProgress?(.init(dx: totalDeltaX, dy: totalDeltaY))
			default:
				fatalError()
			}
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesEnded(touches, with: event)

		for touch in touches {
			touchDictionary[touch] = nil
		}

		if draggingMode == .twoFingers {
			let fingerRelease: TwoFingerGestureFingerRelease
			if touches.count > 1 || touchDictionary.isEmpty {
				fingerRelease = .both
			} else if touches.first == secondFingerTouch {
				fingerRelease = .secondFinger
			} else {
				fingerRelease = .firstFinger
			}
			didReleaseOneFingerDuringTwoFingerGesture?(fingerRelease)
		}

		if (secondFingerTouch != nil && touches.contains(secondFingerTouch!)) || touchDictionary.isEmpty {
			self.secondFingerTouch = nil
		}

		if touchDictionary.isEmpty {
			let draggingModeAtRelease = draggingMode
			draggingMode = .none
			switch draggingModeAtRelease {
			case .threeFingers:
				didReleaseThreeFingerGesture?()
			case .twoFingers:
				didReleaseTwoFingerGesture?()
			default: break
			}
		}
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesCancelled(touches, with: event)
		
		for touch in touches {
			touchDictionary[touch] = nil
		}
		if touchDictionary.count <= 1 {
			secondFingerTouch = nil
		}
		if touchDictionary.isEmpty {
			let wasThreeFingerDragging = draggingMode == .threeFingers
			draggingMode = .none
			if wasThreeFingerDragging {
				didReleaseThreeFingerGesture?()
			}
		}
	}

	func set(state: OverlayState) {
		let previousState = self.state
		self.state = state

		if previousState != .editingGamepad && state == .editingGamepad {
			UIView.animate(withDuration: 0.3) {
				self.backgroundColor = .darkGray.withAlphaComponent(0.8)
			}
		} else if previousState == .editingGamepad && state != .editingGamepad {
			UIView.animate(withDuration: 0.3) {
				self.backgroundColor = .darkGray.withAlphaComponent(0)
			}
		}
	}
}
