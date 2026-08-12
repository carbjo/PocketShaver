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
		// Mac Catalyst's Mac idiom renders UISwitch as an AppKit checkbox by
		// default; keep the sliding switch everywhere (no-op on iPhone/iPad).
		uiSwitch.preferredStyle = .sliding
		// .valueChanged (not .touchUpInside): dragging the thumb on a pointer
		// releases outside the switch bounds, which never fires .touchUpInside,
		// so the toggle would silently fail to persist and snap back.
		uiSwitch.addTarget(self, action: #selector(enabledValueChanged), for: .valueChanged)
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
	enum MarginSize {
		case regular
		case small
	}

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
		isSelected: Bool,
		marginSize: MarginSize = .regular
	) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = .clear

		titleLabel.text = title

		contentView.addSubview(checkboxImageView)
		contentView.addSubview(titleLabel)

		let margin: CGFloat = marginSize == .regular ? 16 : 8

		NSLayoutConstraint.activate([
			checkboxImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			checkboxImageView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

			titleLabel.leadingAnchor.constraint(equalTo: checkboxImageView.trailingAnchor, constant: 8),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -margin)
		])

		configure(isSelected: isSelected)
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(isSelected: Bool) {
		checkboxImageView.image = UIImage(resource: isSelected ? .checkmarkCircleFill : .circle)
	}
}

class PreferencesPercentageSliderCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private lazy var slider: UISlider = {
		let slider = UISlider.withoutConstraints()
		slider.tintColor = .lightGray
		return slider
	}()

	private lazy var valueLabel: UILabel = {
		UILabel.withoutConstraints()
	}()

	private lazy var hiddenValueLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.text = "188%" // Widest case
		label.isHidden = true
		return label
	}()

	private var previousValue: CGFloat
	private var deltaSinceLastIsChangingValueCall: Float = 0

	private let isChangingValue: (() -> Void)
	private let didChangeValue: ((CGFloat) -> Void)

	init(
		title: String,
		minimumValue: Float,
		maximumValue: Float,
		initialOffsetSetting: CGFloat,
		isChangingValue: @escaping (() -> Void),
		didChangeValue: @escaping ((CGFloat) -> Void)
	) {
		self.previousValue = initialOffsetSetting
		self.isChangingValue = isChangingValue
		self.didChangeValue = didChangeValue

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		titleLabel.text = title
		slider.minimumValue = minimumValue
		slider.maximumValue = maximumValue

		contentView.addSubview(titleLabel)
		contentView.addSubview(slider)
		contentView.addSubview(hiddenValueLabel)
		contentView.addSubview(valueLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

			slider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),

			slider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			slider.widthAnchor.constraint(lessThanOrEqualToConstant: 350),

			hiddenValueLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
			hiddenValueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
			hiddenValueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),

			valueLabel.centerYAnchor.constraint(equalTo: hiddenValueLabel.centerYAnchor),
			valueLabel.trailingAnchor.constraint(equalTo: hiddenValueLabel.trailingAnchor)
		])

		slider.value = Float(initialOffsetSetting)

		slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
		slider.addTarget(self, action: #selector(didRelease), for: .touchUpInside)
		slider.addTarget(self, action: #selector(didRelease), for: .touchUpOutside)
		slider.addTarget(self, action: #selector(didRelease), for: .touchCancel)

		valueChanged()
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc
	private func valueChanged() {
		let percent = Int(slider.value * 100)
		valueLabel.text = "\(percent)%"

		let delta = CGFloat(slider.value) - previousValue
		previousValue = CGFloat(slider.value)
		deltaSinceLastIsChangingValueCall += Float(delta)
		if abs(deltaSinceLastIsChangingValueCall) > 0.01 {
			deltaSinceLastIsChangingValueCall = 0
			isChangingValue()
		}
	}

	@objc func didRelease() {
		didChangeValue(CGFloat(slider.value))
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
