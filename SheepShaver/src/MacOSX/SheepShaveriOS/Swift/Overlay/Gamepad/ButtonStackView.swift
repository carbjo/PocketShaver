//
//  ButtonStackView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class ButtonStackView: UIStackView {
	private let isRightHandSide: Bool
	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)
	
	init(
		isRightHandSide: Bool,
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		self.isRightHandSide = isRightHandSide
		self.pushKey = pushKey
		self.releaseKey = releaseKey

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		axis = .horizontal
		spacing = 4

		setupButtons()
	}
	
	required init(coder: NSCoder) { fatalError() }

	private func setupButtons() {
		let screenWidth = UIScreen.main.bounds.width
		let sideMargin: CGFloat = UIDevice.hasNotch ? 64 : 8
		let availableWidth = (screenWidth / 2) - sideMargin
		let buttonLength: CGFloat = UIDevice.hasNotch ? 80 : 64
		let elementWidth = buttonLength + (spacing * 2)

		let numberOfButtons = Int(floor(availableWidth / elementWidth))

		print("-- numberOfButtons \(numberOfButtons)")

		for _ in 0..<numberOfButtons {
			addArrangedSubview(UnassignedButton())
		}
	}

	func set(_ key: SDLKey, at index: Int) {
		let sideCorrectedIndex = isRightHandSide ? (arrangedSubviews.count - 1 - index) : index
		let oldView = arrangedSubviews[sideCorrectedIndex]
		removeArrangedSubview(oldView)
		oldView.removeFromSuperview()

		insertArrangedSubview(
			Button(
				key: key,
				pushKey: pushKey,
				releaseKey: releaseKey
			),
			at: sideCorrectedIndex
		)
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		// Only consider touches to the buttons or spacing cells as
		// touches that belongs to this stack view.
		// Ie. not when touching the spaces between the buttons or spacing cells.

		for view in arrangedSubviews {
			guard let button = view as? Button else {
				continue
			}
			let pointInSubviewCoordinateSpace = button.convert(point, from: self)
			if button.point(inside: pointInSubviewCoordinateSpace, with: event) {
				return true
			}
		}

		return false
	}
}
