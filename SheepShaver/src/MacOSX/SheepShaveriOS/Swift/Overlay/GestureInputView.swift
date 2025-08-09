//
//  GestureInputView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class GestureInputView: UIView {
	private var touchDictionary = [UITouch: CGPoint]()
	private(set) var isDragging: Bool = false
	private(set) var isEditing: Bool = false

	var reportDragProgress: ((CGVector) -> Void)?
	var didBeginGesture: (() -> Void)?
	var didReleaseGesture: (() -> Void)?

	init() {
		super.init(frame: .zero)

		isMultipleTouchEnabled = true
		backgroundColor = .darkGray.withAlphaComponent(0)
	}
	
	required init?(coder: NSCoder) { fatalError() }

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		if !isEditing {
			super.touchesBegan(touches, with: event)
		}

		for touch in touches {
			touchDictionary[touch] = touch.location(in: self)
		}
		if touchDictionary.count >= 3 {
			isDragging = true
			didBeginGesture?()
		}
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesMoved(touches, with: event)

		if isDragging {
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
			reportDragProgress?(.init(dx: totalDeltaX, dy: totalDeltaY))
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesEnded(touches, with: event)

		for touch in touches {
			touchDictionary[touch] = nil
		}
		if touchDictionary.isEmpty {
			let wasDragging = isDragging
			isDragging = false
			if wasDragging {
				didReleaseGesture?()
			}
		}
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesCancelled(touches, with: event)
		
		for touch in touches {
			touchDictionary[touch] = nil
		}
		if touchDictionary.isEmpty {
			isDragging = false
			didReleaseGesture?()
		}
	}

	func set(isEditing: Bool) {
		let wasEditing = self.isEditing
		self.isEditing = isEditing

		if !wasEditing && isEditing {
			UIView.animate(withDuration: 0.3) {
				self.backgroundColor = .darkGray.withAlphaComponent(0.8)
			}
		} else if wasEditing && !isEditing {
			UIView.animate(withDuration: 0.3) {
				self.backgroundColor = .darkGray.withAlphaComponent(0)
			}
		}
	}
}
