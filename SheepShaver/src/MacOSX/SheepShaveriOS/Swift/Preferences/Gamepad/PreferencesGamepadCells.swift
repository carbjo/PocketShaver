//
//  PreferencesGamepadCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-13.
//

import UIKit

class PreferencesGamepadInformationCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.attributedText = "Here you can edit, rearrange and delete your gamepad layouts.\n\n• Use three finger swipe down gesture during emulation to access gamepad mode.\n\n• To create new layouts, edit an <b>Example layout</b> in gamepad mode."
			.withBoldTagsReplacedWith(font: .boldSystemFont(ofSize: 14), color: Colors.primaryText)
		return label
	}()

	init() {
		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor).withPriority(.required - 1)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		// Remove separators
		for view in subviews where view != contentView {
			view.removeFromSuperview()
		}
	}
}

class PreferencesGamepadConfigHeaderCell: UITableViewHeaderFooterView {

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .systemFont(ofSize: 15, weight: .semibold)
		label.textColor = Colors.sectionHeaderText
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.text = "Gamepad layouts"
		return label
	}()

	private lazy var editButton: UIButton = {
		let button = UIButton(type: .system)
		button.translatesAutoresizingMaskIntoConstraints = false
		button.setTitle("Edit", for: .normal)
		button.addTarget(self, action: #selector(editButtonPushed), for: .touchUpInside)
		return button
	}()

	private let didTapEditButton: (() -> Void)
	private var isEditing = false

	init(
		shouldShowEdit: Bool,
		didTapEditButton: @escaping (() -> Void)
	) {
		self.didTapEditButton = didTapEditButton

		super.init(reuseIdentifier: nil)

		editButton.setContentHuggingPriority(.required, for: .horizontal)
		editButton.setContentHuggingPriority(.required, for: .vertical)

		contentView.addSubview(titleLabel)
		contentView.addSubview(editButton)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8).withPriority(.required - 1),

			editButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 16),
			editButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
			editButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			editButton.heightAnchor.constraint(equalToConstant: 44)
		])

		config(shouldShowEdit: shouldShowEdit)
	}

	required init?(coder: NSCoder) { fatalError() }

	func config(shouldShowEdit: Bool) {
		editButton.isHidden = !shouldShowEdit
	}

	@objc private func editButtonPushed() {
		isEditing = !isEditing
		editButton.setTitle(isEditing ? "Done" : "Edit", for: .normal)
		didTapEditButton()
	}
}

class PreferencesGamepadConfigCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private lazy var settingsButton: UIButton = {
		let button = UIButton.withoutConstraints()

		let backgroundView = UIView.withoutConstraints()
		backgroundView.backgroundColor = Colors.secondaryButton
		backgroundView.layer.cornerRadius = 8
		backgroundView.isUserInteractionEnabled = false

		let imageView = UIImageView.withoutConstraints()
		imageView.image = UIImage(resource: .gearshape)

		backgroundView.addSubview(imageView)
		button.addSubview(backgroundView)
		button.tintColor = .white

		NSLayoutConstraint.activate([
			imageView.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
			imageView.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),

			backgroundView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
			backgroundView.centerYAnchor.constraint(equalTo: button.centerYAnchor),

			backgroundView.widthAnchor.constraint(equalToConstant: 30),
			backgroundView.heightAnchor.constraint(equalToConstant: 30)
		])

		button.addTarget(self, action: #selector(settingsButtonPushed), for: .touchUpInside)

		return button
	}()

	private let didTapSettingsButton: (() -> Void)

	init(
		gamepadConfig: GamepadConfig,
		didTapSettingsButton: @escaping (() -> Void)
	) {
		self.didTapSettingsButton = didTapSettingsButton

		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(titleLabel)
		contentView.addSubview(settingsButton)

		titleLabel.setContentHuggingPriority(.required, for: .vertical)
		settingsButton.setContentHuggingPriority(.defaultLow, for: .vertical)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),

			settingsButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
			settingsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
			settingsButton.topAnchor.constraint(equalTo: contentView.topAnchor),
			settingsButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			settingsButton.widthAnchor.constraint(equalToConstant: 44)
		])

		titleLabel.text = gamepadConfig.name
	}

	required init?(coder: NSCoder) { fatalError() }

	override func setEditing(_ editing: Bool, animated: Bool) {
		super.setEditing(editing, animated: animated)

		if editing {
			UIView.animate(withDuration: 0.2) {
				self.settingsButton.alpha = 0
			} completion: { _ in
				self.settingsButton.isHidden = true
			}
		} else {
			settingsButton.isHidden = false

			UIView.animate(withDuration: 0.2) {
				self.settingsButton.alpha = 1
			}
		}
	}

	@objc private func settingsButtonPushed() {
		didTapSettingsButton()
	}
}

class PreferencesGamepadConfigsEmptyStateCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .boldSystemFont(ofSize: 18)
		label.text = "No gamepad layouts saved"
		label.textAlignment = .center
		return label
	}()

	init() {
		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

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
