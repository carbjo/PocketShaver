//
//  GamepadLayerView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class GamepadLayerView: UIView {
	
	private let leftCollectionStackView: GamepadButtonStackViewCollectionStackView
	private let rightCollectionStackView: GamepadButtonStackViewCollectionStackView

	private lazy var settingsButton: GamepadSettingsButton = {
		GamepadSettingsButton()
	}()

	private let didRequestLayoutSettings: (() -> Void)

	init(
		isRelativeMouseModeOn: Bool,
		keyInteraction: @escaping ((Int, Bool, Bool) -> Void),
		specialButtonInteraction: @escaping ((SpecialButton, Bool) -> Void),
		didFireJoystick: @escaping ((CGPoint) -> Void),
		didRequestAssignmentAt: @escaping ((GamepadButtonPosition) -> Void),
		didRequestLayoutSettings: @escaping (() -> Void)
	) {
		self.didRequestLayoutSettings = didRequestLayoutSettings

		self.leftCollectionStackView = GamepadButtonStackViewCollectionStackView(
			side: .left,
			isRelativeMouseModeOn: isRelativeMouseModeOn,
			keyInteraction: keyInteraction,
			specialButtonInteraction: specialButtonInteraction,
			didFireJoystick: didFireJoystick
		) { row, index in
			didRequestAssignmentAt(.init(side: .left, row: row, index: index))
		}
		self.rightCollectionStackView = GamepadButtonStackViewCollectionStackView(
			side: .right,
			isRelativeMouseModeOn: isRelativeMouseModeOn,
			keyInteraction: keyInteraction,
			specialButtonInteraction: specialButtonInteraction,
			didFireJoystick: didFireJoystick
		) { row, index in
			didRequestAssignmentAt(.init(side: .right, row: row, index: index))
		}

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false

		addSubview(leftCollectionStackView)
		addSubview(rightCollectionStackView)
		addSubview(settingsButton)

		let sideMargin: CGFloat = UIScreen.sideMarginForButtons
		let settingsButtonLength = GamepadSettingsButton.length

		NSLayoutConstraint.activate([
			leftCollectionStackView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: sideMargin),
			leftCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			rightCollectionStackView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -sideMargin),
			rightCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			settingsButton.centerXAnchor.constraint(equalTo: centerXAnchor),
			settingsButton.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -UIScreen.main.bounds.size.height * GamepadSettingsButton.verticalScreenPositionRatio),
			settingsButton.widthAnchor.constraint(equalToConstant: settingsButtonLength),
			settingsButton.heightAnchor.constraint(equalToConstant: settingsButtonLength)
		])

		settingsButton.addTarget(self, action: #selector(didTapSettingsButton), for: .touchUpInside)
	}

	convenience init() {
		self.init(
			isRelativeMouseModeOn: false,
			keyInteraction: {_, _, _ in },
			specialButtonInteraction: {_, _ in },
			didFireJoystick: {_ in },
			didRequestAssignmentAt: {_ in },
			didRequestLayoutSettings: {}
		)
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

		for mapping in config.mappings {
			switch mapping.position.side {
			case .left:
				leftCollectionStackView.set(mapping.assignment, row: mapping.position.row, index: mapping.position.index)
			case .right:
				rightCollectionStackView.set(mapping.assignment, row: mapping.position.row, index: mapping.position.index)
			}
		}
	}

	func set(isRelativeMouseModeOn: Bool) {
		leftCollectionStackView.set(isRelativeMouseModeOn: isRelativeMouseModeOn)
		rightCollectionStackView.set(isRelativeMouseModeOn: isRelativeMouseModeOn)
	}

	func set(isEditing: Bool) {
		leftCollectionStackView.set(isEditing: isEditing)
		rightCollectionStackView.set(isEditing: isEditing)
		settingsButton.isHidden = !isEditing
	}

	@objc private func didTapSettingsButton() {
		didRequestLayoutSettings()
	}
}
