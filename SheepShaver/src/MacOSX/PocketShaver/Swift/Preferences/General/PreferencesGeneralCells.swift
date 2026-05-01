//
//  PreferencesGeneralCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit

class PreferencesGeneralWelcomeCell: UITableViewCell {
	private lazy var cardView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = Colors.informationCardBackground
		return view
	}()

	private lazy var welcomeStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .horizontal
		stackView.spacing = 24
		stackView.distribution = .fill
		stackView.alignment = .center
		return stackView
	}()

	private lazy var logoContainerView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.clipsToBounds = true

		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: 70),
			view.heightAnchor.constraint(equalToConstant: 70)
		])

		return view
	}()

	private lazy var logoImageView: UIImageView = {
		let imageView = UIImageView.withoutConstraints()
		imageView.image = UIImage(resource: .logo)
		imageView.tintColor = Colors.secondaryText

		NSLayoutConstraint.activate([
			imageView.widthAnchor.constraint(equalToConstant: 70),
			imageView.heightAnchor.constraint(equalToConstant: 70)
		])

		return imageView
	}()

	private let welcomeLabel: LinkLabel
	private let informationLabel: LinkLabel

	init() {
		welcomeLabel = .init(
			text: "Welcome!",
			config: .init(),
			font: .systemFont(ofSize: 60),
			callback: nil
		)

		informationLabel = .init(
			text: "This window can be accessed during emulation by pressing option + F6.",
			config: .init(),
			font: .systemFont(ofSize: 14),
			callback: nil
		)

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		hideSeparator()

		cardView.setContentHuggingPriority(.required, for: .horizontal)

		logoContainerView.addSubview(logoImageView)
		cardView.addSubview(welcomeStackView)
		welcomeStackView.addArrangedSubview(logoContainerView)
		welcomeStackView.addArrangedSubview(welcomeLabel)
		cardView.addSubview(informationLabel)
		contentView.addSubview(cardView)

		NSLayoutConstraint.activate([
			cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
			cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

			cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

			welcomeStackView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 32),
			welcomeStackView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),

			logoImageView.centerXAnchor.constraint(equalTo: logoContainerView.centerXAnchor),
			logoImageView.centerYAnchor.constraint(equalTo: logoContainerView.centerYAnchor),

			informationLabel.topAnchor.constraint(equalTo: welcomeStackView.bottomAnchor, constant: 24),
			informationLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 50),
			informationLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -32).withPriority(.required - 1),
			informationLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -50),

			cardView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesGeneralSetupInstructionsCell: UITableViewCell {
	private lazy var containerView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = Colors.informationCardBackground
		return view
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText

		var string = "Read initial setup instructions if you plan to install Classic Mac OS from scratch. Contains crucial tip on how to <b>not get stuck in installation progress</b> and <b>get audio working</b>, after intallation.\n\nThe instructions can still be accessed from Advanced tab, after dismissal."

		label.attributedText = string
			.withTagsReplaced(by: .init(boldAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.primaryText)))

		return label
	}()

	private lazy var closeButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(.init(resource: .xmarkCircleFill), for: .normal)
		button.tintColor = Colors.secondaryText
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

		backgroundColor = Colors.primaryBackground

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

			containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8).withPriority(.required - 1),
			containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8).withPriority(.defaultHigh),
			containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),
			containerView.widthAnchor.constraint(lessThanOrEqualToConstant: 500),

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
	private class BootstrapCompletedView: UIView {
		private lazy var stackView: UIStackView = {
			let stackView = UIStackView.withoutConstraints()
			stackView.axis = .horizontal
			stackView.spacing = 16
			stackView.distribution = .fill
			stackView.alignment = .center
			return stackView
		}()

		private lazy var checkmarkIconImageView: UIImageView = {
			let imageView = UIImageView.withoutConstraints()
			imageView.image = UIImage(resource: .checkmarkCircleFill)
			imageView.tintColor = Colors.okColor
			imageView.contentMode = .scaleAspectFit

			NSLayoutConstraint.activate([
				imageView.widthAnchor.constraint(equalToConstant: 44),
				imageView.heightAnchor.constraint(equalToConstant: 44)
			])

			return imageView
		}()

		private lazy var titleLabel: UILabel = {
			let label = UILabel.withoutConstraints()
			label.numberOfLines = 0
			label.font = .systemFont(ofSize: 14)
			label.textColor = Colors.secondaryText
			label.text = "Congratulations, PocketShaver is successfully bootstrapped!\n\nYou can now install and run Mac OS up to version 9.0.4. For network support, Mac OS 9.0 - 9.0.4 is required."
			return label
		}()

		init() {
			super.init(frame: .zero)

			translatesAutoresizingMaskIntoConstraints = false

			stackView.addArrangedSubview(checkmarkIconImageView)
			stackView.addArrangedSubview(titleLabel)

			addSubview(stackView)

			NSLayoutConstraint.activate([
				stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
				stackView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
				stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
				stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
			])
		}

		required init?(coder: NSCoder) { fatalError() }
	}

	private lazy var containerView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = Colors.informationCardBackground
		return view
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText
		label.text = "Tap button below to select a Mac OS install disc file and bootstrap PocketShaver.\n\nBootstrapping is not the same as installing Mac OS onto a disk file."
		return label
	}()

	private lazy var stackView: UIStackView = {
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
		button.setTitle("Bootstrap compatibility list", for: .normal)
		button.addTarget(self, action: #selector(displayCompatibilityListButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var doneButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .secondaryActionConfig
		button.setTitle("Ok", for: .normal)
		button.isHidden = true
		button.addTarget(self, action: #selector(doneButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var bootstrapCompletedView: BootstrapCompletedView = {
		let view = BootstrapCompletedView()
		view.isHidden = true
		return view
	}()

	private let didTapSelectInstallDiskButton: (() -> Void)
	private let didTapCompatibilityListButton: (() -> Void)
	private let didTapDoneButton: (() -> Void)

	init(
		didTapSelectInstallDiskButton: @escaping (() -> Void),
		didTapCompatibilityListButton: @escaping (() -> Void),
		didTapDoneButton: @escaping (() -> Void)

	) {
		self.didTapSelectInstallDiskButton = didTapSelectInstallDiskButton
		self.didTapCompatibilityListButton = didTapCompatibilityListButton
		self.didTapDoneButton = didTapDoneButton

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(containerView)

		containerView.addSubview(stackView)
		stackView.addArrangedSubview(titleLabel)
		stackView.addArrangedSubview(bootstrapCompletedView)
		stackView.addArrangedSubview(selectInstallDiskFileButton)
		stackView.addArrangedSubview(displayCompatibilityListButton)
		stackView.addArrangedSubview(doneButton)


		NSLayoutConstraint.activate([
			stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
			stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
			stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
			stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),

			selectInstallDiskFileButton.heightAnchor.constraint(equalToConstant: 44),
			displayCompatibilityListButton.heightAnchor.constraint(equalToConstant: 44),
			doneButton.heightAnchor.constraint(equalToConstant: 44),

			containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8).withPriority(.defaultHigh),
			containerView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -8) ,
			containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),
			containerView.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func displayBootstrapCompleted() {
		titleLabel.isHidden = true
		selectInstallDiskFileButton.isHidden = true
		displayCompatibilityListButton.isHidden = true

		bootstrapCompletedView.isHidden = false
		doneButton.isHidden = false
	}

	@objc
	private func selectInstallDiskFileButtonPushed() {
		didTapSelectInstallDiskButton()
	}

	@objc
	private func displayCompatibilityListButtonPushed() {
		didTapCompatibilityListButton()
	}

	@objc
	private func doneButtonPushed() {
		didTapDoneButton()
	}
}

