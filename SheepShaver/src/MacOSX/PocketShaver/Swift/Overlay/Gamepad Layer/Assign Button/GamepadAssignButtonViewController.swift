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

	private enum Content {
		case buttonBrowser
		case keysJoystickCreation
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

	private lazy var buttonBrowserVc: GamepadButtonBrowserViewController = {
		GamepadButtonBrowserViewController(
			for: gamepadButtonSize,
			reportKeyboardHeightCallback: { [weak self] keyboardHeight in
				self?.reportKeyboardHeight(keyboardHeight)
			},
			keysJoystickCreationRequest: { [weak self] in
				self?.displayKeysJoystickCreation()
			},
			dismissRequestCallback: { [weak self] result in
				self?.dismiss(with: result)
			}
		)
	}()

	private lazy var keysJoystickCreationVc: GamepadKeysJoystickCreationViewController = {
		let vc = GamepadKeysJoystickCreationViewController()
		vc.view.alpha = 0
		return vc
	}()

	private lazy var secondaryButton: UIButton = {
		let button = UIButton(type: .system)
		button.translatesAutoresizingMaskIntoConstraints = false
		button.addTarget(self, action: #selector(sencondaryButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var primaryButton: UIButton = {
		let button = UIButton(type: .system)
		button.translatesAutoresizingMaskIntoConstraints = false
		button.addTarget(self, action: #selector(primaryButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var bottomButtonStack: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .horizontal
		stackView.distribution = .fillEqually
		stackView.alignment = .fill

		stackView.addArrangedSubview(secondaryButton)

		let cancelButtonSeparator = UIView.withoutConstraints()
		cancelButtonSeparator.backgroundColor = UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
		secondaryButton.addSubview(cancelButtonSeparator)

		NSLayoutConstraint.activate([
			cancelButtonSeparator.widthAnchor.constraint(equalToConstant: 0.5),
			cancelButtonSeparator.topAnchor.constraint(equalTo: secondaryButton.topAnchor, constant: 10),
			cancelButtonSeparator.bottomAnchor.constraint(equalTo: secondaryButton.bottomAnchor),
			cancelButtonSeparator.trailingAnchor.constraint(equalTo: secondaryButton.trailingAnchor)
		])

		stackView.addArrangedSubview(primaryButton)

		return stackView
	}()

	private lazy var containerViewBottomConstraint: NSLayoutConstraint = {
		containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
	}()

	private let dismissRequestCallback: ((GamepadAssignButtonViewController, GamepadAssignResult) -> Void)

	private let gamepadButtonSize: GamepadButtonSize
	private let sizeMode: SizeMode
	private var content: Content = .buttonBrowser

	init(
		for gamepadButtonSize: GamepadButtonSize,
		dismissRequestCallback: @escaping ((GamepadAssignButtonViewController, GamepadAssignResult) -> Void)
	) {
		self.gamepadButtonSize = gamepadButtonSize
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
	}

	override func viewDidLoad() {
		super.viewDidLoad()


		view.addSubview(containerView)
		cardView.addSubview(buttonBrowserVc.view)
		cardView.addSubview(keysJoystickCreationVc.view)
		cardView.addSubview(bottomButtonStack)
		containerView.addSubview(cardView)

		buttonBrowserVc.willMove(toParent: self)
		addChild(buttonBrowserVc)
		buttonBrowserVc.didMove(toParent: self)

		NSLayoutConstraint.activate([
			containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			containerView.topAnchor.constraint(equalTo: view.topAnchor),
			containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			containerViewBottomConstraint,

			bottomButtonStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
			bottomButtonStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
			bottomButtonStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor).withPriority(.required - 1),
			bottomButtonStack.heightAnchor.constraint(equalToConstant: sizeMode.convert(60)),

			buttonBrowserVc.view.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
			buttonBrowserVc.view.topAnchor.constraint(equalTo: cardView.topAnchor),
			buttonBrowserVc.view.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
			buttonBrowserVc.view.bottomAnchor.constraint(equalTo: bottomButtonStack.topAnchor),

			keysJoystickCreationVc.view.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
			keysJoystickCreationVc.view.topAnchor.constraint(equalTo: cardView.topAnchor),
			keysJoystickCreationVc.view.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
			keysJoystickCreationVc.view.bottomAnchor.constraint(equalTo: bottomButtonStack.topAnchor),

			cardView.widthAnchor.constraint(equalToConstant: 280),
			cardView.heightAnchor.constraint(equalToConstant: 400).withPriority(.defaultHigh),

			cardView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
			cardView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor).withPriority(.defaultHigh),
			cardView.topAnchor.constraint(greaterThanOrEqualTo: containerView.topAnchor, constant: sizeMode.convert(8)),
			cardView.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: sizeMode.convert(-8))
		])

		configureBottomButtonsForCurrentContent()

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(keyboardWillShow),
			name: UIResponder.keyboardWillShowNotification,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(keyboardWillHide),
			name: UIResponder.keyboardWillHideNotification,
			object: nil
		)
	}

	required init?(coder: NSCoder) { fatalError() }

	func animatePresent() {
		buttonBrowserVc.animatePresent()

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

	private func configureBottomButtonsForCurrentContent() {
		switch content {
		case .buttonBrowser:
			secondaryButton.setTitle("Cancel", for: .normal)
			primaryButton.setTitle("Unassign", for: .normal)
			primaryButton.setTitleColor(.red, for: .normal)
		case .keysJoystickCreation:
			secondaryButton.setTitle("Back", for: .normal)
			primaryButton.setTitle("Assign", for: .normal)
			let normalTitleColor = secondaryButton.titleColor(for: .normal)
			primaryButton.setTitleColor(normalTitleColor, for: .normal)
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
	private func sencondaryButtonPushed() {
		switch content {
		case .buttonBrowser:
			dismiss(with: .cancel)
		case .keysJoystickCreation:
			displayButtonBrowser()
		}
	}

	@objc
	private func primaryButtonPushed() {
		switch content {
		case .buttonBrowser:
			dismiss(with: .unassign)
		case .keysJoystickCreation:
			createPendingKeysJoystickButtonPressed()
		}
	}

	private func createPendingKeysJoystickButtonPressed() {
		let keysJoystickConfig = keysJoystickCreationVc.model.compileConfig()
		dismiss(
			with: .assignment(
				.joystick(
					.keys(keysJoystickConfig)
				)
			)
		)
	}

	private func displayButtonBrowser() {
		content = .buttonBrowser
		UIView.animate(withDuration: 0.2) {
			self.keysJoystickCreationVc.view.alpha = 0
			self.configureBottomButtonsForCurrentContent()
		} completion: { [weak self] _ in
			UIView.animate(withDuration: 0.2) {
				self?.buttonBrowserVc.view.alpha = 1
			} completion: { [weak self] _ in
				self?.buttonBrowserVc.searchTextField.becomeFirstResponder()
			}
		}
	}

	private func displayKeysJoystickCreation() {
		content = .keysJoystickCreation
		UIView.animate(withDuration: 0.2) {
			self.buttonBrowserVc.view.alpha = 0
			self.configureBottomButtonsForCurrentContent()
		} completion: { [weak self] _ in
			UIView.animate(withDuration: 0.2) {
				self?.keysJoystickCreationVc.view.alpha = 1
			}
		}
	}

	private func dismiss(with result: GamepadAssignResult) {
		UIView.animate(withDuration: 0.2) {
			self.view.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
			self.cardView.alpha = 0
		} completion: { [weak self] _ in
			guard let self else { return }
			dismissRequestCallback(self, result)
		}
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
