//
//  InformationView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-09.
//

import UIKit

class InformationView: UIVisualEffectView {
	private lazy var stackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .vertical
		stackView.spacing = 8
		stackView.alignment = .center
		stackView.distribution = .fill
		return stackView
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.textColor = .white
		label.textAlignment = .center
		label.font = label.font.withSize(40)
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private lazy var hintStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .horizontal
		stackView.spacing = 10
		stackView.alignment = .center
		stackView.distribution = .fill
		return stackView
	}()

	private lazy var hintIconImageView: UIImageView = {
		let imageView = UIImageView.withoutConstraints()
		imageView.tintColor = .white
		return imageView
	}()

	private lazy var hintLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.textColor = .white
		label.textAlignment = .center
		label.font = label.font.withSize(15)
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	init() {
		let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
		super.init(effect: blurEffect)

		isUserInteractionEnabled = false
		backgroundColor = .clear
		clipsToBounds = true
		layer.cornerRadius = 8

		contentView.addSubview(stackView)
		stackView.addArrangedSubview(titleLabel)
		stackView.addArrangedSubview(hintStackView)

		hintStackView.addArrangedSubview(hintIconImageView)
		hintStackView.addArrangedSubview(hintLabel)

		titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

		NSLayoutConstraint.activate([
			stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func show(
		title: String? = nil,
		hintIcon: ImageResource? = nil,
		hint: String? = nil,
		attributedHint: NSAttributedString? = nil,
		atBottom: Bool
	) {
		let screenHeight = UIScreen.main.bounds.height

		if let title {
			titleLabel.text = title
			titleLabel.isHidden = false
		} else {
			titleLabel.isHidden = true
		}

		if let hintIcon {
			hintIconImageView.image = hintIcon.asSymbolImage()
			hintIconImageView.isHidden = false
		} else {
			hintIconImageView.isHidden = true
		}

		if let attributedHint {
			hintLabel.attributedText = attributedHint
			hintLabel.isHidden = false
		} else if let hint {
			hintLabel.text = hint
			hintLabel.isHidden = false
		} else {
			hintLabel.isHidden = true
		}

		if atBottom {
			transform = .init(translationX: 0, y: screenHeight/2)
		} else {
			transform = .identity
		}

		alpha = 0
		isHidden = false

		layoutIfNeeded()

		UIView.animate(
			withDuration: 0.28,
			delay: 0.0,
			usingSpringWithDamping: 0.6,
			initialSpringVelocity: 1.5,
			animations: {
				self.alpha = 1
			},
			completion: { _ in
				UIView.animate(
					withDuration: 0.6,
					delay: hint != nil ? 1.5 : 0.55,
					animations: {
					self.alpha = 0
				}) { _ in
					self.isHidden = false
				}
			}
		)
	}

	func showInformation(
		for state: OverlayState,
		gamepadSettingsName: String,
		showHints: Bool,
		atBottom: Bool = false
	) {
		guard UIDevice.deviceType != .mac else {
			return
		}

		if showHints {
			switch state {
			case .normal:
				show(hint: "Three finger swipe ↓ for Gamepad mode, ↑ for Keyboard mode", atBottom: atBottom)
			case .showingGamepad:
				show(
					title: gamepadSettingsName,
					hint: "Three finger swipe ↓ to edit, ← or → to switch layout, ↑ to dismiss",
					atBottom: atBottom
				)
			case .editingGamepad:
				show(
					title: "Editing \(gamepadSettingsName)",
					hint: "Three finger swipe ↑ to exit edit mode", atBottom: atBottom
				)
			case .showingKeyboard:
				let attrString = NSMutableAttributedString()

				attrString.append(.init(string: "Two finger swipe ↑ or ↓ to scroll screen\nTap "))

				let keyboardDownIconAttachment = NSTextAttachment()
				keyboardDownIconAttachment.image = ImageResource.keyboardChevronCompactDown.asSymbolImage()
				
				attrString.append(.init(attachment: keyboardDownIconAttachment))

				attrString.append(.init(string: " to dismiss."))

				show(attributedHint: attrString, atBottom: atBottom)
			}
		} else if state == .showingGamepad {
			show(
				title: gamepadSettingsName,
				atBottom: atBottom
			)
		}
	}
}