class PreferencesGeneralErrorCell: UITableViewCell {
	private lazy var errorLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .boldSystemFont(ofSize: 14)
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.textColor = Colors.notOkColor
		return label
	}()

	init(title: String) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

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

class PreferencesGeneralDiskActionBarCell: UITableViewCell {
	private lazy var openShareFolderButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.tintColor = Colors.secondaryText
		button.setImage(Assets.folder, for: .normal)

		NSLayoutConstraint.activate([
			button.widthAnchor.constraint(equalToConstant: 44),
			button.heightAnchor.constraint(equalToConstant: 44)
		])

		return button
	}()

	private lazy var reloadButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.tintColor = Colors.secondaryText
		button.setImage(.init(resource: .arrowTriangleheadCounterclockwiseRotate90), for: .normal)

		NSLayoutConstraint.activate([
			button.widthAnchor.constraint(equalToConstant: 44),
			button.heightAnchor.constraint(equalToConstant: 44)
		])

		return button
	}()

	private lazy var addButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.tintColor = Colors.secondaryText
		button.setImage(Assets.plus, for: .normal)
		button.showsMenuAsPrimaryAction = true

		NSLayoutConstraint.activate([
			button.widthAnchor.constraint(equalToConstant: 44),
			button.heightAnchor.constraint(equalToConstant: 44)
		])

		return button
	}()

	init(
		didTapOpenShareFolderButton: @escaping (() -> Void),
		didTapReloadButton: @escaping (() -> Void),
		didTapCreateAction: @escaping (() -> Void),
		didTapImportAction: @escaping (() -> Void)
	) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		let openShareFolderAction = UIAction { _ in
			didTapOpenShareFolderButton()
		}
		openShareFolderButton.addAction(openShareFolderAction, for: .touchUpInside)

		let reloadAction = UIAction { [weak self] _ in
			guard let self else { return }
			didTapReloadButton()

			rotateReloadButton()
		}
		reloadButton.addAction(reloadAction, for: .touchUpInside)

		let createAction = UIAction(
			title: "Create empty disk",
			image: Assets.plus
		) { _ in
			didTapCreateAction()
		}
		let importAction = UIAction(
			title: "Import disk file",
			image: Assets.squareAndArrowDown
		) { _ in
			didTapImportAction()
		}
		let addMenu = UIMenu(title: "", children: [createAction, importAction])
		addButton.menu = addMenu

		contentView.addSubview(reloadButton)
		contentView.addSubview(addButton)

		if UIDevice.deviceType == .mac {
			contentView.addSubview(openShareFolderButton)

			NSLayoutConstraint.activate([
				openShareFolderButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
				reloadButton.leadingAnchor.constraint(equalTo: openShareFolderButton.trailingAnchor),
			])
		}

		NSLayoutConstraint.activate([
			reloadButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
			addButton.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor),
			addButton.topAnchor.constraint(equalTo: contentView.topAnchor),
			addButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			addButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor).withPriority(.required - 1)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	private func rotateReloadButton() {
		// Split in to parts to force it to make the rotation counter clockwise
		UIView.animate(withDuration: 0.10, delay: 0.0, options: .curveEaseIn, animations: {
			self.reloadButton.transform = self.reloadButton.transform.rotated(by: .pi * -4/5)
		}) { _ in
			UIView.animate(withDuration: 0.05, delay: 0.0, options: .curveLinear, animations: {
				self.reloadButton.transform = self.reloadButton.transform.rotated(by: .pi * -2/5)
			}) {  _ in
				UIView.animate(withDuration: 0.10, delay: 0.0, options: .curveEaseOut, animations: {
					self.reloadButton.transform = self.reloadButton.transform.rotated(by: .pi * -4/5)
				})
			}
		}
	}
}

