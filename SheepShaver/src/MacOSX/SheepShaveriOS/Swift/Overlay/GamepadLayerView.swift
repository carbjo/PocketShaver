//
//  GamepadLayerView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class GamepadLayerView: UIView {
	private lazy var leftStack: UIStackView = {
		let stack = UIStackView.withoutConstraints()
		stack.axis = .horizontal
		stack.spacing = 4
		return stack
	}()

	private lazy var rightStack: UIStackView = {
		let stack = UIStackView.withoutConstraints()
		stack.axis = .horizontal
		stack.spacing = 4
		return stack
	}()

	private lazy var leftUpperStack: UIStackView = {
		let stack = UIStackView.withoutConstraints()
		stack.axis = .horizontal
		stack.spacing = 4
		return stack
	}()

	private lazy var rightUpperStack: UIStackView = {
		let stack = UIStackView.withoutConstraints()
		stack.axis = .horizontal
		stack.spacing = 4
		return stack
	}()

	init(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
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
		var isInside = false
		for view in subviews {
			let pointInSubviewCoordinateSpace = view.convert(point, from: self)
			if view.point(inside: pointInSubviewCoordinateSpace, with: event) {
				isInside = true
			}
		}
		
		return isInside
	}
}

extension GamepadLayerView {
	// To be removed. WIP
	func buttonLayout1(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftStack.addArrangedSubview(Button(key: .space, pushKey: pushKey, releaseKey: releaseKey))
		leftStack.addArrangedSubview(Button(key: .x, pushKey: pushKey, releaseKey: releaseKey))
		leftStack.addArrangedSubview(Button(key: .shift, pushKey: pushKey, releaseKey: releaseKey))
		leftUpperStack.addArrangedSubview(Button(key: .a, pushKey: pushKey, releaseKey: releaseKey))
		leftUpperStack.addArrangedSubview(Button(key: .s, pushKey: pushKey, releaseKey: releaseKey))

		rightStack.addArrangedSubview(Button(key: .left, pushKey: pushKey, releaseKey: releaseKey))
		rightStack.addArrangedSubview(Button(key: .right, pushKey: pushKey, releaseKey: releaseKey))
		rightUpperStack.addArrangedSubview(Button(key: .down, pushKey: pushKey, releaseKey: releaseKey))
		rightUpperStack.addArrangedSubview(Button(key: .up, pushKey: pushKey, releaseKey: releaseKey))
	}

	func buttonLayout2(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftStack.addArrangedSubview(Button(key: .down, pushKey: pushKey, releaseKey: releaseKey))
		leftStack.addArrangedSubview(Button(key: .up, pushKey: pushKey, releaseKey: releaseKey))
		leftStack.addArrangedSubview(Button(key: .space, pushKey: pushKey, releaseKey: releaseKey))

		rightStack.addArrangedSubview(Button(key: .alt, pushKey: pushKey, releaseKey: releaseKey))
		rightStack.addArrangedSubview(Button(key: .tab, pushKey: pushKey, releaseKey: releaseKey))
		rightStack.addArrangedSubview(Button(key: .left, pushKey: pushKey, releaseKey: releaseKey))
		rightStack.addArrangedSubview(Button(key: .right, pushKey: pushKey, releaseKey: releaseKey))

		leftUpperStack.addArrangedSubview(Button(key: .q, pushKey: pushKey, releaseKey: releaseKey))
		rightUpperStack.addArrangedSubview(Button(key: .cmd, pushKey: pushKey, releaseKey: releaseKey))
	}

	func buttonLayout3(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		leftStack.addArrangedSubview(Button(key: .up, pushKey: pushKey, releaseKey: releaseKey))
		leftStack.addArrangedSubview(Button(key: .ctrl, pushKey: pushKey, releaseKey: releaseKey))
		leftStack.addArrangedSubview(Button(key: .down, pushKey: pushKey, releaseKey: releaseKey))
		leftUpperStack.addArrangedSubview(Button(key: .space, pushKey: pushKey, releaseKey: releaseKey))

		rightUpperStack.addArrangedSubview(Button(key: .a, pushKey: pushKey, releaseKey: releaseKey))
		rightStack.addArrangedSubview(Button(key: .escape, pushKey: pushKey, releaseKey: releaseKey))
		rightStack.addArrangedSubview(Button(key: .left, pushKey: pushKey, releaseKey: releaseKey))
		rightStack.addArrangedSubview(Button(key: .right, pushKey: pushKey, releaseKey: releaseKey))
	}
}
