//
//  GamepadLayerView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class GamepadLayerView: UIView {
	
	private lazy var leftCollectionStackView: GamepadButtonStackViewCollectionStackView = {
		GamepadButtonStackViewCollectionStackView(
			side: .left,
			keyInteraction: keyInteraction,
			specialButtonInteraction: specialButtonInteraction
		) { [weak self] row, index in
			guard let self else { return }
			didRequestAssignmentAt(.init(side: .left, row: row, index: index))
		}
	}()

	private lazy var rightCollectionStackView: GamepadButtonStackViewCollectionStackView = {
		GamepadButtonStackViewCollectionStackView(
			side: .right,
			keyInteraction: keyInteraction,
			specialButtonInteraction: specialButtonInteraction
		) { [weak self] row, index in
			guard let self else { return }
			didRequestAssignmentAt(.init(side: .right, row: row, index: index))
		}
	}()

	private lazy var settingsButton: UIButton = {
		let button = UIButton.withoutConstraints()
		var configuration = UIButton.Configuration.defaultConfig
		configuration.contentInsets = .zero
		configuration.baseBackgroundColor = .lightGray.withAlphaComponent(0.9)
		button.configuration = configuration
		button.setImage(UIImage(resource: .gearshape), for: .normal)
		button.isHidden = true
		return button
	}()

	private let keyInteraction: ((Int, Bool) -> Void)
	private let specialButtonInteraction: ((SpecialButton, Bool) -> Void)
	private let didRequestAssignmentAt: ((GamepadButtonPosition) -> Void)
	private let didRequestLayoutSettings: (() -> Void)

	init(
		keyInteraction: @escaping ((Int, Bool) -> Void),
		specialButtonInteraction: @escaping ((SpecialButton, Bool) -> Void),
		didRequestAssignmentAt: @escaping ((GamepadButtonPosition) -> Void),
		didRequestLayoutSettings: @escaping (() -> Void)
	) {
		self.keyInteraction = keyInteraction
		self.specialButtonInteraction = specialButtonInteraction
		self.didRequestAssignmentAt = didRequestAssignmentAt
		self.didRequestLayoutSettings = didRequestLayoutSettings

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false

		addSubview(leftCollectionStackView)
		addSubview(rightCollectionStackView)
		addSubview(settingsButton)

		let sideMargin: CGFloat = UIDevice.sideMarginForButtons
		let settingsButtonLength: CGFloat = UIDevice.isSmallScreenSize ? 36 : 44

		NSLayoutConstraint.activate([
			leftCollectionStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sideMargin),
			leftCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			rightCollectionStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sideMargin),
			rightCollectionStackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

			settingsButton.centerXAnchor.constraint(equalTo: centerXAnchor),
			settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -UIScreen.main.bounds.size.height / 4),
			settingsButton.widthAnchor.constraint(equalToConstant: settingsButtonLength),
			settingsButton.heightAnchor.constraint(equalToConstant: settingsButtonLength)
		])

		settingsButton.addTarget(self, action: #selector(didTapSettingsButton), for: .touchUpInside)
	}

	convenience init() {
		self.init(
			keyInteraction: {_, _ in },
			specialButtonInteraction: {_, _ in },
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

	func set(isEditing: Bool) {
		leftCollectionStackView.set(isEditing: isEditing)
		rightCollectionStackView.set(isEditing: isEditing)
		settingsButton.isHidden = !isEditing
	}

	@objc private func didTapSettingsButton() {
		didRequestLayoutSettings()
	}
}