class PreferencesGeneralTagView: UIView, ImageDerivable {
	private lazy var label: UILabel = {
		let label = UILabel.withoutConstraints()
		label.textColor = Colors.primaryBackground
		label.font = label.font.withSize(9 * resolutionMultiplier)
		return label
	}()

	init() {
		super.init(frame: .zero)

		backgroundColor = Colors.primaryBackground

		translatesAutoresizingMaskIntoConstraints = false

		layer.cornerRadius = 4 * resolutionMultiplier

		addSubview(label)

		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4.5 * resolutionMultiplier),
			label.topAnchor.constraint(equalTo: topAnchor, constant: 2 * resolutionMultiplier),
			label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4.5 * resolutionMultiplier),
			label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2 * resolutionMultiplier),
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(text: String) -> Self {
		label.text = text
		backgroundColor = Colors.thinBackground
		layoutIfNeeded()

		return self
	}

	func configure(disk: Disk) -> Self {
		switch disk.type {
		case .disk:
			if disk.isBootable && disk.romVersion == nil {
				return configure(text: "Mac HD")
			} else {
				return configure(text: "Disk")
			}
		case .cd:
			if let installDiscString = disk.installDiscString {
				return configure(text: "\(installDiscString) CD")
			} else {
				return configure(text: "CD")
			}
		}
	}

	func configureAsNotCompatible() -> Self {
		label.text = "Not compatible"
		backgroundColor = Colors.thinWarningBackground
		layoutIfNeeded()

		return self
	}
}

class PreferencesGeneralDiskCell: UITableViewCell {
	private lazy var enabledIndicationView: UIView = {
		UIView.withoutConstraints()
	}()

	private var titleLabel: LinkLabel?

