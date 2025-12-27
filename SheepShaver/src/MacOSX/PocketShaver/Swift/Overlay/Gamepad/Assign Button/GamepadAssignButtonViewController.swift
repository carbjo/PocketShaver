//
//  GamepadAssignButtonViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-14.
//

import UIKit

class GamepadAssignButtonViewController: UIViewController {
	enum SizeMode {
		case normal
		case small
		case tiny
	}

	private lazy var containerView: UIView = {
		UIView.withoutConstraints()
	}()

	private lazy var cardView: UIView = {
		let isDarkMode = traitCollection.userInterfaceStyle == .dark

		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = isDarkMode ? Colors.popupCardBackground : .clear
		view.alpha = 0
		view.transform = .init(translationX: 0, y: 80)
		view.layer.cornerRadius = 8
		view.clipsToBounds = true

		if !isDarkMode {
			let visualEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialLight))
			visualEffectView.translatesAutoresizingMaskIntoConstraints = false

			view.addSubview(visualEffectView)

			NSLayoutConstraint.activate([
				visualEffectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
				visualEffectView.topAnchor.constraint(equalTo: view.topAnchor),
				visualEffectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
				visualEffectView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
			])
		}

		return view
	}()

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

	private lazy var tableView: UITableView = {
		let tableView = UITableView.withoutConstraints()
		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 50
		tableView.backgroundColor = .clear
		GamepadAssignButtonEntryCell.register(in: tableView)
		return tableView
	}()

	private lazy var bottomButtonStack: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .horizontal
		stackView.distribution = .fillEqually
		stackView.alignment = .fill

		let cancelButton = UIButton(type: .system)
		cancelButton.translatesAutoresizingMaskIntoConstraints = false
		cancelButton.setTitle("Cancel", for: .normal)
		cancelButton.addTarget(self, action: #selector(cancelButtonPushed), for: .touchUpInside)
		stackView.addArrangedSubview(cancelButton)

		let cancelButtonSeparator = UIView.withoutConstraints()
		cancelButtonSeparator.backgroundColor = UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
		cancelButton.addSubview(cancelButtonSeparator)

		NSLayoutConstraint.activate([
			cancelButtonSeparator.widthAnchor.constraint(equalToConstant: 0.5),
			cancelButtonSeparator.topAnchor.constraint(equalTo: cancelButton.topAnchor, constant: 10),
			cancelButtonSeparator.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
			cancelButtonSeparator.trailingAnchor.constraint(equalTo: cancelButton.trailingAnchor)
		])

		let unassignButton = UIButton(type: .system)
		unassignButton.translatesAutoresizingMaskIntoConstraints = false
		unassignButton.setTitle("Unassign", for: .normal)
		let originalFont = unassignButton.titleLabel!.font!
		unassignButton.setTitleColor(.red, for: .normal)
		unassignButton.addTarget(self, action: #selector(unassignButtonPushed), for: .touchUpInside)
		stackView.addArrangedSubview(unassignButton)

		return stackView
	}()

	private lazy var containerViewBottomConstraint: NSLayoutConstraint = {
		containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
	}()

	private let model = GamepadAssignButtonModel()
	private let dismissRequestCallback: ((GamepadAssignButtonViewController, GamepadAssignResult) -> Void)

	private let sizeMode: SizeMode

	init(
		dismissRequestCallback: @escaping ((GamepadAssignButtonViewController, GamepadAssignResult) -> Void)
	) {
		self.dismissRequestCallback = dismissRequestCallback

		if UIScreen.isSESize,
		   !UIScreen.isPortraitMode {
			sizeMode = .tiny
		} else if !UIDevice.isIPad,
			 !UIScreen.isPortraitMode {
			sizeMode = .small
		} else {
			sizeMode = .normal
		}

		super.init(nibName: nil, bundle: nil)
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		view.addSubview(containerView)
		searchTextFieldContainer.addSubview(searchTextField)
		cardView.addSubview(searchTextFieldContainer)
		cardView.addSubview(tableView)
		cardView.addSubview(bottomButtonStack)
		containerView.addSubview(cardView)

		NSLayoutConstraint.activate([
			containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			containerView.topAnchor.constraint(equalTo: view.topAnchor),
			containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			containerViewBottomConstraint,

			searchTextField.leadingAnchor.constraint(equalTo: searchTextFieldContainer.leadingAnchor, constant: 8),
			searchTextField.centerYAnchor.constraint(equalTo: searchTextFieldContainer.centerYAnchor),
			searchTextField.trailingAnchor.constraint(equalTo: searchTextFieldContainer.trailingAnchor, constant: -8),

			searchTextFieldContainer.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
			searchTextFieldContainer.topAnchor.constraint(equalTo: cardView.topAnchor, constant: sizeMode.convert(16)),
			searchTextFieldContainer.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: sizeMode.convert(-16)),
			searchTextFieldContainer.heightAnchor.constraint(equalToConstant: sizeMode.convert(44)),

			tableView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
			tableView.topAnchor.constraint(equalTo: searchTextFieldContainer.bottomAnchor, constant: sizeMode.convert(16)),
			tableView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),

			bottomButtonStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
			bottomButtonStack.topAnchor.constraint(equalTo: tableView.bottomAnchor),
			bottomButtonStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
			bottomButtonStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor).withPriority(.required - 1),
			bottomButtonStack.heightAnchor.constraint(equalToConstant: sizeMode.convert(60)),

			cardView.widthAnchor.constraint(equalToConstant: 280),
			cardView.heightAnchor.constraint(equalToConstant: 400).withPriority(.defaultHigh),

			cardView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
			cardView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor).withPriority(.defaultHigh),
			cardView.topAnchor.constraint(greaterThanOrEqualTo: containerView.topAnchor, constant: sizeMode.convert(8)),
			cardView.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: sizeMode.convert(-8))
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
		
		UIView.animate(
			withDuration: 0.28,
			delay: 0.0,
			usingSpringWithDamping: 0.6,
			initialSpringVelocity: 1.5,
			animations: {
				self.view.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.2)
				self.cardView.alpha = 1
				self.cardView.transform = .identity
			}
		)
	}

	private func reportKeyboardHeight(_ keyboardHeight: CGFloat) {
		UIView.animate(withDuration: 0.2) {
			self.containerViewBottomConstraint.constant = -keyboardHeight
			self.view.layoutIfNeeded()
		}
	}

	@objc
	private func keyboardWillShow(notification: NSNotification) {
		if let keyboardFrame: NSValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
			reportKeyboardHeight(keyboardFrame.cgRectValue.height)
		}
	}

	@objc
	private func keyboardWillHide(notification: NSNotification) {
		reportKeyboardHeight(0)
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

		dismiss(with: .assignment(result))
	}

	func dismiss(with result: GamepadAssignResult) {
		searchTextField.resignFirstResponder()

		UIView.animate(withDuration: 0.2) {
			self.view.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
			self.cardView.alpha = 0
		} completion: { [weak self] _ in
			guard let self else { return }

			dismissRequestCallback(self, result)
		}
	}
}

