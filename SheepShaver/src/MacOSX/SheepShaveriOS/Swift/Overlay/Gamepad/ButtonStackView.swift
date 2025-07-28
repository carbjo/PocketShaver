//
//  ButtonStackView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class ButtonStackView: UIStackView {
	private let side: GamepadSide
	private let row: Int
	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)
	private let didRequestAssignmentAtIndex: ((Int) -> Void)

	private var isEditing: Bool = false

	init(
		side: GamepadSide,
		row: Int,
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void),
		didRequestAssignmentAtIndex: @escaping ((Int) -> Void)
	) {
		self.side = side
		self.row = row
		self.pushKey = pushKey
		self.releaseKey = releaseKey
		self.didRequestAssignmentAtIndex = didRequestAssignmentAtIndex

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

		for index in 0..<numberOfButtons {
			let sideCorrectedIndex = side == .right ? (numberOfButtons - 1 - index) : index

			addArrangedSubview(createUnassignedButton(forIndex: sideCorrectedIndex))
		}
	}

	func set(_ key: SDLKey, at index: Int) {
		let sideCorrectedIndex = side == .right ? (arrangedSubviews.count - 1 - index) : index
		let oldView = arrangedSubviews[sideCorrectedIndex]
		removeArrangedSubview(oldView)
		oldView.removeFromSuperview()

		let button = Button(
			key: key,
			index: index,
			isEditing: isEditing,
			pushKey: pushKey,
			releaseKey: releaseKey
		) { [weak self] index in
			guard let self else { return }
			didRequestAssignmentAtIndex(index)
		}

		insertArrangedSubview(
			button,
			at: sideCorrectedIndex
		)
	}

	func set(isEditing: Bool) {
		self.isEditing = isEditing

		for button in arrangedSubviews {
			if let button = button as? Button {
				button.set(isEditing: isEditing)
			} else if let button = button as? UnassignedButton {
				button.set(isEditing: isEditing)
			}
		}
	}

	func reset() {
		let numberOfButtons = arrangedSubviews.count

		for (index, button) in arrangedSubviews.enumerated() {
			if let button = button as? Button {
				let sideCorrectedIndex = side == .right ? (numberOfButtons - 1 - index) : index
				removeArrangedSubview(button)
				button.removeFromSuperview()
				insertArrangedSubview(
					createUnassignedButton(forIndex: sideCorrectedIndex),
					at: index
				)
			}
		}
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		// Only consider touches to the buttons or spacing cells as
		// touches that belongs to this stack view.
		// Ie. not when touching the spaces between the buttons or spacing cells.

		for view in arrangedSubviews {
			guard view is Button || isEditing else {
				continue
			}

			let pointInSubviewCoordinateSpace = view.convert(point, from: self)
			if view.point(inside: pointInSubviewCoordinateSpace, with: event) {
				return true
			}
		}

		return false
	}

	private func createUnassignedButton(forIndex index: Int) -> UnassignedButton {
		UnassignedButton(
			index: index,
			isEditing: isEditing
		) { [weak self] index in
			guard let self else { return }
			didRequestAssignmentAtIndex(index)
		}
	}
}
