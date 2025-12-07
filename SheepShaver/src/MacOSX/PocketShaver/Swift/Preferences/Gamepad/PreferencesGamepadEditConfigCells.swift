//
//  PreferencesGamepadEditConfigCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-13.
//

import UIKit

class PreferencesGamepadEditConfigNameCell: UITableViewCell {
	private lazy var textFieldContainer: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.borderWidth = 1
		view.layer.borderColor = UIColor.darkGray.cgColor
		view.layer.cornerRadius = 8
		return view
	}()

	private(set) lazy var textField: UITextField = {
		let textField = UITextField.withoutConstraints()
		textField.returnKeyType = .done
		return textField
	}()

	private lazy var overlayView: UIView = {
		UIView.withoutConstraints()
	}()

	init(
		name: String,
		delegate: UITextFieldDelegate
	) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = .clear

		textField.text = name
		textField.delegate = delegate

		textFieldContainer.addSubview(textField)
		contentView.addSubview(textFieldContainer)
		contentView.addSubview(overlayView)

		NSLayoutConstraint.activate([
			textField.leadingAnchor.constraint(equalTo: textFieldContainer.leadingAnchor, constant: 8),
			textField.centerYAnchor.constraint(equalTo: textFieldContainer.centerYAnchor),
			textField.trailingAnchor.constraint(equalTo: textFieldContainer.trailingAnchor, constant: -8),

			textFieldContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			textFieldContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			textFieldContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			textFieldContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),
			textFieldContainer.heightAnchor.constraint(equalToConstant: 44),

			overlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			overlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
			overlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			overlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			])
	}

	required init?(coder: NSCoder) { fatalError() }

	func startEditing() {
		textField.becomeFirstResponder()
	}
}

class PreferencesGamepadEditConfigOptionCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		return label
	}()

	private lazy var checkmarkImageView = {
		let imageView = UIImageView.withoutConstraints()
		imageView.image = UIImage(resource: .checkmark)
		return imageView
	}()

	let visibilitySetting: GamepadVisibilitySetting

	init(
		visibilitySetting: GamepadVisibilitySetting,
		isChecked: Bool
	) {
		self.visibilitySetting = visibilitySetting

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = .clear

		contentView.addSubview(titleLabel)
		contentView.addSubview(checkmarkImageView)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

			checkmarkImageView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
			checkmarkImageView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
			checkmarkImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
		])

		titleLabel.text = visibilitySetting.label
		checkmarkImageView.isHidden = !isChecked
	}

	required init?(coder: NSCoder) { fatalError() }

	func config(isChecked: Bool) {
		checkmarkImageView.isHidden = !isChecked
	}
}
