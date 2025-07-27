//
//  OverlayView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class OverlayView: UIView {
	private var touchDictionary = [UITouch: CGFloat]()
	private var isDragging: Bool = false

	var reportDragProgress: ((CGFloat) -> Void)?
	var didBeginGesture: (() -> Void)?
	var didReleaseGesture: (() -> Void)?

	init() {
		super.init(frame: .zero)

		isMultipleTouchEnabled = true
	}
	
	required init?(coder: NSCoder) { fatalError() }

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesBegan(touches, with: event)

		for touch in touches {
			touchDictionary[touch] = touch.location(in: self).y
		}
		if touchDictionary.count >= 3 {
			isDragging = true
			didBeginGesture?()
		}
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		if isDragging {
			var totalDeltaYUp: CGFloat = 0
			var totalDeltaYDown: CGFloat = 0

			for touch in touches {
				guard let previousYPos = touchDictionary[touch] else {
					print("-- unexpected")
					continue
				}
				let newYPos = touch.location(in: self).y
				let deltaY = newYPos - previousYPos
				if deltaY < 0 {
					totalDeltaYUp = min(deltaY, totalDeltaYUp)
				} else {
					totalDeltaYDown = max(deltaY, totalDeltaYDown)
				}
				touchDictionary[touch] = newYPos
			}
			let totalDeltaY = totalDeltaYUp + totalDeltaYDown
			reportDragProgress?(totalDeltaY)
		} else {
			super.touchesMoved(touches, with: event)
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesEnded(touches, with: event)

		for touch in touches {
			touchDictionary[touch] = nil
		}
		if touchDictionary.isEmpty {
			isDragging = false
			didReleaseGesture?()
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
}
