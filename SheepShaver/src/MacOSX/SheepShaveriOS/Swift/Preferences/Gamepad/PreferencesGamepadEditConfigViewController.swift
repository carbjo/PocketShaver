//
//  PreferencesGamepadEditConfigViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-13.
//

import UIKit

class PreferencesGamepadEditConfigViewController: UIViewController {
	@MainActor
	enum SectionType: Int, CaseIterable {
		case name
		case visibility
	}

	private lazy var containerView: UIView = {
		UIView.withoutConstraints()
	}()

	private lazy var cardView: UIView = {
		let view = UIView.withoutConstraints()
		view.layer.cornerRadius = 8
		view.backgroundColor = .clear
		view.alpha = 0
		view.transform = .init(translationX: 0, y: 80)
		view.layer.cornerRadius = 8
		view.clipsToBounds = true

		let visualEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialLight))
		visualEffectView.translatesAutoresizingMaskIntoConstraints = false

		view.addSubview(visualEffectView)

		NSLayoutConstraint.activate([
			visualEffectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			visualEffectView.topAnchor.constraint(equalTo: view.topAnchor),
			visualEffectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			visualEffectView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])

		return view
	}()

	private lazy var tableView: UITableView = {
		let tableView = UITableView.withoutConstraints()
		tableView.isScrollEnabled = false
		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 50
		tableView.backgroundColor = .clear
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

		let okButton = UIButton(type: .system)
		okButton.translatesAutoresizingMaskIntoConstraints = false
		okButton.setTitle("Ok", for: .normal)
		let originalFont = okButton.titleLabel!.font!
		okButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: originalFont.pointSize)
		okButton.addTarget(self, action: #selector(okButtonPushed), for: .touchUpInside)
		stackView.addArrangedSubview(okButton)

		return stackView
	}()

	private lazy var tableViewHeightConstraint: NSLayoutConstraint = {
		tableView.heightAnchor.constraint(equalToConstant: 500)
	}()

	private lazy var containerViewBottomConstraint: NSLayoutConstraint = {
		containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
	}()

	private let originalGamepadConfig: GamepadConfig
	private var gamepadConfig: GamepadConfig
	private let dismissRequestCallback: ((PreferencesGamepadEditConfigViewController) -> Void)

	init(
		gamepadConfig: GamepadConfig,
		dismissRequestCallback: @escaping ((PreferencesGamepadEditConfigViewController) -> Void)
	) {
		self.originalGamepadConfig = gamepadConfig
		self.gamepadConfig = gamepadConfig
		self.dismissRequestCallback = dismissRequestCallback

		super.init(nibName: nil, bundle: nil)
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		view.addSubview(containerView)
		cardView.addSubview(tableView)
		cardView.addSubview(bottomButtonStack)
		containerView.addSubview(cardView)

		NSLayoutConstraint.activate([
			containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			containerView.topAnchor.constraint(equalTo: view.topAnchor),
			containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			containerViewBottomConstraint,

			tableView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
			tableView.topAnchor.constraint(equalTo: cardView.topAnchor),
			tableView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),

			bottomButtonStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
			bottomButtonStack.topAnchor.constraint(equalTo: tableView.bottomAnchor),
			bottomButtonStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
			bottomButtonStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor).withPriority(.required - 1),
			bottomButtonStack.heightAnchor.constraint(equalToConstant: 60),

			cardView.widthAnchor.constraint(equalToConstant: 280),

			cardView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
			cardView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

			tableViewHeightConstraint
		])

		tableView.dataSource = self
		tableView.delegate = self
		tableView.reloadData()

		NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()

		tableView.layoutIfNeeded()
		tableViewHeightConstraint.constant = tableView.contentSize.height
	}

	func animatePresent() {
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
		dismiss(animated: true)
	}

	@objc
	private func okButtonPushed() {
		guard !gamepadConfig.name.isEmpty else {
			let alertVC = UIAlertController.withMessage("Name must not be empty")
			present(alertVC, animated: true)

			return
		}

		GamepadSettings.current.replace(originalGamepadConfig, with: gamepadConfig)

		dismiss(animated: true)
	}

	override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
		UIView.animate(withDuration: 0.2) {
			self.view.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
			self.cardView.alpha = 0
		} completion: { [weak self] _ in
			guard let self else { return }
			dismissRequestCallback(self)

			completion?()
		}
	}
}

extension PreferencesGamepadEditConfigViewController: UITableViewDataSource {
	func numberOfSections(in tableView: UITableView) -> Int {
		SectionType.allCases.count
	}

	func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		let section = SectionType(sectionIndex: section)
		switch section {
		case .name:
			return 1
		case .visibility:
			return 3
		}
	}
	
	func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let section = SectionType(sectionIndex: indexPath.section)
		switch section {
		case .name:
			return PreferencesGamepadEditConfigNameCell(
				name: gamepadConfig.name,
				delegate: self
			)
		case .visibility:
			switch indexPath.row {
			case 0:
				return PreferencesGamepadEditConfigOptionCell(
					visibilitySetting: .both,
					isChecked: gamepadConfig.visibilitySetting == .both
				)
			case 1:
				return PreferencesGamepadEditConfigOptionCell(
					visibilitySetting: .portraitOnly,
					isChecked: gamepadConfig.visibilitySetting == .portraitOnly
				)
			case 2:
				return PreferencesGamepadEditConfigOptionCell(
					visibilitySetting: .landscapeOnly,
					isChecked: gamepadConfig.visibilitySetting == .landscapeOnly
				)
			default:
				fatalError()
			}
		}
	}

	func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		let section = SectionType(sectionIndex: section)
		switch section {
		case .name:
			return "Layout name"
		case .visibility:
			return "Visibility"
		}
	}
}

extension PreferencesGamepadEditConfigViewController: UITableViewDelegate {
	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let section = SectionType(sectionIndex: indexPath.section)
		switch section {
		case .name:
			guard let cell = tableView.cellForRow(at: indexPath) as? PreferencesGamepadEditConfigNameCell else {
				return
			}
			cell.startEditing()
			break
		case .visibility:
			switch indexPath.row {
			case 0:
				gamepadConfig = gamepadConfig.withVisbility(.both)
			case 1:
				gamepadConfig = gamepadConfig.withVisbility(.portraitOnly)
			case 2:
				gamepadConfig = gamepadConfig.withVisbility(.landscapeOnly)
			default:
				fatalError()
			}

			for cell in tableView.visibleCells {
				guard let cell = cell as? PreferencesGamepadEditConfigOptionCell else {
					continue
				}
				cell.config(isChecked: cell.visibilitySetting == gamepadConfig.visibilitySetting)
			}
		}
	}
}

extension PreferencesGamepadEditConfigViewController: UITextFieldDelegate {
	func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
		var text = textField.text ?? ""
		if let range = Range(range, in: text) {
			text.replaceSubrange(range, with: string)
		}

		gamepadConfig = gamepadConfig.renaming(text)

		return true
	}

	func textFieldDidEndEditing(_ textField: UITextField) {
		gamepadConfig = gamepadConfig.renaming(textField.text ?? "")
	}

	func textFieldShouldReturn(_ textField: UITextField) -> Bool {
		textField.resignFirstResponder()
		return true
	}
}

extension PreferencesGamepadEditConfigViewController.SectionType {
	init(sectionIndex: Int) {
		self = Self(rawValue: sectionIndex)!
	}

	static var count: Int {
		allCases.count
	}

	func sectionIndex() -> Int {
		rawValue
	}
}
