//
//  GamepadButtonStackViewCollectionStackView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class GamepadButtonStackViewCollectionStackView: UIStackView {

	private let didRequestAssignmentAtRowAndIndex: ((Int, Int) -> Void)

	init(
		side: GamepadSide,
		inputInteractionModel: InputInteractionModel,
		didRequestAssignmentAtRowAndIndex: @escaping ((Int, Int) -> Void)
	) {
		self.didRequestAssignmentAtRowAndIndex = didRequestAssignmentAtRowAndIndex

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		axis = .vertical
		alignment = side == .right ? .trailing : .leading
		spacing = 8

		setupStackViews(
			side: side,
			inputInteractionModel: inputInteractionModel
		)
	}
	
	required init(coder: NSCoder) { fatalError() }

	private func setupStackViews(
		side: GamepadSide,
		inputInteractionModel: InputInteractionModel
	) {
		let screenHeight = UIScreen.main.bounds.height - UIApplication.safeAreaInsets.top - UIApplication.safeAreaInsets.bottom
		let length = GamepadButton.length
		let stackViewHeight: CGFloat = length + spacing
		let availableHeight = screenHeight

		let numberOfStackViews = Int(floor(availableHeight / stackViewHeight))

		let halfGamepadSettingsLength = GamepadSettingsButton.length / 2
		let settingsButtonStartRow = Int(floor((GamepadSettingsButton.verticalScreenPositionRatio * availableHeight - halfGamepadSettingsLength) / stackViewHeight))
		let settingsButtonEndRow = Int(floor((GamepadSettingsButton.verticalScreenPositionRatio * availableHeight + halfGamepadSettingsLength) / stackViewHeight))
		let settingsButtonRange = settingsButtonStartRow...settingsButtonEndRow

		for row in 0..<numberOfStackViews {
			let orientationCorrectedRow = numberOfStackViews - 1 - row // Build from bottom to top

			addArrangedSubview(
				GamepadButtonStackView(
					side: side,
					row: row,
					isSettingsButtonRow: settingsButtonRange.contains(orientationCorrectedRow),
					inputInteractionModel: inputInteractionModel
				) { [weak self] index in
					guard let self else { return }
					didRequestAssignmentAtRowAndIndex(orientationCorrectedRow, index)
				}
			)
		}
	}

	func set(_ assignment: GamepadButtonAssignment, row: Int, index: Int) {
		guard let orientationCorrectedRow = getOrientationCorrectedRow(for: row),
			  let stackView = arrangedSubviews[orientationCorrectedRow] as? GamepadButtonStackView else {
			print("-- unexpected")
			return
		}

		switch assignment {
		case .key(let key):
			stackView.set(key, at: index)
		case .specialButton(let specialButton):
			stackView.set(specialButton, at: index)
		case .joystick(let joystickType):
			stackView.set(joystickType, at: index)

			stackView.setKeyToRightObscured(true, rightOfIndex: index)
			guard let orientationCorrectedRowPlusOne = getOrientationCorrectedRow(for: row - 1),
				  let stackViewPlusOne = arrangedSubviews[orientationCorrectedRowPlusOne] as? GamepadButtonStackView else {
				return
			}
			stackViewPlusOne.setKeyObscured(true, at: index)
			stackViewPlusOne.setKeyToRightObscured(true, rightOfIndex: index)
		}
	}

	func set(isEditing: Bool) {
		for stackView in arrangedSubviews {
			guard let stackView = stackView as? GamepadButtonStackView else {
				print("-- unexpected")
				continue
			}
			stackView.set(isEditing: isEditing)
		}
	}

	func reset() {
		for stackView in arrangedSubviews {
			guard let stackView = stackView as? GamepadButtonStackView else {
				print("-- unexpected")
				continue
			}

			stackView.reset()
		}
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		for view in arrangedSubviews {
			let pointInSubviewCoordinateSpace = view.convert(point, from: self)
			if view.point(inside: pointInSubviewCoordinateSpace, with: event) {
				return true
			}
		}

		return false
	}

	private func getOrientationCorrectedRow(for row: Int) -> Int? {
		let orientationCorrectedRow = arrangedSubviews.count - 1 - row // Build from bottom to top
		guard orientationCorrectedRow >= 0,
			  let stackView = arrangedSubviews[orientationCorrectedRow] as? GamepadButtonStackView else {
			print("-- unexpected")
			return nil
		}

		return orientationCorrectedRow
	}
}
