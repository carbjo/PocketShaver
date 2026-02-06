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
	private var sideButtonStackViews: [GamepadSideButtonLayout: GamepadSideButtonStackView] = [:]

	private lazy var settingsButton: GamepadSettingsButton = {
		GamepadSettingsButton()
	}()

	private let didRequestLayoutSettings: (() -> Void)

	init(
		inputInteractionModel: InputInteractionModel,
		didRequestAssignmentForButton: @escaping ((GamepadButtonPosition) -> Void),
		didRequestAssignmentForSideButton: @escaping ((GamepadSideButtonPosition) -> Void),
		didRequestLayoutSettings: @escaping (() -> Void)
	) {
		self.didRequestLayoutSettings = didRequestLayoutSettings

		self.leftCollectionStackView = GamepadButtonStackViewCollectionStackView(
			side: .left,
			inputInteractionModel: inputInteractionModel
		) { row, index in
			didRequestAssignmentForButton(.init(side: .left, row: row, index: index))
		}
		self.rightCollectionStackView = GamepadButtonStackViewCollectionStackView(
			side: .right,
			inputInteractionModel: inputInteractionModel
		) { row, index in
			didRequestAssignmentForButton(.init(side: .right, row: row, index: index))
		}

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false

		addSubview(leftCollectionStackView)
		addSubview(rightCollectionStackView)
		addSubview(settingsButton)

		let sideMargin: CGFloat = UIScreen.sideMarginForButtons
		let settingsButtonLength = GamepadSettingsButton.length

		NSLayoutConstraint.activate([
			leftCollectionStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargin + UIApplication.safeAreaInsets.left),
			leftCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			rightCollectionStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargin - UIApplication.safeAreaInsets.right),
			rightCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			settingsButton.centerXAnchor.constraint(equalTo: centerXAnchor),
			settingsButton.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -UIScreen.main.bounds.size.height * GamepadSettingsButton.verticalScreenPositionRatio),
			settingsButton.widthAnchor.constraint(equalToConstant: settingsButtonLength),
			settingsButton.heightAnchor.constraint(equalToConstant: settingsButtonLength)
		])

		if GamepadSideButtonLayout.isSupported {
			addStackView(
				for: .topLeft,
				horizontalAnchor: leadingAnchor,
				verticalAnchor: topAnchor,
				inputInteractionModel: inputInteractionModel,
				didRequestAssignmentForSideButton: didRequestAssignmentForSideButton
			)
			addStackView(
				for: .topRight,
				horizontalAnchor: trailingAnchor,
				verticalAnchor: topAnchor,
				inputInteractionModel: inputInteractionModel,
				didRequestAssignmentForSideButton: didRequestAssignmentForSideButton
			)
			addStackView(
				for: .bottomLeft,
				horizontalAnchor: leadingAnchor,
				verticalAnchor: bottomAnchor,
				inputInteractionModel: inputInteractionModel,
				didRequestAssignmentForSideButton: didRequestAssignmentForSideButton
			)
			addStackView(
				for: .bottomRight,
				horizontalAnchor: trailingAnchor,
				verticalAnchor: bottomAnchor,
				inputInteractionModel: inputInteractionModel,
				didRequestAssignmentForSideButton: didRequestAssignmentForSideButton
			)
		}

		settingsButton.addTarget(self, action: #selector(didTapSettingsButton), for: .touchUpInside)
	}

	convenience init() {
		self.init(
			inputInteractionModel: .init(),
			didRequestAssignmentForButton: {_ in },
			didRequestAssignmentForSideButton: {_ in },
			didRequestLayoutSettings: {}
		)

		isUserInteractionEnabled = false
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
		for sideButtonStackView in sideButtonStackViews.values {
			sideButtonStackView.reset()
		}

		for mapping in config.mappings {
			switch mapping.position.side {
			case .left:
				leftCollectionStackView.set(mapping.assignment, row: mapping.position.row, index: mapping.position.index)
			case .right:
				rightCollectionStackView.set(mapping.assignment, row: mapping.position.row, index: mapping.position.index)
			}
		}

		if let sideButtonMappings = config.sideButtonMappings {
			for sideButtonMapping in sideButtonMappings {
				guard let stackView = sideButtonStackViews[sideButtonMapping.position.layout] else {
					continue
				}

				switch sideButtonMapping.assignment {
				case .key(let sdlKey):
					stackView.set(sdlKey, at: sideButtonMapping.position.index)
				case .specialButton(let specialButton):
					stackView.set(specialButton, at: sideButtonMapping.position.index)
				case .joystick:
					fatalError()
				}
			}
		}
	}

	func set(isEditing: Bool) {
		leftCollectionStackView.set(isEditing: isEditing)
		rightCollectionStackView.set(isEditing: isEditing)
		for sideButtonStackView in sideButtonStackViews.values {
			sideButtonStackView.set(isEditing: isEditing)
		}
		settingsButton.isHidden = !isEditing
	}

	func updateSlotVisiblity(afterUpdating position: GamepadSideButtonPosition) {
		guard let stackView = sideButtonStackViews[position.layout] else {
			return
		}
		stackView.updateSlotVisiblity()
	}

	private func addStackView(
		for sideButtonLayout: GamepadSideButtonLayout,
		horizontalAnchor: NSLayoutXAxisAnchor,
		verticalAnchor: NSLayoutYAxisAnchor,
		inputInteractionModel: InputInteractionModel,
		didRequestAssignmentForSideButton: @escaping ((GamepadSideButtonPosition) -> Void)
	) {
		let stackView = GamepadSideButtonStackView(
			sideButtonLayout: sideButtonLayout,
			horizontalAnchor: horizontalAnchor,
			verticalAnchor: verticalAnchor,
			inputInteractionModel: inputInteractionModel
		) { index in
			didRequestAssignmentForSideButton(.init(layout: sideButtonLayout, index: index))
		}

		addSubview(stackView)

		NSLayoutConstraint.activate([
			stackView.centerXAnchor.constraint(equalTo: horizontalAnchor, constant: sideButtonLayout.centerXOffset),
			stackView.centerYAnchor.constraint(equalTo: verticalAnchor, constant: sideButtonLayout.centerYOffset)
		])

		sideButtonStackViews[sideButtonLayout] = stackView
	}

	@objc private func didTapSettingsButton() {
		didRequestLayoutSettings()
	}
}