extension GamepadAssignButtonViewController: UITableViewDataSource {
	func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		model.results.count
	}
	
	func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		guard let cell = tableView.dequeueReusableCell(withIdentifier: GamepadAssignButtonEntryCell.reuseIdentifier, for: indexPath) as? GamepadAssignButtonEntryCell else {
			return UITableViewCell()
		}

		let entry = model.results[indexPath.row]

		let isPrimarySelection = !model.searchString.isEmpty && indexPath.row == 0

		cell.config(
			listEntry: entry,
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

extension GamepadAssignButtonViewController: UITableViewDelegate {
	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let result = model.results[indexPath.row]

		dismiss(with: .assignment(result))
	}
}

extension GamepadAssignButtonViewController: UITextFieldDelegate {
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
}

extension GamepadAssignButtonViewController.SizeMode {
	func convert(_ margin: CGFloat) -> CGFloat {
		switch self {
		case .normal:
			return margin
		case .small:
			switch margin {
			case 16:
				return 4
			case -16:
				return -4
			case 8:
				return 4
			case -8:
				return -4
			case 60:
				return 40
			default:
				return margin
			}
		case .tiny:
			switch margin {
			case 16:
				return 2
			case -16:
				return -2
			case 8:
				return 2
			case -8:
				return -2
			case 44:
				return 28
			case 60:
				return 40
			default:
				return margin
			}
		}
	}
}
