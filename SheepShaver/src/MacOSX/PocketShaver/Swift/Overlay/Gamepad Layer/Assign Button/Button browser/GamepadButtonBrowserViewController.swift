//
//  GamepadButtonBrowserViewController.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-08-03.
//

import UIKit

class GamepadButtonBrowserViewController: UIViewController {
	private lazy var searchTextFieldContainer: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.borderWidth = 1
		view.layer.borderColor = UIColor.darkGray.cgColor
		view.layer.cornerRadius = 8
		view.backgroundColor = Colors.primaryBackground
		return view
	}()

	private(set) lazy var searchTextField: UITextField = {
		let textField = UITextField.withoutConstraints()
		textField.returnKeyType = .done
		textField.placeholder = "Search"
		textField.autocapitalizationType = .none
		textField.autocorrectionType = .no
		textField.delegate = self
		return textField
	}()

	private lazy var searchTextFieldAccessoryView: GamepadAssignKeyboardAccessoryView = {
		let view = GamepadAssignKeyboardAccessoryView()
		view.configure(didTapDismissKeyboardButton: { [weak self] in
			self?.searchTextField.resignFirstResponder()
		})
		return view
	}()

	private lazy var tableView: UITableView = {
		let tableView = UITableView.withoutConstraints()
		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 50
		tableView.backgroundColor = .clear
		GamepadButtonBrowserEntryCell.register(in: tableView)
		return tableView
	}()

	private let model: GamepadButtonBrowserModel
	private let reportKeyboardHeightCallback: ((CGFloat) -> Void)
	private let keysJoystickCreationRequest: (() -> Void)
	private let dismissRequestCallback: ((GamepadAssignResult) -> Void)

	private let sizeMode: GamepadAssignButtonViewController.SizeMode

	init(
		for gamepadButtonSize: GamepadButtonSize,
		reportKeyboardHeightCallback: @escaping ((CGFloat) -> Void),
		keysJoystickCreationRequest: @escaping (() -> Void),
		dismissRequestCallback: @escaping ((GamepadAssignResult) -> Void)
	)
	{
		self.model = .init(gamepadButtonSize: gamepadButtonSize)
		self.reportKeyboardHeightCallback = reportKeyboardHeightCallback
		self.keysJoystickCreationRequest = keysJoystickCreationRequest
		self.dismissRequestCallback = dismissRequestCallback

		if UIScreen.isSESize,
		   !UIScreen.isPortraitMode {
			sizeMode = .tiny
		} else if !UIDevice.isIPadIdiom,
				  !UIScreen.isPortraitMode {
			sizeMode = .small
		} else {
			sizeMode = .normal
		}

		super.init(nibName: nil, bundle: nil)

		if !UIDevice.isIPadIdiom {
			searchTextField.inputAccessoryView = searchTextFieldAccessoryView
		}
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		view.translatesAutoresizingMaskIntoConstraints = false

		searchTextFieldContainer.addSubview(searchTextField)
		view.addSubview(searchTextFieldContainer)
		view.addSubview(tableView)

		NSLayoutConstraint.activate([
			searchTextField.leadingAnchor.constraint(equalTo: searchTextFieldContainer.leadingAnchor, constant: 8),
			searchTextField.centerYAnchor.constraint(equalTo: searchTextFieldContainer.centerYAnchor),
			searchTextField.trailingAnchor.constraint(equalTo: searchTextFieldContainer.trailingAnchor, constant: -8),

			searchTextFieldContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
			searchTextFieldContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: sizeMode.convert(16)),
			searchTextFieldContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
			searchTextFieldContainer.heightAnchor.constraint(equalToConstant: sizeMode.convert(44)),

			tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			tableView.topAnchor.constraint(equalTo: searchTextFieldContainer.bottomAnchor, constant: sizeMode.convert(16)),
			tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])

		tableView.dataSource = self
		tableView.delegate = self
		tableView.reloadData()

		NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
	}

	required init?(coder: NSCoder) { fatalError() }


	func animatePresent() {
		searchTextField.becomeFirstResponder()
	}

	@objc
	private func keyboardWillShow(notification: NSNotification) {
		if let keyboardFrame: NSValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
			reportKeyboardHeightCallback(keyboardFrame.cgRectValue.height)
		}
	}

	@objc
	private func keyboardWillHide(notification: NSNotification) {
		reportKeyboardHeightCallback(0)
	}

	@objc
	private func cancelButtonPushed() {
		dismiss(with: .cancel)
	}

	@objc
	private func unassignButtonPushed() {
		dismiss(with: .unassign)
	}

	private func returnKeyPressed() {
		guard !model.searchString.isEmpty,
		let result = model.results.first else {
			return
		}

		switch result {
		case .assignEntry(let gamepadAssignEntry):
			dismiss(with: .assignment(gamepadAssignEntry.assignment))
		case .keysJoystick:
			keysJoystickCreationRequest()
		}
	}

	func dismiss(with result: GamepadAssignResult) {
		searchTextField.resignFirstResponder()

		dismissRequestCallback(result)
	}
}

extension GamepadButtonBrowserViewController: UITableViewDataSource {
	func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		model.results.count
	}

	func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		guard let cell = tableView.dequeueReusableCell(withIdentifier: GamepadButtonBrowserEntryCell.reuseIdentifier, for: indexPath) as? GamepadButtonBrowserEntryCell else {
			return UITableViewCell()
		}

		let entry = model.results[indexPath.row]

		let isPrimarySelection = !model.searchString.isEmpty && indexPath.row == 0

		cell.config(
			identifier: entry.identifier,
			isPrimarySelection: isPrimarySelection,
			sizeMode: sizeMode,
			didTapInfoButton: { [weak self] in
				let alertVc = UIAlertController.with(
					title: entry.identifier,
					message: entry.description
				)
				self?.present(alertVc, animated: true)
			}
		)

		return cell
	}
}

extension GamepadButtonBrowserViewController: UITableViewDelegate {
	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let result = model.results[indexPath.row]

		switch result {
		case .assignEntry(let assignmentEntry):
			dismiss(with: .assignment(assignmentEntry.assignment))
		case .keysJoystick:
			searchTextField.resignFirstResponder()
			keysJoystickCreationRequest()
		}
	}
}

extension GamepadButtonBrowserViewController: UITextFieldDelegate {
	func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
		UIView.animate(withDuration: 0.2) {
			self.searchTextFieldAccessoryView.fadeInDismissKeyboardButton()
		}

		return true
	}

	func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
		if string == "\n" {
			returnKeyPressed()
			return false
		}

		var text = textField.text ?? ""
		if let range = Range(range, in: text) {
			text.replaceSubrange(range, with: string)
		}

		model.input(searchString: text)

		tableView.reloadData()

		return true
	}

	func textFieldShouldEndEditing(_ textField: UITextField) -> Bool {
		UIView.animate(withDuration: 0.2) {
			self.searchTextFieldAccessoryView.fadeOutDismissKeyboardButton()
		}

		return true
	}
}
