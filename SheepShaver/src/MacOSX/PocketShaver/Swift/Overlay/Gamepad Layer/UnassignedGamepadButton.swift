//
//  UnassignedGamepadButton.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class UnassignedGamepadButton: UIView {
	
	private lazy var label: UILabel = {
		let label = UILabel.withoutConstraints()
		label.text = "Tap to assign"
		label.textColor = .white
		label.textAlignment = .center
		label.numberOfLines = 0
		return label
	}()

	private var isObscured: Bool
	private let didRequestAssignment: (() -> Void)
	private var isEditing: Bool = false

	init(
		buttonSize: GamepadButtonSize,
		isEditing: Bool,
		isObscured: Bool,
		didRequestAssignment: @escaping (() -> Void)
	) {
		self.isObscured = isObscured
		self.didRequestAssignment = didRequestAssignment

		super.init(frame: .zero)
		
		translatesAutoresizingMaskIntoConstraints = false
		layer.cornerRadius = 8

		let length = buttonSize.length


		if buttonSize == .small {
			label.font = .systemFont(ofSize: 9)
		} else if UIScreen.isSmallSize {
			label.font = .systemFont(ofSize: 16)
		}

		let sideMargin: CGFloat = buttonSize == .regular ? 8 : 2

		addSubview(label)

		NSLayoutConstraint.activate([
			widthAnchor.constraint(equalToConstant: length),
			heightAnchor.constraint(equalToConstant: length),

			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargin),
			label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargin),
			label.centerYAnchor.constraint(equalTo: centerYAnchor)
		])

		set(isEditing: isEditing)
	}
	
	required init?(coder: NSCoder) { fatalError() }

	func set(isObscured: Bool) {
		self.isObscured = isObscured

		alpha = isObscured ? 0.02 : 1
	}

	func set(isEditing: Bool) {
		backgroundColor = isEditing ? .orange.withAlphaComponent(0.85) : .clear
		transform = isEditing ? .identity : .init(scaleX: 0.5, y: 0.5)
		label.textColor = isEditing ? .white : .white.withAlphaComponent(0)
		self.isEditing = isEditing
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesBegan(touches, with: event)

		if isEditing {
			backgroundColor = .orange.withAlphaComponent(0.5)
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesEnded(touches, with: event)

		if isEditing {
			backgroundColor = .orange.withAlphaComponent(0.8)

			var isInside = false
			for touch in touches {
				if bounds.contains(touch.location(in: self)) {
					isInside = true
				}
			}

			if isInside {
				didRequestAssignment()
			}
		}
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		guard !isObscured else {
			return false
		}

		return super.point(inside: point, with: event)
	}
}
