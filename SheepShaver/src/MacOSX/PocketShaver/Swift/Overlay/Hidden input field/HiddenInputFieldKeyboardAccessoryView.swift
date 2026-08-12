//
//  HiddenInputFieldKeyboardAccessoryView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-19.
//

import UIKit

class HiddenInputFieldKeyboardAccessoryView: UIView {
	private lazy var leftStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .horizontal
		stackView.distribution = .fill
		return stackView
	}()

	private lazy var leftCmdButton: UIButton = {
		createButton(title: "⌘")
	}()

	private lazy var optButton: UIButton = {
		createButton(title: "⌥")
	}()

	private lazy var ctrlButton: UIButton = {
		createButton(title: "⌃")
	}()

	private lazy var shiftButton: UIButton = {
		createButton(title: "⇧")
	}()

	private lazy var copyClipboardHostToGuestButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(Assets.arrowRightPageOnClipboard.asSymbolImage(),
			for: .normal
		)
		button.configuration = buttonConfig()
		button.layer.cornerRadius = 8
		button.addTarget(self, action: #selector(copyClipboardHostToGuestButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var copyClipboardGuestToHostButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(Assets.arrowLeftPageOnClipboard.asSymbolImage(),
			for: .normal
		)
		button.configuration = buttonConfig()
		button.layer.cornerRadius = 8
		button.addTarget(self, action: #selector(copyClipboardGuestToHostButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var preferencesButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(ImageResource.gearshape.asSymbolImage(),
			for: .normal
		)
		button.configuration = buttonConfig()
		button.layer.cornerRadius = 8
		button.addTarget(self, action: #selector(preferencesButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var rightStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .horizontal
		return stackView
	}()

	private lazy var rightCmdButton: UIButton = {
		createButton(title: "⌘")
	}()

	private lazy var dismissKeyboardButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(ImageResource.keyboardChevronCompactDown.asSymbolImage(),
			for: .normal
		)
		button.configuration = buttonConfig()
		button.layer.cornerRadius = 8
		button.addTarget(self, action: #selector(dismissKeyboardButtonPushed), for: .touchUpInside)
		return button
	}()


	private let inputInteractionModel: InputInteractionModel
	private let didTapClipboardHostToGuestButton: (() -> Void)
	private let didTapClipboardGuestToHostButton: (() -> Void)
	private let didTapPreferencesButton: (() -> Void)
	private let didTapDismissKeyboardButton: (() -> Void)

	private var pushKey: ((SDLKey) -> Void)!
	private var releaseKey: ((SDLKey) -> Void)!

	private let deviceScreenSize = UIScreen.deviceScreenSize

	init(
		inputInteractionModel: InputInteractionModel,
		didTapClipboardHostToGuestButton: @escaping (() -> Void),
		didTapClipboardGuestToHostButton: @escaping (() -> Void),
		didTapPreferencesButton: @escaping (() -> Void),
		didTapDismissKeyboardButton: @escaping (() -> Void)
	) {
		self.inputInteractionModel = inputInteractionModel
		self.didTapClipboardHostToGuestButton = didTapClipboardHostToGuestButton
		self.didTapClipboardGuestToHostButton = didTapClipboardGuestToHostButton
		self.didTapPreferencesButton = didTapPreferencesButton
		self.didTapDismissKeyboardButton = didTapDismissKeyboardButton

		super.init(
			frame: .init(
				origin: .zero,
				size: .init(
					width: 100,
					height: 44
				)
			)
		)

		translatesAutoresizingMaskIntoConstraints = false

		addSubview(leftStackView)
		addSubview(rightStackView)

		let spacing: CGFloat
		let sideMargin: CGFloat
		switch (deviceScreenSize, UIScreen.isPortraitMode) {
		case (.normal, _):
			spacing = 8
			sideMargin = 16
		case (.small, false):
			spacing = 4
			sideMargin = 8
			copyClipboardHostToGuestButton.setTargetWidth(44)
			copyClipboardGuestToHostButton.setTargetWidth(44)
			preferencesButton.setTargetWidth(44)
			dismissKeyboardButton.setTargetWidth(44)
		case (.small, true),
			(.tiny, _):
			spacing = 3
			sideMargin = 4
			copyClipboardHostToGuestButton.setTargetWidth(38)
			copyClipboardGuestToHostButton.setTargetWidth(38)
			preferencesButton.setTargetWidth(38)
			dismissKeyboardButton.setTargetWidth(38)
		}

		leftStackView.spacing = spacing
		rightStackView.spacing = spacing

		leftStackView.addArrangedSubview(leftCmdButton)
		leftStackView.addArrangedSubview(optButton)
		leftStackView.addArrangedSubview(ctrlButton)
		leftStackView.addArrangedSubview(shiftButton)

		rightStackView.addArrangedSubview(copyClipboardHostToGuestButton)
		rightStackView.addArrangedSubview(copyClipboardGuestToHostButton)
		rightStackView.addArrangedSubview(preferencesButton)
		if !UIScreen.isPortraitMode || UIDevice.isIPadIdiom {
			rightStackView.addArrangedSubview(rightCmdButton)
		}
		if !UIDevice.isIPadIdiom {
			rightStackView.addArrangedSubview(dismissKeyboardButton)
		}

		NSLayoutConstraint.activate([
			leftStackView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: sideMargin),
			leftStackView.topAnchor.constraint(equalTo: topAnchor),
			leftStackView.bottomAnchor.constraint(equalTo: bottomAnchor),

			rightStackView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -sideMargin),
			rightStackView.topAnchor.constraint(equalTo: topAnchor),
			rightStackView.bottomAnchor.constraint(equalTo: bottomAnchor)
		])

		leftCmdButton.addTarget(self, action: #selector(cmdPushed), for: .touchDown)
		optButton.addTarget(self, action: #selector(optPushed), for: .touchDown)
		ctrlButton.addTarget(self, action: #selector(ctrlPushed), for: .touchDown)
		shiftButton.addTarget(self, action: #selector(shiftPushed), for: .touchDown)

		leftCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpInside)
		optButton.addTarget(self, action: #selector(optReleased), for: .touchUpInside)
		ctrlButton.addTarget(self, action: #selector(ctrlReleased), for: .touchUpInside)
		shiftButton.addTarget(self, action: #selector(shiftReleased), for: .touchUpInside)
		leftCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpOutside)
		optButton.addTarget(self, action: #selector(optReleased), for: .touchUpOutside)
		ctrlButton.addTarget(self, action: #selector(ctrlReleased), for: .touchUpOutside)
		shiftButton.addTarget(self, action: #selector(shiftReleased), for: .touchUpOutside)

		rightCmdButton.addTarget(self, action: #selector(cmdPushed), for: .touchDown)

		rightCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpInside)
		rightCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpOutside)

		pushKey = { [weak self] key in
			self?.inputInteractionModel.handle(key, isDown: true)
		}
		releaseKey = { [weak self] key in
			self?.inputInteractionModel.handle(key, isDown: false)
		}

		listenToChanges()
	}
	
	required init?(coder: NSCoder) { fatalError() }

	private func listenToChanges() {
		LocalNotification.observe(.clipboardSharingSettingChanged, self, #selector(updateClipboardSharingButtonVisiblity))
	}

	@objc private func cmdPushed() {
		pushKey?(SDLKey.cmd)
	}
	
	@objc private func cmdReleased() {
		releaseKey?(SDLKey.cmd)
	}

	@objc private func optPushed() {
		pushKey?(SDLKey.alt)
	}

	@objc private func optReleased() {
		releaseKey?(SDLKey.alt)
	}

	@objc private func ctrlPushed() {
		pushKey?(SDLKey.ctrl)
	}

	@objc private func ctrlReleased() {
		releaseKey?(SDLKey.ctrl)
	}

	@objc private func shiftPushed() {
		pushKey?(SDLKey.shift)
	}

	@objc private func shiftReleased() {
		releaseKey?(SDLKey.shift)
	}

	@objc private func copyClipboardGuestToHostButtonPushed() {
		didTapClipboardGuestToHostButton();
	}

	@objc private func copyClipboardHostToGuestButtonPushed() {
		didTapClipboardHostToGuestButton();
	}

	@objc private func preferencesButtonPushed() {
		didTapPreferencesButton()
	}

	@objc private func dismissKeyboardButtonPushed() {
		didTapDismissKeyboardButton()
	}

	private func createButton(title: String) -> UIButton {
		let button = UIButton.withoutConstraints()
		button.setTitle(title, for: .normal)
		button.configuration = buttonConfig()
		button.backgroundColor = .gray
		button.layer.cornerRadius = 8
		return button
	}

	@objc private func updateClipboardSharingButtonVisiblity() {
		let isHidden = MiscellaneousSettings.current.clipboardSharing == .automatic
		copyClipboardGuestToHostButton.isHidden = isHidden
		copyClipboardHostToGuestButton.isHidden = isHidden
	}
}

@MainActor
private func buttonConfig() -> UIButton.Configuration {
	var configuration = UIButton.Configuration.filled()
	configuration.baseForegroundColor = .white
	configuration.baseBackgroundColor = .lightGray
	let margin: CGFloat = UIScreen.deviceScreenSize == .tiny ? 12 : 16
	configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
	configuration.background.cornerRadius = 8
	return configuration
}
