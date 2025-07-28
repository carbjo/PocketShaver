//
//  ButtonStackViewCollectionStackView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class ButtonStackViewCollectionStackView: UIStackView {

	private let didRequestAssignmentAtRowAndIndex: ((Int, Int) -> Void)

	init(
		side: GamepadSide,
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void),
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
			pushKey: pushKey,
			releaseKey: releaseKey
		)
	}
	
	required init(coder: NSCoder) { fatalError() }

	private func setupStackViews(
		side: GamepadSide,
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		let screenHeight = UIScreen.main.bounds.height
		let length: CGFloat = UIDevice.hasNotch ? 80 : 64
		let stackViewHeight: CGFloat = length + (spacing * 2)

		let numberOfStackViews = Int(floor(screenHeight / stackViewHeight))

		for row in 0..<numberOfStackViews {
			let orientationCorrectedRow = numberOfStackViews - 1 - row // Build from bottom to top

			addArrangedSubview(
				ButtonStackView(
					side: side,
					row: row,
					pushKey: pushKey,
					releaseKey: releaseKey
				) { [weak self] index in
					guard let self else { return }
					didRequestAssignmentAtRowAndIndex(orientationCorrectedRow, index)
				}
			)
		}
	}

	func set(_ key: SDLKey, row: Int, index: Int) {
		let orientationCorrectedRow = arrangedSubviews.count - 1 - row // Build from bottom to top
		guard orientationCorrectedRow >= 0,
			  let stackView = arrangedSubviews[orientationCorrectedRow] as? ButtonStackView else {
			print("-- unexpected")
			return
		}

		stackView.set(key, at: index)
	}

	func set(isEditing: Bool) {
		for stackView in arrangedSubviews {
			guard let stackView = stackView as? ButtonStackView else {
				print("-- unexpected")
				continue
			}
			stackView.set(isEditing: isEditing)
		}
	}

	func reset() {
		for stackView in arrangedSubviews {
			guard let stackView = stackView as? ButtonStackView else {
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
}
