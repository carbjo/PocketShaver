//
//  PreferencesAdvancedCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-15.
//

import UIKit

class PreferencesAdvancedRomCell: UITableViewCell {
	private lazy var containerView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.06)
		return view
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.font = .systemFont(ofSize: 15)
		label.textColor = .darkGray
		return label
	}()

	private lazy var selectRomFileButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .primaryActionConfig
		button.setTitle("Change ROM file", for: .normal)
		button.addTarget(self, action: #selector(selectRomFileButtonPushed), for: .touchUpInside)
		return button
	}()

	private let didTapSelectRomButton: (() -> Void)

	init(
		romType: RomType,
		didTapSelectRomButton: @escaping (() -> Void)
	) {
		self.didTapSelectRomButton = didTapSelectRomButton

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(containerView)
		containerView.addSubview(selectRomFileButton)
		containerView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),


			selectRomFileButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
			selectRomFileButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
			selectRomFileButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
			selectRomFileButton.heightAnchor.constraint(equalToConstant: 44),
			selectRomFileButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),

			containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),
		])

		configure(with: romType)
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(with romType: RomType) {
		if romType == .invalid {
			titleLabel.attributedText = NSAttributedString(string: "Current '\(RomManager.romFilename)' file does not pass validation")
			return
		}

		titleLabel.attributedText = "Current '\(RomManager.romFilename)' file is validated and identified as a <b>\(romType.description)</b>"
			.withBoldTagsReplacedWith(font: .boldSystemFont(ofSize: 15), color: .black)
	}

	@objc
	private func selectRomFileButtonPushed() {
		didTapSelectRomButton()
	}
}

class PreferencesAdvancedOptionCell: UITableViewCell {
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

	private let didSetIsEnabled: ((Bool) -> Void)

	init(
		optionInitialState: PreferencesAdvancedModel.OptionInitialState,
		didSetIsEnabled: @escaping ((Bool) -> Void)
	) {
		self.didSetIsEnabled = didSetIsEnabled

		super.init(style: .default, reuseIdentifier: nil)

		titleLabel.text = optionInitialState.option.title

		enabledSwitch.isOn = optionInitialState.isOn

		contentView.addSubview(enabledIndicationView)
		contentView.addSubview(titleLabel)
		contentView.addSubview(enabledSwitch)

		NSLayoutConstraint.activate([
			enabledIndicationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			enabledIndicationView.topAnchor.constraint(equalTo: contentView.topAnchor),
			enabledIndicationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			enabledIndicationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

			enabledSwitch.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
			enabledSwitch.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			enabledSwitch.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			enabledSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8)
		])

		updateEnabledIndicationView()
	}

	required init?(coder: NSCoder) { fatalError() }

	private func updateEnabledIndicationView() {
		enabledIndicationView.backgroundColor = enabledSwitch.isOn ? .veryLightGreen : .white
	}

	@objc private func enabledValueChanged() {
		updateEnabledIndicationView()

		didSetIsEnabled(enabledSwitch.isOn)
	}
}
