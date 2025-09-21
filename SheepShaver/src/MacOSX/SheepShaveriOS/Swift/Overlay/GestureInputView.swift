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

	private var touchDictionary = [UITouch: CGPoint]()
	private var draggingMode: DraggingMode = .none
	private var state: OverlayState

	var isDragging: Bool {
		draggingMode != .none
	}

	var reportTwoFingerDragProgress: ((CGFloat) -> Void)?

	var reportThreeFingerDragProgress: ((CGVector) -> Void)?
	var didBeginThreeFingerGesture: (() -> Void)?
	var didReleaseThreeFingerGesture: (() -> Void)?


	init(state: OverlayState) {
		self.state = state

		super.init(frame: .zero)

		isMultipleTouchEnabled = true
		backgroundColor = .darkGray.withAlphaComponent(0)
	}
	
	required init?(coder: NSCoder) { fatalError() }

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		if state != .editingGamepad {
			super.touchesBegan(touches, with: event)
		}

		for touch in touches {
			touchDictionary[touch] = touch.location(in: self)
		}

		if touchDictionary.count >= 3 {
			draggingMode = .threeFingers
			didBeginThreeFingerGesture?()
		} else if state == .showingKeyboard,
				  touchDictionary.count >= 2 {
			draggingMode = .twoFingers
		 }
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesMoved(touches, with: event)

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
		if touchDictionary.isEmpty {
			let wasThreeFingerDragging = draggingMode == .threeFingers
			draggingMode = .none
			if wasThreeFingerDragging {
				didReleaseThreeFingerGesture?()
			}
		}
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesCancelled(touches, with: event)
		
		for touch in touches {
			touchDictionary[touch] = nil
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
