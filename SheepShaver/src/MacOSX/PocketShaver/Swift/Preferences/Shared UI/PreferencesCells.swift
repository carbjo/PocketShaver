//
//  PreferencesCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-30.
//

import UIKit

class PreferencesEnabledSettingCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private lazy var enabledSwitch: UISwitch = {
		let uiSwitch = UISwitch.withoutConstraints()
		uiSwitch.addTarget(self, action: #selector(enabledValueChanged), for: .touchUpInside)
		return uiSwitch
	}()

	private let didSetIsEnabled: ((Bool) -> Void)

	init(
		title: String,
		isOn: Bool,
		didSetIsEnabled: @escaping ((Bool) -> Void)
	) {
		self.didSetIsEnabled = didSetIsEnabled

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		titleLabel.text = title
		enabledSwitch.isOn = isOn

		titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		enabledSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)

		contentView.addSubview(titleLabel)
		contentView.addSubview(enabledSwitch)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

			enabledSwitch.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
			enabledSwitch.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			enabledSwitch.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			enabledSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8)
		])
	}

	required init?(coder: NSCoder) { fatalError() }


	@objc private func enabledValueChanged() {
		didSetIsEnabled(enabledSwitch.isOn)
	}
}

class PreferencesInformationCell: UITableViewCell {
	enum Margin {
		case medium
		case short
		case tiny
		case none
	}

	private let informationLabel: LinkLabel

	init(
		text: String,
		upperMargin: Margin = .short,
		lowerMargin: Margin = .medium,
		tagConfig: StringTagConfig = .init(),
		separatorHidden: Bool = true,
		linkCallback: (() -> Void)? = nil
	) {
		informationLabel = .init(
			text: text,
			config: tagConfig,
			font: .systemFont(ofSize: 14),
			callback: linkCallback
		)

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		if separatorHidden {
			hideSeparator()
		}

		contentView.addSubview(informationLabel)

		NSLayoutConstraint.activate([
			informationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			informationLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: upperMargin.value),
			informationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			informationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -lowerMargin.value).withPriority(.required - 1)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(text: String) {
		informationLabel.label.text = text
	}
}

class PreferencesCardInformationCell: UITableViewCell {
	enum InformationType {
		case info
		case warning
	}

	private lazy var cardView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = Colors.informationCardBackground
		return view
	}()

	private lazy var iconImageView: UIImageView = {
		let imageView = UIImageView.withoutConstraints()
		imageView.image = UIImage(resource: ImageResource.infoCircle)
		imageView.tintColor = Colors.secondaryText

		NSLayoutConstraint.activate([
			imageView.widthAnchor.constraint(equalToConstant: 22),
			imageView.heightAnchor.constraint(equalToConstant: 22)
		])

		return imageView
	}()

	private lazy var closeButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(.init(resource: .xmarkCircleFill), for: .normal)
		button.tintColor = Colors.secondaryText
		button.addTarget(self, action: #selector(closeButtonPushed), for: .touchUpInside)
		return button
	}()

	private let informationLabel: LinkLabel

	private let didTapCloseButton: (() -> Void)?

	init(
		informationType: InformationType = .info,
		text: String,
		tagConfig: StringTagConfig? = .init(),
		separatorHidden: Bool = true,
		didTapCloseButton: (() -> Void)? = nil,
		linkCallback: (() -> Void)? = nil,
	) {
		let config = tagConfig ?? .init(
			boldAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.primaryText),
			highlightedAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.highlightedText)
		)

		informationLabel = .init(
			text: text,
			config: config,
			font: .systemFont(ofSize: 14),
			callback: linkCallback
		)

		self.didTapCloseButton = didTapCloseButton

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		switch informationType {
		case .info:
			iconImageView.image = UIImage(resource: ImageResource.infoCircle)
		case .warning:
			iconImageView.image = ImageResource.exclamationmarkTriangle.asSymbolImage()
		}

		if separatorHidden {
			hideSeparator()
		}

		cardView.setContentHuggingPriority(.required, for: .horizontal)

		cardView.addSubview(iconImageView)
		cardView.addSubview(informationLabel)
		contentView.addSubview(cardView)

		if didTapCloseButton != nil {
			cardView.addSubview(closeButton)

			NSLayoutConstraint.activate([
				cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

				closeButton.leadingAnchor.constraint(equalTo: informationLabel.trailingAnchor, constant: 8),
				closeButton.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
				closeButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16)
			])
		} else {
			NSLayoutConstraint.activate([
				cardView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
				informationLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16)
			])
		}

		NSLayoutConstraint.activate([
			cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
			cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

			cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

			iconImageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
			iconImageView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

			informationLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 16),
			informationLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
			informationLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12).withPriority(.required - 1)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(text: String) {
		informationLabel.label.text = text
	}

	@objc
	private func closeButtonPushed() {
		didTapCloseButton?()
	}
}

class PreferencesEmptyStateCell: UITableViewCell {
	private lazy var stackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .vertical
		stackView.spacing = 8
		stackView.alignment = .center
		stackView.distribution = .fill
		return stackView
	}()

	init(
		title: String,
		titleTagConfig: StringTagConfig = .init(),
		subtitles: [(String, StringTagConfig)] = [],
		separatorHidden: Bool = false
	) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		let titleLabel = LinkLabel(
			text: title,
			config: titleTagConfig,
			font: .boldSystemFont(ofSize: 18),
			textColor: Colors.primaryText,
			textAlignment: .center
		)
		stackView.addArrangedSubview(titleLabel)

		for (subtitleText, subtitleConfig) in subtitles {
			let subtitleLabel = LinkLabel(
				text: subtitleText,
				config: subtitleConfig,
				font: .systemFont(ofSize: 14),
				textAlignment: .center
			)
			stackView.addArrangedSubview(subtitleLabel)
		}

		contentView.addSubview(stackView)

		let margin: CGFloat = UIScreen.isSESize ? 16 : 32

		NSLayoutConstraint.activate([
			stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
			stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
			stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
			stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
		])

		if separatorHidden {
			hideSeparator()
		}
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesRadioButtonChoiceCell: UITableViewCell {
	private lazy var checkboxImageView: UIImageView = {
		let view = UIImageView.withoutConstraints()
		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: 22),
			view.heightAnchor.constraint(equalToConstant: 22)
		])
		view.tintColor = Colors.secondaryText
		return view
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.primaryText
		return label
	}()

	init(
		title: String,
		isSelected: Bool
	) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		titleLabel.text = title

		contentView.addSubview(checkboxImageView)
		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			checkboxImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			checkboxImageView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

			titleLabel.leadingAnchor.constraint(equalTo: checkboxImageView.trailingAnchor, constant: 8),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
		])

		configure(isSelected: isSelected)
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(isSelected: Bool) {
		checkboxImageView.image = UIImage(resource: isSelected ? .checkmarkCircleFill : .circle)
	}
}

extension PreferencesInformationCell.Margin {
	var value: CGFloat {
		switch self {
		case .medium:
			return 16
		case .short:
			return 8
		case .tiny:
			return 2
		case .none:
			return 0
		}
	}
}