	private lazy var enabledSwitch: UISwitch = {
		let uiSwitch = UISwitch.withoutConstraints()
		uiSwitch.addTarget(self, action: #selector(enabledValueChanged), for: .valueChanged)
		return uiSwitch
	}()

	private var filename: String!
	private var didSetIsEnabled: ((String, Bool) -> Void)?


	override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
		super.init(style: .default, reuseIdentifier: Self.reuseIdentifier)

		backgroundColor = Colors.primaryBackground

		contentView.addSubview(enabledIndicationView)
		contentView.addSubview(enabledSwitch)

		NSLayoutConstraint.activate([
			enabledIndicationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			enabledIndicationView.topAnchor.constraint(equalTo: contentView.topAnchor),
			enabledIndicationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			enabledIndicationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),


			enabledSwitch.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
			enabledSwitch.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
			enabledSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	override func prepareForReuse() {
		super.prepareForReuse()

		if let titleLabel {
			titleLabel.removeFromSuperview()
			self.titleLabel = nil
		}
	}

	func configure(
		disk: Disk,
		didSetIsEnabled: @escaping ((String, Bool) -> Void),
		didSetDiskType: @escaping ((String, DiskType) -> Void)
	) {
		self.filename = disk.filename
		self.didSetIsEnabled = didSetIsEnabled
		
		let diskTypeView = PreferencesGeneralTagView().configure(disk: disk)
		let diskTypeViewImage = diskTypeView.asImage()
		diskTypeView.alpha = 0.5
		let diskTypeViewHighligtedImage = diskTypeView.asImage()

		let diskNotCompatibleView = PreferencesGeneralTagView().configureAsNotCompatible()
		let diskNotCompatibleViewImage = diskNotCompatibleView.asImage()

		var diskTypeTags: String
		if disk.installDiscString != nil {
			diskTypeTags = " <img yOffset=-2/> " // Not clickable
			if disk.isNonCompatibleInstallDisc {
				diskTypeTags += "<img yOffset=-2/> "
			}
		} else {
			diskTypeTags = "<link> <img yOffset=-2/> </link>"
		}

		let titleLabel = LinkLabel(
			text: "\(disk.filename) \(diskTypeTags)",
			config: .init(
				images: [diskTypeViewImage, diskNotCompatibleViewImage],
				highlightedImages: [diskTypeViewHighligtedImage]
			),
			font: .systemFont(ofSize: 17),
			textColor: Colors.primaryText
		) {
			let newType: DiskType = disk.type == .disk ? .cd: .disk
			didSetDiskType(disk.filename, newType)
		}

		titleLabel.label.setContentHuggingPriority(.required, for: .horizontal)
		titleLabel.label.setContentCompressionResistancePriority(.required, for: .vertical)

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.centerYAnchor.constraint(equalTo: enabledSwitch.centerYAnchor),
			titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: enabledSwitch.leadingAnchor, constant: -16),
			titleLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
			titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8).withPriority(.defaultHigh),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8).withPriority(.defaultHigh),
			])

		self.titleLabel = titleLabel

		enabledSwitch.isOn = disk.isEnabled

		updateEnabledIndicationView()

		layoutIfNeeded()
	}

	private func updateEnabledIndicationView() {
		enabledIndicationView.backgroundColor = enabledSwitch.isOn ? Colors.selectedCell : Colors.primaryBackground
	}

	@objc private func enabledValueChanged() {
		updateEnabledIndicationView()

		didSetIsEnabled?(filename, enabledSwitch.isOn)
	}
}

class PreferencesGeneralGamepadOverlaysCell: UITableViewCell {
	private lazy var editButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setTitle("Edit", for: .normal)
		button.setTitleColor(Colors.primaryText, for: .normal)
		button.setTitleColor(Colors.highlightedText, for: .highlighted)
		button.titleLabel?.font = .boldSystemFont(ofSize: 17)
		button.addTarget(self, action: #selector(editButtonPushed), for: .touchUpInside)
		return button
	}()

	private let previewVC: PreferencesGamepadThumbnailsViewController

	private let didTapEditButton: (() -> Void)

	init(
		containerVC: UIViewController,
		gamepadConfigs: [GamepadConfig],
		didTapEditButton: @escaping (() -> Void)
	) {
		self.didTapEditButton = didTapEditButton

		previewVC = .init(gamepadConfigs: gamepadConfigs)

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		contentView.addSubview(previewVC.view)
		contentView.addSubview(editButton)

		previewVC.willMove(toParent: containerVC)
		containerVC.addChild(previewVC)
		previewVC.didMove(toParent: containerVC)

		NSLayoutConstraint.activate([
			previewVC.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			previewVC.view.topAnchor.constraint(equalTo: contentView.topAnchor),
			previewVC.view.trailingAnchor.constraint(equalTo: editButton.trailingAnchor).withPriority(.required - 1),
			previewVC.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor).withPriority(.required - 1),

			editButton.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
			editButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
			editButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			editButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()

		previewVC.setRightInset(editButton.frame.width + 12)
	}

	deinit {
		previewVC.removeFromParent()
	}

	@objc
	private func editButtonPushed() {
		didTapEditButton()
	}
}

class PreferencesGeneralTwoFingerSteeringDetailsCell: UITableViewCell {
	private lazy var editButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setTitle("Edit", for: .normal)
		button.setTitleColor(Colors.primaryText, for: .normal)
		button.setTitleColor(Colors.highlightedText, for: .highlighted)
		button.titleLabel?.font = .boldSystemFont(ofSize: 17)
		button.addTarget(self, action: #selector(editButtonPushed), for: .touchUpInside)
		return button
	}()

