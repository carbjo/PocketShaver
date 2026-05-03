//
//  PreferencesGeneralCreateDiskDialogueFactory.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-03-22.
//

import UIKit

class PreferencesGeneralCreateDiskDialogueFactory: NSObject {
	struct CreateDiskSpecification {
		let name: String
		let size: Int
	}

	private enum FieldIndex: Int {
		case name
		case size
	}

	private var namePhantomLabel: UILabel?
	private var nameSuffixLabel: UILabel?
	private var sizePhantomLabel: UILabel?
	private var sizeUnitLabel: UILabel?

	func create(
		_ createCallback: @escaping ((CreateDiskSpecification) -> Void)
	) -> UIAlertController {
		let alertVC = UIAlertController(
			title: "Create new disk",
			message: "Choose name and size",
			preferredStyle: .alert
		)
		alertVC.addTextField { [weak self] textField in
			guard let self else { return }

			textField.tag = FieldIndex.name.rawValue
			textField.placeholder = "DiskName.dsk"
			textField.autocapitalizationType = .sentences

			let phantomLabel = UILabel.withoutConstraints()
			phantomLabel.font = textField.font
			phantomLabel.isHidden = true

			let suffixLabel = UILabel.withoutConstraints()
			suffixLabel.font = textField.font
			suffixLabel.text = ".dsk"
			suffixLabel.isHidden = true

			textField.addSubview(phantomLabel)
			textField.addSubview(suffixLabel)

			NSLayoutConstraint.activate([
				phantomLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
				phantomLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor),

				suffixLabel.leadingAnchor.constraint(equalTo: phantomLabel.trailingAnchor),
				suffixLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor)
			])

			textField.delegate = self

			self.namePhantomLabel = phantomLabel
			self.nameSuffixLabel = suffixLabel
		}

		alertVC.addTextField { [weak self] textField in
			guard let self else { return }

			textField.tag = FieldIndex.size.rawValue
			textField.placeholder = "0"
			textField.keyboardType = .numberPad

			let phantomLabel = UILabel.withoutConstraints()
			phantomLabel.text = "0"
			phantomLabel.font = textField.font
			phantomLabel.isHidden = true

			let unitLabel = UILabel.withoutConstraints()
			unitLabel.text = "MB"
			unitLabel.font = textField.font
			unitLabel.textColor = .gray

			textField.addSubview(phantomLabel)
			textField.addSubview(unitLabel)

			NSLayoutConstraint.activate([
				phantomLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
				phantomLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor),

				unitLabel.leadingAnchor.constraint(equalTo: phantomLabel.trailingAnchor, constant: 4),
				unitLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor)
			])

			textField.delegate = self

			self.sizePhantomLabel = phantomLabel
			self.sizeUnitLabel = unitLabel
		}

		alertVC.addAction(.init(title: "Cancel", style: .cancel, handler: { [weak self] _ in
			guard let self else { return }

			namePhantomLabel = nil
			nameSuffixLabel = nil
		}))
		alertVC.addAction(.init(title: "Create", style: .default, handler: { [weak self] action in
			guard let self else { return }

			namePhantomLabel = nil
			nameSuffixLabel = nil

			let name = alertVC.textFields?[0].text ?? ""
			let sizeString = alertVC.textFields?[1].text ?? ""
			let size = Int(sizeString) ?? 0
			let specification = CreateDiskSpecification(name: name, size: size)

			createCallback(specification)
		}))

		return alertVC
	}
}

extension PreferencesGeneralCreateDiskDialogueFactory: UITextFieldDelegate {
	func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
		let currentString = (textField.text ?? "") as NSString
		let newString = currentString.replacingCharacters(in: range, with: string)

		switch FieldIndex(rawValue: textField.tag)! {
		case .name:
			namePhantomLabel?.text = newString
			nameSuffixLabel?.isHidden = newString.isEmpty
		case .size:
			sizePhantomLabel?.text = newString.isEmpty ? "0" : newString
		}

		return true
	}
}
