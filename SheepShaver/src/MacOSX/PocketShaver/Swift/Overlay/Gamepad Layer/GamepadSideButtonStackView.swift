//
//  GamepadSideButtonStackView.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-30.
//

import UIKit

class GamepadSideButtonStackView: UIStackView {
	private let inputInteractionModel: InputInteractionModel
	private let didRequestAssignmentAtIndex: ((Int) -> Void)

	private var isEditing: Bool = false

	init(
		sideButtonLayout: GamepadSideButtonLayout,
		horizontalAnchor: NSLayoutXAxisAnchor,
		verticalAnchor: NSLayoutYAxisAnchor,
		inputInteractionModel: InputInteractionModel,
		didRequestAssignmentAtIndex: @escaping ((Int) -> Void)
	) {
		self.inputInteractionModel = inputInteractionModel
		self.didRequestAssignmentAtIndex = didRequestAssignmentAtIndex

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false

		axis = .vertical
		spacing = sideButtonLayout.spacing

		for index in 0..<sideButtonLayout.numberOfSlots {
			let unassignedButton = createUnassignedButton(forIndex: index)

			NSLayoutConstraint.activate([
				unassignedButton.widthAnchor.constraint(equalToConstant: GamepadButtonSize.small.length),
				unassignedButton.heightAnchor.constraint(equalToConstant: GamepadButtonSize.small.length)
			])

			addArrangedSubview(unassignedButton)
		}
	}

	required init(coder: NSCoder) { fatalError() }

	func set(_ assignment: GamepadButtonAssignment, index: Int) {
		switch assignment {
		case .key(let key):
			set(key, at: index)
		case .specialButton(let specialButton):
			set(specialButton, at: index)
		case .joystick:
			fatalError()
		}
	}

	func set(_ key: SDLKey, at index: Int) {
		removeViewAt(index)

		let button = GamepadButton(
			label: .text(key.label.uppercased()),
			buttonSize: .small,
			inputInteractionModel: inputInteractionModel,
			isEditing: isEditing,
			pushKey: { [weak self] in
				// TODO: Which value is dependent on keyboard layout is chosen in simlated OS.
				// Should not assume EN layout, specifically
				self?.inputInteractionModel.handle(
					key,
					isDown: true,
					hapticAllowed: true
				)
			},
			releaseKey: { [weak self] in
				self?.inputInteractionModel.handle(
					key,
					isDown: false,
					hapticAllowed: true
				)
			},
			didRequestAssignment:  { [weak self] in
				self?.didRequestAssignmentAtIndex(index)
			}
		)

		insertArrangedSubview(
			button,
			at: index
		)
	}

	func set(_ specialButton: SpecialButton, at index: Int) {
		removeViewAt(index)

		let button = GamepadButton(
			label: specialButton.gamepadLabel,
			buttonSize: .small,
			specialButtonConfig: specialButton,
			inputInteractionModel: inputInteractionModel,
			isEditing: isEditing,
			pushKey: { [weak self] in
				self?.inputInteractionModel.handle(
					specialButton,
					isDown: true
				)
			},
			releaseKey: { [weak self] in
				self?.inputInteractionModel.handle(
					specialButton,
					isDown: false
				)
			},
			didRequestAssignment:  { [weak self] in
				self?.didRequestAssignmentAtIndex(index)
			}
		)

		insertArrangedSubview(
			button,
			at: index
		)
	}

	func set(isEditing: Bool) {
		self.isEditing = isEditing

		for view in arrangedSubviews {
			if let button = view as? GamepadButton {
				button.set(isEditing: isEditing)
			} else if let button = view as? UnassignedGamepadButton {
				button.set(isEditing: isEditing)
			}
		}

		var highestAssignedButtonIndex = -1
		for index in 0..<arrangedSubviews.count {
			if !(arrangedSubviews[index] is UnassignedGamepadButton) {
				highestAssignedButtonIndex = index
			}
		}

		if highestAssignedButtonIndex > -1,
		   highestAssignedButtonIndex < arrangedSubviews.count - 1,
		   let nextButtonAsUnassigned = arrangedSubviews[highestAssignedButtonIndex + 1] as? UnassignedGamepadButton {
			if isEditing {
				nextButtonAsUnassigned.isHidden = false
				nextButtonAsUnassigned.alpha = 1
			} else {
				nextButtonAsUnassigned.isHidden = true
				nextButtonAsUnassigned.alpha = 0
			}
		}
	}

	func updateSlotVisiblity() {
		guard arrangedSubviews.count > 1 else {
			return
		}

		if let secondButtonAsUnassigned = arrangedSubviews[1] as? UnassignedGamepadButton,
		   secondButtonAsUnassigned.isHidden {
			secondButtonAsUnassigned.isHidden = false
			secondButtonAsUnassigned.alpha = 1
		} else if arrangedSubviews[0] is UnassignedGamepadButton,
				  let secondButtonAsUnassigned = arrangedSubviews[1] as? UnassignedGamepadButton,
				  !secondButtonAsUnassigned.isHidden {
			secondButtonAsUnassigned.isHidden = true
			secondButtonAsUnassigned.alpha = 0
		}
	}

	private func removeViewAt(_ index: Int) {
		let oldView = arrangedSubviews[index]
		removeArrangedSubview(oldView)
		oldView.removeFromSuperview()
	}

	func reset() {
		for (index, button) in arrangedSubviews.enumerated() {
			if let button = button as? GamepadButton {
				removeArrangedSubview(button)
				button.removeFromSuperview()
				insertArrangedSubview(
					createUnassignedButton(forIndex: index),
					at: index
				)
			} else if !isEditing,
					  index > 0,
					  let button = button as? UnassignedGamepadButton {
				button.isHidden = true
				button.alpha = 0
			}
		}
	}

	private func createUnassignedButton(forIndex index: Int) -> UnassignedGamepadButton {
		let button = UnassignedGamepadButton(
			buttonSize: .small,
			isEditing: isEditing,
			isObscured: false
		) { [weak self] in
			self?.didRequestAssignmentAtIndex(index)
		}

		if !isEditing,
		   index > 0 {
			button.isHidden = true
			button.alpha = 0
		}

		return button
	}
}
