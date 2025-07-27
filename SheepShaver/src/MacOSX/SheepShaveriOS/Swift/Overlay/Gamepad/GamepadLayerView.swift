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
			isRightHandSide: false,
			pushKey: pushKey,
			releaseKey: releaseKey
		)
	}()

	private lazy var rightCollectionStackView: ButtonStackViewCollectionStackView = {
		ButtonStackViewCollectionStackView(
			isRightHandSide: true,
			pushKey: pushKey,
			releaseKey: releaseKey
		)
	}()

	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)

	init(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		self.pushKey = pushKey
		self.releaseKey = releaseKey

		super.init(frame: .zero)

		buttonLayout2(pushKey: pushKey, releaseKey: releaseKey)

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
}

extension GamepadLayerView {
	// To be removed. WIP
	func buttonLayout1(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftCollectionStackView.set(.space, row: 0, index: 0)
		leftCollectionStackView.set(.x, row: 0, index: 1)
		leftCollectionStackView.set(.shift, row: 0, index: 2)
		leftCollectionStackView.set(.a, row: 1, index: 0)
		leftCollectionStackView.set(.s, row: 1, index: 1)

		rightCollectionStackView.set(.left, row: 0, index: 0)
		rightCollectionStackView.set(.right, row: 0, index: 1)
		rightCollectionStackView.set(.down, row: 1, index: 0)
		rightCollectionStackView.set(.up, row: 1, index: 1)
	}

	func buttonLayout2(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftCollectionStackView.set(.down, row: 0, index: 0)
		leftCollectionStackView.set(.up, row: 0, index: 1)
		leftCollectionStackView.set(.space, row: 0, index: 2)

		rightCollectionStackView.set(.alt, row: 0, index: 3)
		rightCollectionStackView.set(.tab, row: 0, index: 2)
		rightCollectionStackView.set(.left, row: 0, index: 1)
		rightCollectionStackView.set(.right, row: 0, index: 0)

		leftCollectionStackView.set(.q, row: 1, index: 0)
		rightCollectionStackView.set(.cmd, row: 1, index: 0)
	}

	func buttonLayout3(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftCollectionStackView.set(.up, row: 0, index: 0)
		leftCollectionStackView.set(.ctrl, row: 0, index: 1)
		leftCollectionStackView.set(.down, row: 0, index: 2)
		leftCollectionStackView.set(.space, row: 1, index: 0)

		rightCollectionStackView.set(.escape, row: 0, index: 0)
		rightCollectionStackView.set(.left, row: 0, index: 1)
		rightCollectionStackView.set(.right, row: 0, index: 2)
		rightCollectionStackView.set(.a, row: 1, index: 0)
	}

	func buttonLayout4(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftCollectionStackView.set(.up, row: 0, index: 0)
		leftCollectionStackView.set(.ctrl, row: 0, index: 1)

		rightCollectionStackView.set(.left, row: 0, index: 0)
		rightCollectionStackView.set(.right, row: 0, index: 1)
	}
}
