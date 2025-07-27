//
//  GamepadLayerView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class GamepadLayerView: UIView {

	private lazy var leftStack: ButtonStackView = {
		ButtonStackView(pushKey: pushKey, releaseKey: releaseKey)
	}()

	private lazy var rightStack: ButtonStackView = {
		ButtonStackView(pushKey: pushKey, releaseKey: releaseKey)
	}()

	private lazy var leftUpperStack: ButtonStackView = {
		ButtonStackView(pushKey: pushKey, releaseKey: releaseKey)
	}()

	private lazy var rightUpperStack: ButtonStackView = {
		ButtonStackView(pushKey: pushKey, releaseKey: releaseKey)
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

		addSubview(leftStack)
		addSubview(rightStack)

		addSubview(leftUpperStack)
		addSubview(rightUpperStack)

		let sideMargin: CGFloat = UIDevice.hasNotch ? 64 : 8

		NSLayoutConstraint.activate([
			leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargin),
			leftStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			leftUpperStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargin),
			leftUpperStack.bottomAnchor.constraint(equalTo: leftStack.topAnchor, constant: -8),

			rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargin),
			rightStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			rightUpperStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargin),
			rightUpperStack.bottomAnchor.constraint(equalTo: rightStack.topAnchor, constant: -8)
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
		leftStack.add(.space)
		leftStack.add(.x)
		leftStack.add(.shift)
		leftUpperStack.add(.a)
		leftUpperStack.add(.s)

		rightStack.add(.left)
		rightStack.add(.right)
		rightUpperStack.add(.down)
		rightUpperStack.add(.up)
	}

	func buttonLayout2(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftStack.add(.down)
		leftStack.add(.up)
		leftStack.add(.space)

		rightStack.add(.alt)
		rightStack.add(.tab)
		rightStack.add(.left)
		rightStack.add(.right)

		leftUpperStack.add(.q)
		rightUpperStack.add(.cmd)
	}

	func buttonLayout3(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftStack.add(.up)
		leftStack.add(.ctrl)
		leftStack.add(.down)
		leftUpperStack.add(.space)

		rightUpperStack.add(.a)
		rightStack.add(.escape)
		rightStack.add(.left)
		rightStack.add(.right)
	}

	func buttonLayout4(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftStack.add(.up)
		leftStack.addArrangedSubview(UnassignedButton())
		leftStack.add(.ctrl)

		rightStack.add(.left)
		rightStack.add(.right)
	}
}
