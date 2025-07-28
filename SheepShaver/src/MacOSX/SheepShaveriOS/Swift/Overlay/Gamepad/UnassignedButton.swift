//
//  UnassignedButton.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class UnassignedButton: UIView {
	
	private lazy var label: UILabel = {
		let label = UILabel.withoutConstraints()
		label.text = "Tap to assign"
		label.textColor = .white
		label.textAlignment = .center
		label.numberOfLines = 0
		return label
	}()

	private let index: Int
	private let didRequestAssignmentAtIndex: ((Int) -> Void)
	private var isEditing: Bool = false

	init(
		index: Int,
		isEditing: Bool,
		didRequestAssignmentAtIndex: @escaping ((Int) -> Void)
	) {
		self.index = index
		self.didRequestAssignmentAtIndex = didRequestAssignmentAtIndex

		super.init(frame: .zero)
		
		translatesAutoresizingMaskIntoConstraints = false
		layer.cornerRadius = 8

		let length: CGFloat = UIDevice.hasNotch ? 80 : 64

		addSubview(label)

		NSLayoutConstraint.activate([
			widthAnchor.constraint(equalToConstant: length),
			heightAnchor.constraint(equalToConstant: length),

			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
			label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
			label.centerYAnchor.constraint(equalTo: centerYAnchor)
		])

		set(isEditing: isEditing)
	}
	
	required init?(coder: NSCoder) { fatalError() }

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
				didRequestAssignmentAtIndex(index)
			}
		}
	}
}
