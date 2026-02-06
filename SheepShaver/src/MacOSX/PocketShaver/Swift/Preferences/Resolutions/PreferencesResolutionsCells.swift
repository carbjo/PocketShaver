//
//  PreferencesResolutionsCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-07.
//

import UIKit

class PreferencesResolutionsInformationCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	init(
		isPortraitMode: Bool,
		alwaysLandscapeMode: Bool,
		initialMonitorResolutionCount: Int
	) {
		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 0).withPriority(.required - 1)
		])

		configure(
			isPortraitMode: isPortraitMode,
			alwaysLandscapeMode: alwaysLandscapeMode,
			currentMonitorResolutionCount: initialMonitorResolutionCount
		)
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(
		isPortraitMode: Bool,
		alwaysLandscapeMode: Bool,
		currentMonitorResolutionCount: Int
	) {
		let thisOrientationString = isPortraitMode ? "portrait" : "landscape"
		let otherOrientationString = isPortraitMode ? "landscape" : "portrait"
		let maxNumberOfSimultaniousResolutions = MonitorResolutionManager.maxNumberOfSimultaniousResolutions

		let orientationString: String
		if alwaysLandscapeMode {
			orientationString = "Currently displaying settings for landscape mode, since 'Always boot in landscape mode' is toggled on in Advanced settings."
		} else {
			orientationString = "Currently displaying settings for \(thisOrientationString) mode. Rotate screen to access \(otherOrientationString) mode settings."
		}

		titleLabel.attributedText = "This list controls what monitor resolutions are available to Mac OS. Changing active resolution is still done with Monitors app, inside Mac OS.\n\n• \(orientationString)\n\n• When booting from an installation CD, the operating system will always pick the highest possible resolution, without any possibility of changing it.\n\n• Mac OS allows a maximum number of \(maxNumberOfSimultaniousResolutions) monitor resolutions to be available simultaniously. Current number of selected resolutions: <b>\(currentMonitorResolutionCount)</b>"
			.withTagsReplaced(by: .init(boldAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.primaryText)))
	}
}

class PreferencesResolutionsFooterCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	init(
		title: String
	) {
		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		titleLabel.text = title

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1)
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesResolutionsMonitorResolutionCell: UITableViewCell {
	private lazy var enabledIndicationView: UIView = {
		UIView.withoutConstraints()
	}()

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

	private lazy var hiddenCountIsFullInfoButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.isHidden = true
		button.addTarget(self, action: #selector(hiddenCountIsFullInfoButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var auxillaryLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private let option: MonitorResolutionOption
	private let isAlwaysOn: Bool
	private let didTapHiddenCountIsFullInfoButton: (() -> Void)
	private let didSetIsEnabled: ((MonitorResolutionOption, Bool) -> Void)

	init(
		option: MonitorResolutionOption,
		isOn: Bool,
		isAlwaysOn: Bool,
		countIsFull: Bool,
		didTapHiddenCountIsFullInfoButton: @escaping (() -> Void),
		didSetIsEnabled: @escaping ((MonitorResolutionOption, Bool) -> Void)
	) {
		self.option = option
		self.isAlwaysOn = isAlwaysOn
		self.didTapHiddenCountIsFullInfoButton = didTapHiddenCountIsFullInfoButton
		self.didSetIsEnabled = didSetIsEnabled

		super.init(style: .default, reuseIdentifier: nil)

		titleLabel.text = option.label

		enabledSwitch.isOn = isOn || isAlwaysOn
		enabledSwitch.isEnabled = !isAlwaysOn

		enabledSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
		auxillaryLabel.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)

		contentView.addSubview(enabledIndicationView)
		contentView.addSubview(titleLabel)
		contentView.addSubview(enabledSwitch)
		contentView.addSubview(hiddenCountIsFullInfoButton)

		NSLayoutConstraint.activate([
			enabledIndicationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			enabledIndicationView.topAnchor.constraint(equalTo: contentView.topAnchor),
			enabledIndicationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			enabledIndicationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.centerYAnchor.constraint(equalTo: enabledSwitch.centerYAnchor),
			titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: enabledSwitch.leadingAnchor, constant: -16),

			enabledSwitch.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12).withPriority(.defaultHigh),
			enabledSwitch.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			enabledSwitch.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
			enabledSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),

			hiddenCountIsFullInfoButton.leadingAnchor.constraint(equalTo: enabledSwitch.leadingAnchor),
			hiddenCountIsFullInfoButton.topAnchor.constraint(equalTo: enabledSwitch.topAnchor),
			hiddenCountIsFullInfoButton.trailingAnchor.constraint(equalTo: enabledSwitch.trailingAnchor),
			hiddenCountIsFullInfoButton.bottomAnchor.constraint(equalTo: enabledSwitch.bottomAnchor)
		])

		if let auxillaryInformation = option.auxillaryInformation {
			contentView.addSubview(auxillaryLabel)

			auxillaryLabel.text = auxillaryInformation

			NSLayoutConstraint.activate([
				auxillaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
				auxillaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
				auxillaryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
				auxillaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8)
			])
		}

		configure(countIsFull: countIsFull)
		updateEnabledIndicationView()
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(countIsFull: Bool) {
		guard !isAlwaysOn else {
			return
		}

		if countIsFull,
		   !enabledSwitch.isOn {
			enabledSwitch.isEnabled = false
			hiddenCountIsFullInfoButton.isHidden = false
		} else if !countIsFull {
			enabledSwitch.isEnabled = true
			hiddenCountIsFullInfoButton.isHidden = true
		}
	}

	private func updateEnabledIndicationView() {
		enabledIndicationView.backgroundColor = enabledSwitch.isOn ? Colors.selectedCell : Colors.primaryBackground
	}

	@objc private func enabledValueChanged() {
		updateEnabledIndicationView()

		didSetIsEnabled(option, enabledSwitch.isOn)
	}

	@objc private func hiddenCountIsFullInfoButtonPushed() {
		didTapHiddenCountIsFullInfoButton()
	}
}

