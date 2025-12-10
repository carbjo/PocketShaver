//
//  GamepadButtonStackView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class GamepadButtonStackView: UIStackView {
	private let side: GamepadSide
	private let row: Int
	private let keyInteraction: ((Int, Bool) -> Void)
	private let specialButtonInteraction: ((SpecialButton, Bool) -> Void)
	private let didRequestAssignmentAtIndex: ((Int) -> Void)

	private var isEditing: Bool = false

	init(
		side: GamepadSide,
		row: Int,
		keyInteraction: @escaping ((Int, Bool) -> Void),
		specialButtonInteraction: @escaping ((SpecialButton, Bool) -> Void),
		didRequestAssignmentAtIndex: @escaping ((Int) -> Void)
	) {
		self.side = side
		self.row = row
		self.keyInteraction = keyInteraction
		self.specialButtonInteraction = specialButtonInteraction
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
		let sideMargin: CGFloat = UIScreen.sideMarginForButtons

		let settingsButtonLength: CGFloat = UIScreen.isSmallSize ? 36 : 44
		let halfSettingsButton: CGFloat = settingsButtonLength/2
		let availableWidth = (screenWidth / 2) - sideMargin - halfSettingsButton
		let buttonLength = GamepadButton.length
		let elementWidth = buttonLength + spacing

		let numberOfButtons = max(2, Int(floor(availableWidth / elementWidth)))

		for index in 0..<numberOfButtons {
			let sideCorrectedIndex = side == .right ? (numberOfButtons - 1 - index) : index

			addArrangedSubview(createUnassignedButton(forIndex: sideCorrectedIndex))
		}
	}

	func set(_ key: SDLKey, at index: Int) {
		guard let sideCorrectedIndex = getSideCorrectedIndex(for: index) else {
			return
		}

		let oldView = arrangedSubviews[sideCorrectedIndex]
		removeArrangedSubview(oldView)
		oldView.removeFromSuperview()

		let button = GamepadButton(
			text: key.label,
			isEditing: isEditing,
			pushKey: { [weak self] in
				// TODO: Which value is dependent on keyboard layout is chosen in simlated OS.
				// Should not assume EN layout, specifically
				self?.keyInteraction(key.enValue, true)
			},
			releaseKey: { [weak self] in
				self?.keyInteraction(key.enValue, false)
			},
			didRequestAssignment:  { [weak self] in
				self?.didRequestAssignmentAtIndex(index)
			}
		)

		insertArrangedSubview(
			button,
			at: sideCorrectedIndex
		)
	}

	func set(_ specialButton: SpecialButton, at index: Int) {
		guard let sideCorrectedIndex = getSideCorrectedIndex(for: index) else {
			return
		}

		let oldView = arrangedSubviews[sideCorrectedIndex]
		removeArrangedSubview(oldView)
		oldView.removeFromSuperview()

		let button = GamepadButton(
			text: specialButton.label,
			isEditing: isEditing,
			pushKey: { [weak self] in
				// TODO: Which value is dependent on keyboard layout is chosen in simlated OS.
				// Should not assume EN layout, specifically
				self?.specialButtonInteraction(specialButton, true)
			},
			releaseKey: { [weak self] in
				self?.specialButtonInteraction(specialButton, false)
			},
			didRequestAssignment:  { [weak self] in
				self?.didRequestAssignmentAtIndex(index)
			}
		)

		insertArrangedSubview(
			button,
			at: sideCorrectedIndex
		)
	}

	func set(isEditing: Bool) {
		self.isEditing = isEditing

		for button in arrangedSubviews {
			if let button = button as? GamepadButton {
				button.set(isEditing: isEditing)
			} else if let button = button as? UnassignedGamepadButton {
				button.set(isEditing: isEditing)
			}
		}
	}

	func reset() {
		let numberOfButtons = arrangedSubviews.count

		for (index, button) in arrangedSubviews.enumerated() {
			if let button = button as? GamepadButton {
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
			guard view is GamepadButton || isEditing else {
				continue
			}

			let pointInSubviewCoordinateSpace = view.convert(point, from: self)
			if view.point(inside: pointInSubviewCoordinateSpace, with: event) {
				return true
			}
		}

		return false
	}

	private func createUnassignedButton(forIndex index: Int) -> UnassignedGamepadButton {
		UnassignedGamepadButton(
			isEditing: isEditing
		) { [weak self] in
			self?.didRequestAssignmentAtIndex(index)
		}
	}

	private func getSideCorrectedIndex(for index: Int) -> Int? {
		let sideCorrectedIndex = side == .right ? (arrangedSubviews.count - 1 - index) : index
		guard sideCorrectedIndex >= 0,
			  sideCorrectedIndex < arrangedSubviews.count else {
			return nil
		}

		return sideCorrectedIndex
	}
}
