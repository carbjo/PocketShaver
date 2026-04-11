//
//  PreferencesAdvancedCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-15.
//

import UIKit

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
		let ramSetting = PreferencesGeneralRamSetting(rawValue: stepperValue) ?? .n256
		stepperLabel.text = ramSetting.label
		didChangeStepperValue(ramSetting)
	}
}

class PreferencesAdvancedMiscellaneousCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.textColor = Colors.primaryText
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
			containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8).withPriority(.required - 1),
			containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),
			containerView.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
		])

		configure(with: romDescription)
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(with romDescription: String) {
		titleLabel.attributedText = "PocketShaver is bootstrapped by an install disc identified as belonging to category <b>\(romDescription)</b>. Tap 'Select Mac OS install disc' if you want to redo bootstrapping with another install disc."
			.withTagsReplaced(by: .init(boldAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.primaryText)))
	}

	@objc
	private func selectInstallDiskFileButtonPushed() {
		didTapSelectInstallDiskButton()
	}
}

class PreferencesAdvancedJustAboveOffsetSettingCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.text = "Hover just above offset"
		return label
	}()

	private lazy var slider: UISlider = {
		let slider = UISlider.withoutConstraints()
		slider.minimumValue = 0.5
		slider.maximumValue = 1.5
		slider.tintColor = .lightGray
		return slider
	}()

	private lazy var valueLabel: UILabel = {
		UILabel.withoutConstraints()
	}()

	private lazy var hiddenValueLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.text = "188%"
		label.isHidden = true
		return label
	}()

	private var previousValue: Float
	private var deltaSinceLastIsChangingValueCall: Float = 0

	private let isChangingValue: (() -> Void)
	private let didChangeValue: ((Float) -> Void)

	init(
		initialOffsetSetting: Float,
		isChangingValue: @escaping (() -> Void),
		didChangeValue: @escaping ((Float) -> Void)
	) {
		self.previousValue = initialOffsetSetting
		self.isChangingValue = isChangingValue
		self.didChangeValue = didChangeValue

		super.init(style: .default, reuseIdentifier: nil)

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

		slider.value = initialOffsetSetting

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

		let delta = slider.value - previousValue
		previousValue = slider.value
		deltaSinceLastIsChangingValueCall += delta
		if abs(deltaSinceLastIsChangingValueCall) > 0.01 {
			deltaSinceLastIsChangingValueCall = 0
			isChangingValue()
		}
	}

	@objc func didRelease() {
		didChangeValue(slider.value)
	}
}

class PreferencesAdvancedGammaRampSettingCell: UITableViewCell {
	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in GammaRampSetting.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((GammaRampSetting) -> Void)

	init(
		initialGammaRampSetting: GammaRampSetting,
		didChangeSelection: @escaping ((GammaRampSetting) -> Void)
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

		segmentedControl.selectedSegmentIndex = GammaRampSetting.allCases.enumerated().first(where: { initialGammaRampSetting == $1 })!.0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let index = segmentedControl.selectedSegmentIndex
		let setting = GammaRampSetting.allCases.enumerated().first(where: { index == $0.0 })!.1

		didChangeSelection(setting)
	}
}

extension PreferencesGeneralRamSetting {
	var label: String {
		"\(ramInMB) MB"
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

private extension GammaRampSetting {
	var label: String {
		switch self {
		case .osDefined: return "OS defined"
		case .linear: return "Linear"
		}
	}
}
