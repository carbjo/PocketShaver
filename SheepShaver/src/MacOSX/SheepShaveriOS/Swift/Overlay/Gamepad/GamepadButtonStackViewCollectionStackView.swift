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
		keyInteraction: @escaping ((Int, Bool) -> Void),
		specialButtonInteraction: @escaping ((SpecialButton, Bool) -> Void),
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
			keyInteraction: keyInteraction,
			specialButtonInteraction: specialButtonInteraction
		)
	}
	
	required init(coder: NSCoder) { fatalError() }

	private func setupStackViews(
		side: GamepadSide,
		keyInteraction: @escaping ((Int, Bool) -> Void),
		specialButtonInteraction: @escaping ((SpecialButton, Bool) -> Void)
	) {
		let screenHeight = UIScreen.main.bounds.height
		let length: CGFloat = UIDevice.hasNotch ? 80 : 64
		let stackViewHeight: CGFloat = length + (spacing * 2)

		let numberOfStackViews = Int(floor(screenHeight / stackViewHeight))

		for row in 0..<numberOfStackViews {
			let orientationCorrectedRow = numberOfStackViews - 1 - row // Build from bottom to top

			addArrangedSubview(
				GamepadButtonStackView(
					side: side,
					row: row,
					keyInteraction: keyInteraction,
					specialButtonInteraction: specialButtonInteraction
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
