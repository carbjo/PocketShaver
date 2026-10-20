//
//  SelectionWheelButtonCreationCells.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-10-10.
//

import UIKit

class SelectionWheelButtonCreationButtonNameCell: UITableViewCell {
	private lazy var buttonNameTextFieldContainer: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.borderWidth = 1
		view.layer.borderColor = UIColor.darkGray.cgColor
		view.layer.cornerRadius = 8
		view.backgroundColor = Colors.primaryBackground
		return view
	}()

	private(set) lazy var buttonNameTextField: UITextField = {
		let textField = UITextField.withoutConstraints()
		textField.returnKeyType = .done
		textField.placeholder = "Button name (optional)"
		textField.autocapitalizationType = .sentences
		textField.autocorrectionType = .no
		textField.delegate = self
		return textField
	}()

	fileprivate let textDidChange: ((String) -> Void)

	init(
		initialName: String,
		textDidChange: @escaping ((String) -> Void)
	) {
		self.textDidChange = textDidChange

		super.init(style: .default, reuseIdentifier: nil)

		buttonNameTextField.text = initialName

		backgroundColor = .clear

		buttonNameTextFieldContainer.addSubview(buttonNameTextField)
		contentView.addSubview(buttonNameTextFieldContainer)

		NSLayoutConstraint.activate([
			buttonNameTextField.leadingAnchor.constraint(equalTo: buttonNameTextFieldContainer.leadingAnchor, constant: 8),
			buttonNameTextField.centerYAnchor.constraint(equalTo: buttonNameTextFieldContainer.centerYAnchor),
			buttonNameTextField.trailingAnchor.constraint(equalTo: buttonNameTextFieldContainer.trailingAnchor, constant: -8),

			buttonNameTextFieldContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			buttonNameTextFieldContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			buttonNameTextFieldContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			buttonNameTextFieldContainer.heightAnchor.constraint(equalToConstant: 28),
		])

		hideSeparator()
	}

	required init?(coder: NSCoder) { fatalError() }
}

extension SelectionWheelButtonCreationButtonNameCell: UITextFieldDelegate {
	func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
		if string == "\n" {
			textField.resignFirstResponder()
			return false
		}

		var text = textField.text ?? ""
		if let range = Range(range, in: text) {
			text.replaceSubrange(range, with: string)
		}

		textDidChange(text)

		return true
	}
}

class SelectionWheelButtonCreationAssignmentCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.primaryText
		return label
	}()

	init(
		title: String
	) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = .clear

		titleLabel.text = title

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class SelectionWheelButtonCreationAddAssignmentCell: UITableViewCell {
	private let titleLabel: LinkLabel

	init(
		initiallyVisible: Bool
	) {
		titleLabel = .init(
			text: "<img/> Add assignment",
			config: .init(
				images: [
					ImageResource.plusCircleFill.asSymbolImage().withTintColor(Colors.okColor)
				]
			)
		)

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = .clear

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
		])

		hideSeparator()

		if !initiallyVisible {
			contentView.alpha = 0
		}
	}

	required init?(coder: NSCoder) { fatalError() }
}
