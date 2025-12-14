//
//  PreferencesAdvancedCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-15.
//

import UIKit

class PreferencesAdvancedBootstrapCell: UITableViewCell {
	private lazy var containerView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = Colors.informationCardBackground
		return view
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.font = .systemFont(ofSize: 15)
		label.textColor = Colors.secondaryText
		return label
	}()

	private lazy var selectInstallDiskFileButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .primaryActionConfig
		button.setTitle("Select Mac OS install disc file", for: .normal)
		button.addTarget(self, action: #selector(selectInstallDiskFileButtonPushed), for: .touchUpInside)
		return button
	}()

	private let didTapSelectInstallDiskButton: (() -> Void)

	init(
		romDescription: String,
		didTapSelectInstallDiskButton: @escaping (() -> Void)
	) {
		self.didTapSelectInstallDiskButton = didTapSelectInstallDiskButton

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(containerView)
		containerView.addSubview(titleLabel)
		containerView.addSubview(selectInstallDiskFileButton)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),


			selectInstallDiskFileButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
			selectInstallDiskFileButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
			selectInstallDiskFileButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
			selectInstallDiskFileButton.heightAnchor.constraint(equalToConstant: 44),
			selectInstallDiskFileButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),

			containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),
		])

		configure(with: romDescription)
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(with romDescription: String) {
		titleLabel.attributedText = "PocketShaver is bootstrapped by an install disc identified as belonging to category <b>\(romDescription)</b>. Tap 'Select Mac OS install disc' if you want to redo bootstrapping with another install disc."
			.withBoldTagsReplacedWith(font: .boldSystemFont(ofSize: 15), color: Colors.primaryText)
	}

	@objc
	private func selectInstallDiskFileButtonPushed() {
		didTapSelectInstallDiskButton()
	}
}

class PreferencesAdvancedRamStepperCell: UITableViewCell {
	private lazy var stepper: UIStepper = {
		let stepper = UIStepper.withoutConstraints()
		stepper.isContinuous = false
		stepper.minimumValue = 0
		stepper.maximumValue = Double(PreferencesGeneralRamSetting.allCases.count - 1)
		stepper.addTarget(self, action: #selector(stepperValueChanged), for: .valueChanged)
		return stepper
	}()

	private lazy var stepperLabel: UILabel = {
		UILabel.withoutConstraints()
	}()

	private lazy var informationLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText
		label.text = "Changes in RAM value requires PocketShaver to restart."
		return label
	}()

	private let didChangeStepperValue: ((PreferencesGeneralRamSetting) -> Void)

	init(
		initialRamSettting: PreferencesGeneralRamSetting,
		didChangeStepperValue: @escaping ((PreferencesGeneralRamSetting) -> Void)
	) {
		self.didChangeStepperValue = didChangeStepperValue

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(stepper)
		contentView.addSubview(stepperLabel)
		contentView.addSubview(informationLabel)

		NSLayoutConstraint.activate([
			stepper.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			stepper.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

			stepperLabel.centerYAnchor.constraint(equalTo: stepper.centerYAnchor),
			stepperLabel.leadingAnchor.constraint(equalTo: stepper.trailingAnchor, constant: 16),

			informationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			informationLabel.topAnchor.constraint(equalTo: stepper.bottomAnchor, constant: 16),
			informationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			informationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
		])

		stepper.value = Double(initialRamSettting.rawValue)
		stepperLabel.text = initialRamSettting.label
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func stepperValueChanged() {
		let stepperValue = Int(stepper.value)
		let ramSetting = PreferencesGeneralRamSetting(rawValue: stepperValue) ?? .n128
		stepperLabel.text = ramSetting.label
		didChangeStepperValue(ramSetting)
	}
}

class PreferencesAdvancedMiscellaneousCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	init(
		title: String
	) {
		super.init(style: .default, reuseIdentifier: nil)

		titleLabel.text = title

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([

			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1)
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesAdvancedFrameRateSettingCell: UITableViewCell {
	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in FrameRateSetting.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((FrameRateSetting) -> Void)

	init(
		initialFrameRateSetting: FrameRateSetting,
		didChangeSelection: @escaping ((FrameRateSetting) -> Void)
	) {
		self.didChangeSelection = didChangeSelection

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(segmentedControl)

		NSLayoutConstraint.activate([
			segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),
			segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			segmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 350)
		])

		segmentedControl.selectedSegmentIndex = FrameRateSetting.allCases.enumerated().first(where: { initialFrameRateSetting == $1 })!.0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let index = segmentedControl.selectedSegmentIndex
		let setting = FrameRateSetting.allCases.enumerated().first(where: { index == $0.0 })!.1

		didChangeSelection(setting)
	}
}

class PreferencesAdvancedRelativeMouseModeSettingCell: UITableViewCell {
	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in RelativeMouseModeSetting.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((RelativeMouseModeSetting) -> Void)

	init(
		initialRelativeMouseModeSetting: RelativeMouseModeSetting,
		didChangeSelection: @escaping ((RelativeMouseModeSetting) -> Void)
	) {
		self.didChangeSelection = didChangeSelection

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(segmentedControl)

		NSLayoutConstraint.activate([
			segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),
			segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			segmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 350)
		])

		segmentedControl.selectedSegmentIndex = RelativeMouseModeSetting.allCases.enumerated().first(where: { initialRelativeMouseModeSetting == $1 })!.0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let index = segmentedControl.selectedSegmentIndex
		let setting = RelativeMouseModeSetting.allCases.enumerated().first(where: { index == $0.0 })!.1

		didChangeSelection(setting)
	}
}

class PreferencesAdvancedRelativeMouseModeFooterCell: UITableViewCell {
	private lazy var informationLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText
		return label
	}()

	init() {
		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(informationLabel)

		NSLayoutConstraint.activate([
			informationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			informationLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			informationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			informationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1)
		])

		let attrString = NSMutableAttributedString()
		attrString.append(.init(string: "Some games and apps require relative mouse mode to function. If set to Manual or Automatic, Relative mouse mode can be toggled on and off by tapping the "))

		let mouseIconAttachment = NSTextAttachment()
		mouseIconAttachment.image = UIImage(resource: .computermouse)
			.withRenderingMode(.alwaysTemplate)
			.applyingSymbolConfiguration(.init(pointSize: 12))
		attrString.append(.init(attachment: mouseIconAttachment))

		attrString.append(.init(string: " button above the keyboard."))

		informationLabel.attributedText = attrString
	}

	required init?(coder: NSCoder) { fatalError() }
}

private extension FrameRateSetting {
	var label: String {
		switch self {
		case .f60hz: return "60 hz"
		case .f75hz: return "75 hz"
		case .f120hz: return "120 hz"
		}
	}
}

private extension RelativeMouseModeSetting {
	var label: String {
		switch self {
		case .manual: return "Manual"
		case .automatic: return "Automatic"
		case .alwaysOn: return "Always on"
		}
	}
}
