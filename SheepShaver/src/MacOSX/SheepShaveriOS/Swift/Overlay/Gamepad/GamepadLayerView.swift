//
//  GamepadLayerView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class GamepadLayerView: UIView {
	
	private lazy var leftCollectionStackView: ButtonStackViewCollectionStackView = {
		ButtonStackViewCollectionStackView(
			side: .left,
			pushKey: pushKey,
			releaseKey: releaseKey
		) { [weak self] row, index in
			guard let self else { return }
			didRequestAssignmentAt(.init(side: .left, row: row, index: index))
		}
	}()

	private lazy var rightCollectionStackView: ButtonStackViewCollectionStackView = {
		ButtonStackViewCollectionStackView(
			side: .right,
			pushKey: pushKey,
			releaseKey: releaseKey
		) { [weak self] row, index in
			guard let self else { return }
			didRequestAssignmentAt(.init(side: .right, row: row, index: index))
		}
	}()

	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)
	private let didRequestAssignmentAt: ((GamepadButtonPosition) -> Void)

	init(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void),
		didRequestAssignmentAt: @escaping ((GamepadButtonPosition) -> Void)
	) {
		self.pushKey = pushKey
		self.releaseKey = releaseKey
		self.didRequestAssignmentAt = didRequestAssignmentAt

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false

		addSubview(leftCollectionStackView)
		addSubview(rightCollectionStackView)

		let sideMargin: CGFloat = UIDevice.hasNotch ? 64 : 8

		NSLayoutConstraint.activate([
			leftCollectionStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargin),
			leftCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			rightCollectionStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargin),
			rightCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		for view in subviews {
			let pointInSubviewCoordinateSpace = view.convert(point, from: self)
			if view.point(inside: pointInSubviewCoordinateSpace, with: event) {
				return true
			}
		}

		return false
	}

	func load(config: GamepadConfig) {
		leftCollectionStackView.reset()
		rightCollectionStackView.reset()

		for assignment in config.assignments {
			switch assignment.position.side {
			case .left:
				leftCollectionStackView.set(assignment.key, row: assignment.position.row, index: assignment.position.index)
			case .right:
				rightCollectionStackView.set(assignment.key, row: assignment.position.row, index: assignment.position.index)
			}
		}
	}

	func set(isEditing: Bool) {
		leftCollectionStackView.set(isEditing: isEditing)
		rightCollectionStackView.set(isEditing: isEditing)
	}
}
