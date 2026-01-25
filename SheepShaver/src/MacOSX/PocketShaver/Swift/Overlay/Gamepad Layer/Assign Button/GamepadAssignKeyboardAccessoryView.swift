//
//  GamepadAssignKeyboardAccessoryView.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-27.
//

import UIKit

class GamepadAssignKeyboardAccessoryView: UIView {
	private lazy var dismissKeyboardButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage( ImageResource.keyboardChevronCompactDown.asSymbolImage(),
			for: .normal
		)
		button.configuration = buttonConfig()
		button.layer.cornerRadius = 8
		button.addTarget(self, action: #selector(dismissKeyboardButtonPushed), for: .touchUpInside)
		return button
	}()

	private var didTapDismissKeyboardButton: (() -> Void)?

	private let deviceScreenSize = UIScreen.deviceScreenSize

	init() {
		super.init(
			frame: .init(
				origin: .zero,
				size: .init(
					width: 100,
					height: 0
				)
			)
		)

		clipsToBounds = false

		addSubview(dismissKeyboardButton)

		let sideMargin: CGFloat
		switch deviceScreenSize {
		case .normal:
			sideMargin = 16
		case .small:
			sideMargin = 8
			dismissKeyboardButton.setTargetWidth(44)
		case .tiny:
			sideMargin = 4
			dismissKeyboardButton.setTargetWidth(38)
		}

		NSLayoutConstraint.activate([
			dismissKeyboardButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -sideMargin),
			dismissKeyboardButton.heightAnchor.constraint(equalToConstant: 44),
			dismissKeyboardButton.bottomAnchor.constraint(equalTo: bottomAnchor)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		let pointInSubviewCoordinateSpace = dismissKeyboardButton.convert(point, from: self)
		if dismissKeyboardButton.point(inside: pointInSubviewCoordinateSpace, with: event) {
			return true
		}

		return false
	}

	func configure(
		didTapDismissKeyboardButton: (() -> Void)?
	) {
		self.didTapDismissKeyboardButton = didTapDismissKeyboardButton
	}

	func fadeInDismissKeyboardButton() {
		dismissKeyboardButton.alpha = 1
	}

	func fadeOutDismissKeyboardButton() {
		dismissKeyboardButton.alpha = 0
	}

	@objc private func dismissKeyboardButtonPushed() {
		UIView.animate(withDuration: 0.2) {
			self.fadeOutDismissKeyboardButton()
		}
		didTapDismissKeyboardButton?()
	}
}

@MainActor
private func buttonConfig() -> UIButton.Configuration {
	var configuration = UIButton.Configuration.filled()
	configuration.baseForegroundColor = .white
	configuration.baseBackgroundColor = .lightGray
	let margin: CGFloat = UIScreen.deviceScreenSize == .tiny ? 12 : 16
	configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
	configuration.background.cornerRadius = 8
	return configuration
}
