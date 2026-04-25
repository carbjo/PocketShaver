//
//  GamepadLayerView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class GamepadLayerView: UIView, ImageDerivable {

	enum Mode {
		case `default`
		case thumbnail
	}

	private let leftCollectionStackView: GamepadButtonStackViewCollectionStackView
	private let rightCollectionStackView: GamepadButtonStackViewCollectionStackView
	private var sideButtonStackViews: [GamepadSideButtonLayout: GamepadSideButtonStackView] = [:]

	private lazy var settingsButton: GamepadSettingsButton = {
		GamepadSettingsButton()
	}()

	private let inputInteractionModel: InputInteractionModel
	private let didRequestAssignmentForSideButton: ((GamepadSideButtonPosition) -> Void)
	private let didRequestLayoutSettings: (() -> Void)

	init(
		mode: Mode = .default,
		inputInteractionModel: InputInteractionModel,
		didRequestAssignmentForButton: @escaping ((GamepadButtonPosition) -> Void),
		didRequestAssignmentForSideButton: @escaping ((GamepadSideButtonPosition) -> Void),
		didRequestLayoutSettings: @escaping (() -> Void)
	) {
		self.inputInteractionModel = inputInteractionModel
		self.didRequestAssignmentForSideButton = didRequestAssignmentForSideButton
		self.didRequestLayoutSettings = didRequestLayoutSettings

		self.leftCollectionStackView = GamepadButtonStackViewCollectionStackView(
			side: .left,
			mode: mode,
			inputInteractionModel: inputInteractionModel
		) { row, index in
			didRequestAssignmentForButton(.init(side: .left, row: row, index: index))
		}
		self.rightCollectionStackView = GamepadButtonStackViewCollectionStackView(
			side: .right,
			mode: mode,
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

		let safeAreaInsets: UIEdgeInsets
		switch mode {
		case .default:
			safeAreaInsets = UIApplication.safeAreaInsets
		case .thumbnail:
			if GamepadSideButtonLayout.isSupported {
				safeAreaInsets = .init(top: 0, left: 62, bottom: 0, right: 62)
			} else {
				safeAreaInsets = .zero
			}
		}

		NSLayoutConstraint.activate([
			leftCollectionStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargin + safeAreaInsets.left),
			leftCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			rightCollectionStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargin - safeAreaInsets.right),
			rightCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			settingsButton.centerXAnchor.constraint(equalTo: centerXAnchor),
			settingsButton.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -UIScreen.main.bounds.size.height * GamepadSettingsButton.verticalScreenPositionRatio),
			settingsButton.widthAnchor.constraint(equalToConstant: settingsButtonLength),
			settingsButton.heightAnchor.constraint(equalToConstant: settingsButtonLength)
		])

		let showSideButtons: Bool
		switch mode {
		case .default:
			showSideButtons = GamepadSideButtonLayout.isAvailable
		case .thumbnail:
			showSideButtons = GamepadSideButtonLayout.isSupported
		}

		if showSideButtons {
			addStackView(
				for: .topLeft,
				horizontalAnchor: leadingAnchor,
				verticalAnchor: topAnchor
			)
			addStackView(
				for: .topRight,
				horizontalAnchor: trailingAnchor,
				verticalAnchor: topAnchor
			)
			addStackView(
				for: .bottomLeft,
				horizontalAnchor: leadingAnchor,
				verticalAnchor: bottomAnchor
			)
			addStackView(
				for: .bottomRight,
				horizontalAnchor: trailingAnchor,
				verticalAnchor: bottomAnchor
			)
		}

		settingsButton.addTarget(self, action: #selector(didTapSettingsButton), for: .touchUpInside)
	}

	convenience init(
		mode: Mode = .default
	) {
		self.init(
			mode: mode,
			inputInteractionModel: .init(),
			didRequestAssignmentForButton: {_ in },
			didRequestAssignmentForSideButton: {_ in },
			didRequestLayoutSettings: {}
		)

		isUserInteractionEnabled = false
	}

	required init?(coder: NSCoder) { fatalError() }

	static func asImage(config: GamepadConfig, size: CGSize) -> UIImage {
		let gamepadLayerView = GamepadLayerView(mode: .thumbnail)
		gamepadLayerView.load(config: config)
		NSLayoutConstraint.activate([
			gamepadLayerView.widthAnchor.constraint(equalToConstant: size.width),
			gamepadLayerView.heightAnchor.constraint(equalToConstant: size.height),
		])
		gamepadLayerView.layoutIfNeeded()

		return gamepadLayerView.asImage()
	}

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
		verticalAnchor: NSLayoutYAxisAnchor
	) {
		let stackView = GamepadSideButtonStackView(
			sideButtonLayout: sideButtonLayout,
			horizontalAnchor: horizontalAnchor,
			verticalAnchor: verticalAnchor,
			inputInteractionModel: inputInteractionModel
		) { [weak self] index in
			self?.didRequestAssignmentForSideButton(.init(layout: sideButtonLayout, index: index))
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
