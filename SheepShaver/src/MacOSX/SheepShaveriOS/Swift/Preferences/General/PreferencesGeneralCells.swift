//
//  PreferencesGeneralCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit

class PreferencesGeneralSetupInstructionsCell: UITableViewCell {
	private lazy var containerView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.06)
		return view
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = .darkGray

		var string = "Read initial setup instructions if you plan to install Classic Mac OS from scratch. Contains crucial tip on how to <b>not get stuck in installation progress</b> and <b>get audio working</b>, after intallation.\n\nThe instructions can still be accessed from Advanced tab, after dismissal."

		label.attributedText = string
			.withBoldTagsReplacedWith(
				font: .boldSystemFont(ofSize: 14),
				color: .black
			)

		return label
	}()

	private lazy var closeButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(.init(resource: .xmarkCircleFill), for: .normal)
		button.tintColor = .darkGray
		button.addTarget(self, action: #selector(closeButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var readButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .secondaryActionConfig
		button.setTitle("Read instructions", for: .normal)
		button.addTarget(self, action: #selector(readButtonPushed), for: .touchUpInside)
		return button
	}()

	private let didTapReadButton: (() -> Void)
	private let didTapCloseButton: (() -> Void)

	init(
		didTapReadButton: @escaping (() -> Void),
		didTapCloseButton: @escaping (() -> Void)
	) {
		self.didTapReadButton = didTapReadButton
		self.didTapCloseButton = didTapCloseButton

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		closeButton.setContentHuggingPriority(.required, for: .horizontal)
		titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

		containerView.addSubview(titleLabel)
		containerView.addSubview(closeButton)
		containerView.addSubview(readButton)
		contentView.addSubview(containerView)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),

			readButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
			readButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
			readButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
			readButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),
			readButton.heightAnchor.constraint(equalToConstant: 44),

			containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),

			closeButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
			closeButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
			closeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc
	private func readButtonPushed() {
		didTapReadButton()
	}

	@objc
	private func closeButtonPushed() {
		didTapCloseButton()
	}
}