	private var titleLabel: LinkLabel?

	private let didTapEditButton: (() -> Void)

	init(
		twoFingerSteeringSetting: TwoFingerSteeringSetting,
		didTapEditButton: @escaping (() -> Void)
	) {
		self.didTapEditButton = didTapEditButton

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		contentView.addSubview(editButton)

		NSLayoutConstraint.activate([
			editButton.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
			editButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
			editButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
		])

		configure(
			twoFingerSteeringSetting: twoFingerSteeringSetting
		)
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(
		twoFingerSteeringSetting: TwoFingerSteeringSetting
	) {
		let text = """
• Second finger click <img/>
• Second finger swipe <img/>
• Boot in hover mode <img/>
"""

		let enabledImage = ImageResource.checkmarkCircleFill.asSymbolImage().withTintColor(Colors.okColor)
		let disabledImage = ImageResource.xmarkCircleFill.asSymbolImage().withTintColor(Colors.highlightedText)

		let images: [UIImage]
		switch twoFingerSteeringSetting {
		case .click:
			images = [enabledImage, disabledImage, disabledImage]
		case .clickPlusSwipe:
			images = [enabledImage, enabledImage, disabledImage]
		case .clickPlusSwipePlusBootInHoverMode:
			images = [enabledImage, enabledImage, enabledImage]
		default:
			fatalError()
		}

		let titleLabel = LinkLabel(
			text: text,
			config: .init(
				images: images,
				highlightedImages: []
			),
			font: .systemFont(ofSize: 14),
			textColor: Colors.secondaryText
		)

		titleLabel.label.setContentHuggingPriority(.required, for: .horizontal)
		titleLabel.label.setContentCompressionResistancePriority(.required, for: .vertical)

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
			titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -16),
			titleLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
			titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16).withPriority(.defaultHigh),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.defaultHigh),
			])

		self.titleLabel = titleLabel

		layoutIfNeeded()
	}

	@objc
	private func editButtonPushed() {
		didTapEditButton()
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

		backgroundColor = Colors.primaryBackground

		hideSeparator()

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

class PreferencesGeneralRightClickCell: UITableViewCell {
	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in RightClickSetting.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((RightClickSetting) -> Void)

	init(
		initialRightClickSetting: RightClickSetting,
		didChangeSelection: @escaping ((RightClickSetting) -> Void)
	) {
		self.didChangeSelection = didChangeSelection

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		hideSeparator()

		contentView.addSubview(segmentedControl)

		NSLayoutConstraint.activate([
			segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),
			segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			segmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 350)
		])

		segmentedControl.selectedSegmentIndex = RightClickSetting.allCases.enumerated().first(where: { initialRightClickSetting == $1 })!.0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let index = segmentedControl.selectedSegmentIndex
		let setting = RightClickSetting.allCases.enumerated().first(where: { index == $0.0 })!.1

		didChangeSelection(setting)
	}
}

class PreferencesGeneralKeyboardAutoOffsetCell: UITableViewCell {
	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in KeyboardAutoOffsetSetting.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((KeyboardAutoOffsetSetting) -> Void)

	init(
		initialKeyboardAutoOffsetSetting: KeyboardAutoOffsetSetting,
		didChangeSelection: @escaping ((KeyboardAutoOffsetSetting) -> Void)
	) {
		self.didChangeSelection = didChangeSelection

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		hideSeparator()

		contentView.addSubview(segmentedControl)

		NSLayoutConstraint.activate([
			segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),
			segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			segmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 350)
		])

		segmentedControl.selectedSegmentIndex = KeyboardAutoOffsetSetting.allCases.enumerated().first(where: { initialKeyboardAutoOffsetSetting == $1 })!.0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let index = segmentedControl.selectedSegmentIndex
		let setting = KeyboardAutoOffsetSetting.allCases.enumerated().first(where: { index == $0.0 })!.1

		didChangeSelection(setting)
	}
}

private extension RightClickSetting {
	var label: String {
		switch self {
		case .control:
			return "control + click"
		case .command:
			return "command + click"
		}
	}
}

private extension KeyboardAutoOffsetSetting {
	var label: String {
		switch self {
		case .top:
			return "Top"
		case .middle:
			return "Middle"
		case .bottom:
			return "Bottom"
		}
	}
}
