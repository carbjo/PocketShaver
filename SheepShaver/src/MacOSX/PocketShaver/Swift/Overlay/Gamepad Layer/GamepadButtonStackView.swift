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
	private let inputInteractionModel: InputInteractionModel
	private let didRequestAssignmentAtIndex: ((Int) -> Void)

	private var isEditing: Bool = false

	init(
		side: GamepadSide,
		row: Int,
		isSettingsButtonRow: Bool,
		inputInteractionModel: InputInteractionModel,
		didRequestAssignmentAtIndex: @escaping ((Int) -> Void)
	) {
		self.side = side
		self.row = row
		self.inputInteractionModel = inputInteractionModel
		self.didRequestAssignmentAtIndex = didRequestAssignmentAtIndex

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		axis = .horizontal
		spacing = 4

		setupButtons(isSettingsButtonRow: isSettingsButtonRow)
	}
	
	required init(coder: NSCoder) { fatalError() }

	private func setupButtons(
		isSettingsButtonRow: Bool
	) {
		let screenWidth = UIScreen.main.bounds.width - UIApplication.safeAreaInsets.left - UIApplication.safeAreaInsets.right
		let sideMargin: CGFloat = UIScreen.sideMarginForButtons

		let settingsButtonLength = GamepadSettingsButton.length
		let halfSettingsButton: CGFloat = settingsButtonLength/2
		let settingsButtonMargin = isSettingsButtonRow ? halfSettingsButton : 0
		let availableWidth = (screenWidth / 2) - sideMargin - settingsButtonMargin
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

		removeViewAt(index)

		let button = GamepadButton(
			label: .text(key.label),
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
			at: sideCorrectedIndex
		)
	}

	func set(_ specialButton: SpecialButton, at index: Int) {
		guard let sideCorrectedIndex = getSideCorrectedIndex(for: index) else {
			return
		}

		removeViewAt(index)

		let button = GamepadButton(
			label: specialButton.gamepadLabel,
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
			at: sideCorrectedIndex
		)
	}

	func set(_ joystickType: JoystickType ,at index: Int) {
		guard let sideCorrectedIndex = getSideCorrectedIndex(for: index) else {
			return
		}

		removeViewAt(index)

		let mode: GamepadJoystick.Mode
		switch joystickType {
		case .mouse:
			mode = .mouse({ [weak self] delta in
				self?.inputInteractionModel.handleFireMouseJoystick(with: delta)
			})
		case .wasd4way:
			mode = .wasd(
				.fourWay,
				{ [weak self] sdlKey, isDown in
					self?.inputInteractionModel.handle(
						sdlKey,
						isDown: isDown,
						hapticAllowed: false
					)
				}
			)
		case .wasd8way:
			mode = .wasd(
				.eightWay,
				{ [weak self] sdlKey, isDown in
					self?.inputInteractionModel.handle(
						sdlKey,
						isDown: isDown,
						hapticAllowed: false
					)
				}
			)
		}

		let joystick = GamepadJoystick(
			inputInteractionModel: inputInteractionModel,
			isEditing: isEditing,
			mode: mode,
			didRequestAssignment: { [weak self] in
				self?.didRequestAssignmentAtIndex(index)
			}
		)

		insertArrangedSubview(
			joystick,
			at: sideCorrectedIndex
		)
	}

	func setKeyObscured(_ isObscured: Bool, at index: Int) {
		guard let sideCorrectedIndex = getSideCorrectedIndex(for: index),
			  let unassignedButton = arrangedSubviews[sideCorrectedIndex] as? UnassignedGamepadButton else {
			return
		}

		unassignedButton.set(isObscured: isObscured)
	}

	func setKeyToRightObscured(_ isObscured: Bool, rightOfIndex index: Int) {
		guard let sideCorrectedIndex = getSideCorrectedIndex(for: index),
			  sideCorrectedIndex + 1 < arrangedSubviews.count,
			  let unassignedButton = arrangedSubviews[sideCorrectedIndex + 1] as? UnassignedGamepadButton else {
			return
		}

		unassignedButton.set(isObscured: isObscured)
	}

	func set(isEditing: Bool) {
		self.isEditing = isEditing

		for view in arrangedSubviews {
			if let button = view as? GamepadButton {
				button.set(isEditing: isEditing)
			} else if let joystick = view as? GamepadJoystick {
				joystick.set(isEditing: isEditing)
			} else if let button = view as? UnassignedGamepadButton {
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
			} else if let joystick = button as? GamepadJoystick {
				let sideCorrectedIndex = side == .right ? (numberOfButtons - 1 - index) : index
				removeArrangedSubview(joystick)
				button.removeFromSuperview()
				insertArrangedSubview(
					createUnassignedButton(forIndex: sideCorrectedIndex),
					at: index
				)
			} else if let button = button as? UnassignedGamepadButton {
				button.set(isObscured: false)
			}
		}
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		// Only consider touches to the buttons or spacing cells as
		// touches that belongs to this stack view.
		// Ie. not when touching the spaces between the buttons or spacing cells.

		for view in arrangedSubviews {
			guard view is GamepadButton || view is GamepadJoystick || isEditing else {
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
			isEditing: isEditing,
			isObscured: false
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

	private func removeViewAt(_ index: Int) {
		guard let sideCorrectedIndex = getSideCorrectedIndex(for: index) else {
			return
		}

		let oldView = arrangedSubviews[sideCorrectedIndex]
		removeArrangedSubview(oldView)
		oldView.removeFromSuperview()
	}
}