class PreferencesGeneralBootstrapCell: UITableViewCell {
	private lazy var containerView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.06)
		return view
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.font = .systemFont(ofSize: 14)
		label.textColor = .darkGray
		label.text = "Tap button below to select a compatible Mac OS install disc file. This is needed to bootstrap PocketShaver."
		return label
	}()

	private lazy var buttonStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .vertical
		stackView.spacing = 12
		stackView.distribution = .fill
		stackView.alignment = .fill
		return stackView
	}()

	private lazy var selectInstallDiskFileButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .primaryActionConfig
		button.setTitle("Select Mac OS install disc file", for: .normal)
		button.addTarget(self, action: #selector(selectInstallDiskFileButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var displayCompatibilityListButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .secondaryActionConfig
		button.setTitle("Compatibility list", for: .normal)
		button.addTarget(self, action: #selector(displayCompatibilityListButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var checkmarkIconImageView: UIImageView = {
		let imageView = UIImageView.withoutConstraints()
		imageView.image = UIImage(resource: .checkmarkCircleFill)
		imageView.tintColor = CustomColors.okColor
		imageView.isHidden = true
		imageView.contentMode = .scaleAspectFit

		NSLayoutConstraint.activate([
			imageView.widthAnchor.constraint(equalToConstant: 44),
			imageView.heightAnchor.constraint(equalToConstant: 44)
		])

		return imageView
	}()

	private let didTapSelectInstallDiskButton: (() -> Void)
	private let didTapCompatibilityListButton: (() -> Void)

	init(
		didTapSelectInstallDiskButton: @escaping (() -> Void),
		didTapCompatibilityListButton: @escaping (() -> Void)

	) {
		self.didTapSelectInstallDiskButton = didTapSelectInstallDiskButton
		self.didTapCompatibilityListButton = didTapCompatibilityListButton

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(containerView)

		containerView.addSubview(titleLabel)
		containerView.addSubview(checkmarkIconImageView)
		containerView.addSubview(buttonStackView)
		buttonStackView.addArrangedSubview(selectInstallDiskFileButton)
		buttonStackView.addArrangedSubview(displayCompatibilityListButton)

		NSLayoutConstraint.activate([
			checkmarkIconImageView.centerXAnchor.constraint(equalTo: buttonStackView.centerXAnchor),
			checkmarkIconImageView.centerYAnchor.constraint(equalTo: buttonStackView.centerYAnchor),

			titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

			buttonStackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
			buttonStackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
			buttonStackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
			buttonStackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),

			selectInstallDiskFileButton.heightAnchor.constraint(equalToConstant: 44),
			displayCompatibilityListButton.heightAnchor.constraint(equalToConstant: 44),

			containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func displayCheckmark() {
		selectInstallDiskFileButton.alpha = 0
		displayCompatibilityListButton.alpha = 0
		checkmarkIconImageView.isHidden = false
	}

	@objc
	private func selectInstallDiskFileButtonPushed() {
		didTapSelectInstallDiskButton()
	}

	@objc
	private func displayCompatibilityListButtonPushed() {
		didTapCompatibilityListButton()
	}
}

class PreferencesGeneralErrorCell: UITableViewCell {
	private lazy var errorLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .boldSystemFont(ofSize: 14)
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.textColor = CustomColors.notOkColor
		return label
	}()

	init(title: String) {
		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		errorLabel.text = title

		contentView.addSubview(errorLabel)

		NSLayoutConstraint.activate([
			errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			errorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			errorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			errorLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesGeneralDiskColumnsDescriptionCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.text = "Filename"
		label.font = .boldSystemFont(ofSize: 14)
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private lazy var cdromLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.text = "CDROM"
		label.font = .boldSystemFont(ofSize: 14)
		return label
	}()

	private lazy var hiddenCdromSwitch: UISwitch = {
		let uiSwich = UISwitch.withoutConstraints()
		uiSwich.isHidden = true
		return uiSwich
	}()

	private lazy var enabledLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.text = "Mount"
		label.font = .boldSystemFont(ofSize: 14)
		return label
	}()

	private lazy var hiddenEnabledSwitch: UISwitch = {
		let uiSwich = UISwitch.withoutConstraints()
		uiSwich.isHidden = true
		return uiSwich
	}()

	init() {
		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(titleLabel)
		contentView.addSubview(hiddenCdromSwitch)
		contentView.addSubview(hiddenEnabledSwitch)
		contentView.addSubview(cdromLabel)
		contentView.addSubview(enabledLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.centerYAnchor.constraint(equalTo: hiddenEnabledSwitch.centerYAnchor),
			titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: hiddenCdromSwitch.leadingAnchor, constant: -16),

			hiddenCdromSwitch.centerYAnchor.constraint(equalTo: hiddenEnabledSwitch.centerYAnchor),
			hiddenEnabledSwitch.leadingAnchor.constraint(equalTo: hiddenCdromSwitch.trailingAnchor, constant: 12),
			hiddenEnabledSwitch.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
			hiddenEnabledSwitch.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
			hiddenEnabledSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),

			cdromLabel.centerYAnchor.constraint(equalTo: hiddenCdromSwitch.centerYAnchor),
			cdromLabel.trailingAnchor.constraint(equalTo: hiddenCdromSwitch.trailingAnchor),
			enabledLabel.centerYAnchor.constraint(equalTo: hiddenEnabledSwitch.centerYAnchor),
			enabledLabel.trailingAnchor.constraint(equalTo: hiddenEnabledSwitch.trailingAnchor)
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesGeneralDiskCell: UITableViewCell {
	private lazy var enabledIndicationView: UIView = {
		UIView.withoutConstraints()
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private lazy var cdromSwitch: UISwitch = {
		let uiSwitch = UISwitch.withoutConstraints()
		uiSwitch.addTarget(self, action: #selector(cdRomValueChanged), for: .touchUpInside)
		return uiSwitch
	}()

	private lazy var enabledSwitch: UISwitch = {
		let uiSwitch = UISwitch.withoutConstraints()
		uiSwitch.addTarget(self, action: #selector(enabledValueChanged), for: .touchUpInside)
		return uiSwitch
	}()

	private let filename: String
	private let didSetIsEnabled: ((String, Bool) -> Void)
	private let didSetIsCdRom: ((String, Bool) -> Void)

	init(
		disk: Disk,
		didSetIsEnabled: @escaping ((String, Bool) -> Void),
		didSetIsCdRom: @escaping ((String, Bool) -> Void)
	) {
		self.filename = disk.filename
		self.didSetIsEnabled = didSetIsEnabled
		self.didSetIsCdRom = didSetIsCdRom

		super.init(style: .default, reuseIdentifier: nil)

		titleLabel.text = disk.filename

		cdromSwitch.isOn = disk.isCdRom
		enabledSwitch.isOn = disk.isEnabled

		contentView.addSubview(enabledIndicationView)
		contentView.addSubview(titleLabel)
		contentView.addSubview(cdromSwitch)
		contentView.addSubview(enabledSwitch)

		NSLayoutConstraint.activate([
			enabledIndicationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			enabledIndicationView.topAnchor.constraint(equalTo: contentView.topAnchor),
			enabledIndicationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			enabledIndicationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
			titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cdromSwitch.leadingAnchor, constant: -16),

			cdromSwitch.centerYAnchor.constraint(equalTo: enabledSwitch.centerYAnchor),
			enabledSwitch.leadingAnchor.constraint(equalTo: cdromSwitch.trailingAnchor, constant: 12),
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

		didSetIsEnabled(filename, enabledSwitch.isOn)
	}

	@objc private func cdRomValueChanged() {
		didSetIsCdRom(filename, cdromSwitch.isOn)
	}
}

class PreferencesGeneralDiskEmptyStateCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .boldSystemFont(ofSize: 18)
		label.text = "No files found"
		label.textAlignment = .center
		return label
	}()

	init() {
		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesGeneralDiskSectionActionsCell: UITableViewCell {
	private lazy var informationLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = .darkGray
		let supportedFormatsString = DiskManager.supportedFileExtensions.map({ ".\($0)" }).joined(separator: ", ")
		label.text = "Disks placed in the root of PocketShaver share folder will appear here. Supported formats: \(supportedFormatsString)."
		return label
	}()

	private lazy var buttonStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .vertical
		stackView.spacing = 12
		stackView.distribution = .fill
		stackView.alignment = .fill
		return stackView
	}()

	private lazy var createDiskButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .primaryActionConfig
		button.setTitle("Create empty disk", for: .normal)
		button.addTarget(self, action: #selector(createDiskButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var reloadDisksButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .secondaryActionConfig
		button.setTitle("Reload disk list", for: .normal)
		button.addTarget(self, action: #selector(reloadDisksButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var importDiskButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .secondaryActionConfig
		button.setTitle("Import disk file", for: .normal)
		button.addTarget(self, action: #selector(importDiskButtonPushed), for: .touchUpInside)
		return button
	}()

	private let didTapCreateDiskButton: (() -> Void)
	private let didTapReloadDisksButton: (() -> Void)
	private let didTapImportDiskButton: (() -> Void)

	init(
		hasDskFile: Bool,
		didTapCreateDiskButton: @escaping (() -> Void),
		didTapReloadDisksButton: @escaping (() -> Void),
		didTapImportDiskButton: @escaping (() -> Void)
	) {
		self.didTapCreateDiskButton = didTapCreateDiskButton
		self.didTapReloadDisksButton = didTapReloadDisksButton
		self.didTapImportDiskButton = didTapImportDiskButton

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(informationLabel)
		buttonStackView.addArrangedSubview(createDiskButton)
		buttonStackView.addArrangedSubview(reloadDisksButton)
		buttonStackView.addArrangedSubview(importDiskButton)
		contentView.addSubview(buttonStackView)

		NSLayoutConstraint.activate([
			informationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			informationLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
			informationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

			reloadDisksButton.heightAnchor.constraint(equalToConstant: 44),
			createDiskButton.heightAnchor.constraint(equalToConstant: 44),
			importDiskButton.heightAnchor.constraint(equalToConstant: 44),

			buttonStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			buttonStackView.topAnchor.constraint(equalTo: informationLabel.bottomAnchor, constant: 12),
			buttonStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			buttonStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
		])

		setupForHasDskFile(hasDskFile, animated: false)
	}

	required init?(coder: NSCoder) { fatalError() }

	func setupForHasDskFile(_ hasDskFile: Bool, animated: Bool) {
		let block: (() -> Void)
		if hasDskFile {
			block = { [weak self] in
				guard let self else { return }
				buttonStackView.removeArrangedSubview(self.reloadDisksButton)
				buttonStackView.insertArrangedSubview(self.reloadDisksButton, at: 0)

				createDiskButton.configuration = .secondaryActionConfig
				createDiskButton.setTitle(self.createDiskButton.title(for: .normal), for: .normal)
			}
		} else {
			block = { [weak self] in
				guard let self else { return }
				buttonStackView.removeArrangedSubview(self.createDiskButton)
				buttonStackView.insertArrangedSubview(self.createDiskButton, at: 0)

				createDiskButton.configuration = .primaryActionConfig
				createDiskButton.setTitle(self.createDiskButton.title(for: .normal), for: .normal)
			}
		}


		if animated {
			UIView.animate(withDuration: 0.2) {
				block()

				self.buttonStackView.layoutIfNeeded()
			}
		} else {
			block()
		}
	}

	@objc
	private func reloadDisksButtonPushed() {
		didTapReloadDisksButton()
	}

	@objc
	private func createDiskButtonPushed() {
		didTapCreateDiskButton()
	}

	@objc
	private func importDiskButtonPushed() {
		didTapImportDiskButton()
	}
}

class PreferencesGeneralRamStepperCell: UITableViewCell {
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
		label.textColor = .darkGray
		label.text = "Changes in RAM value requires PocketShaver to restart"
		return label
	}()

	private let didChangeStepperValue: ((PreferencesGeneralRamSetting) -> Void)

	init(
		initialRamSettting: PreferencesGeneralRamSetting,
		didChangeStepperValue: @escaping ((PreferencesGeneralRamSetting) -> Void)
	) {
		self.didChangeStepperValue = didChangeStepperValue

		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(stepper)
		contentView.addSubview(stepperLabel)
		contentView.addSubview(informationLabel)

		NSLayoutConstraint.activate([
			stepper.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			stepper.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

			stepperLabel.centerYAnchor.constraint(equalTo: stepper.centerYAnchor),
			stepperLabel.leadingAnchor.constraint(equalTo: stepper.trailingAnchor, constant: 16),

			informationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			informationLabel.topAnchor.constraint(equalTo: stepper.bottomAnchor, constant: 8),
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

class PreferencesGeneralIPadMouseCell: UITableViewCell {
	enum Selection: Int, CaseIterable {
		case touch
		case mouse

		var label: String {
			switch self {
			case .touch: "Touch"
			case .mouse: "Mouse"
			}
		}
	}

	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in Selection.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((Bool) -> Void)

	init(
		initialIPadMouseSetting: Bool,
		didChangeSelection: @escaping ((Bool) -> Void)
	) {
		self.didChangeSelection = didChangeSelection

		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(segmentedControl)

		NSLayoutConstraint.activate([
			segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),
			segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
			segmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 350)
		])

		segmentedControl.selectedSegmentIndex = initialIPadMouseSetting ? 1 : 0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let isOn = segmentedControl.selectedSegmentIndex == Selection.mouse.rawValue
		didChangeSelection(isOn)
	}
}

class PreferencesGeneralSettingCell: UITableViewCell {
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

		titleLabel.text = title
		enabledSwitch.isOn = isOn

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

class PreferencesGeneralAudioFooterCell: UITableViewCell {
	private lazy var informationLabel: LinkLabel = {
		let text = "Sound from other apps is lowered if audio is enabled during emulation.\nHaving trouble getting audio to work? Read the setup guide."
		let range = text.range(of: "setup guide")!
		let label = LinkLabel(
			text: text,
			linkRange: range,
			callback: callback
		)
		label.translatesAutoresizingMaskIntoConstraints = false

		return label
	}()

	private let callback: (() -> Void)

	init(
		callback: @escaping (() -> Void)
	) {
		self.callback = callback

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(informationLabel)

		NSLayoutConstraint.activate([
			informationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			informationLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			informationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			informationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1)
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesGeneralHintsFooterCell: UITableViewCell {
	private lazy var informationLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = .darkGray
		label.text = "Gamepad layout names are shown even when hints are turned off."
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
	}

	required init?(coder: NSCoder) { fatalError() }
}
