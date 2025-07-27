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
			alignment: .leading,
			pushKey: pushKey,
			releaseKey: releaseKey
		)
	}()

	private lazy var rightCollectionStackView: ButtonStackViewCollectionStackView = {
		ButtonStackViewCollectionStackView(
			alignment: .trailing,
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

//		addSubview(leftUpperStack)
//		addSubview(rightUpperStack)

		let sideMargin: CGFloat = UIDevice.hasNotch ? 64 : 8

		NSLayoutConstraint.activate([
			leftCollectionStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargin),
			leftCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

//			leftUpperStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargin),
//			leftUpperStack.bottomAnchor.constraint(equalTo: leftStack.topAnchor, constant: -8),

			rightCollectionStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargin),
			rightCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

//			rightUpperStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargin),
//			rightUpperStack.bottomAnchor.constraint(equalTo: rightStack.topAnchor, constant: -8)
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
		leftCollectionStackView.add(.space, row: 0)
		leftCollectionStackView.add(.x, row: 0)
		leftCollectionStackView.add(.shift, row: 0)
		leftCollectionStackView.add(.a, row: 1)
		leftCollectionStackView.add(.s, row: 1)

		rightCollectionStackView.add(.left, row: 0)
		rightCollectionStackView.add(.right, row: 0)
		rightCollectionStackView.add(.down, row: 1)
		rightCollectionStackView.add(.up, row: 1)
	}

	func buttonLayout2(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftCollectionStackView.add(.down, row: 0)
		leftCollectionStackView.add(.up, row: 0)
		leftCollectionStackView.add(.space, row: 0)

		rightCollectionStackView.add(.alt, row: 0)
		rightCollectionStackView.add(.tab, row: 0)
		rightCollectionStackView.add(.left, row: 0)
		rightCollectionStackView.add(.right, row: 0)

		leftCollectionStackView.add(.q, row: 1)
		rightCollectionStackView.add(.cmd, row: 1)
	}

	func buttonLayout3(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftCollectionStackView.add(.up, row: 0)
		leftCollectionStackView.add(.ctrl, row: 0)
		leftCollectionStackView.add(.down, row: 0)
		leftCollectionStackView.add(.space, row: 1)

		rightCollectionStackView.add(.escape, row: 0)
		rightCollectionStackView.add(.left, row: 0)
		rightCollectionStackView.add(.right, row: 0)
		rightCollectionStackView.add(.a, row: 1)
	}

	func buttonLayout4(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftCollectionStackView.add(.up, row: 0)
		leftCollectionStackView.add(.ctrl, row: 0)

		rightCollectionStackView.add(.left, row: 0)
		rightCollectionStackView.add(.right, row: 0)
	}
}
