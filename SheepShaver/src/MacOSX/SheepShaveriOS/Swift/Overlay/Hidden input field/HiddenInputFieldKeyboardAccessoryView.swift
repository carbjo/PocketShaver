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
		stackView.spacing = 8
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
		createButton(title: "ctrl")
	}()

	private lazy var leftShiftButton: UIButton = {
		createButton(title: "⇧")
	}()

	private lazy var preferencesButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(
			.init(resource: .gearshape).applyingSymbolConfiguration(.init(pointSize: 12)),
			for: .normal
		)
		button.configuration = buttonConfig()
		button.backgroundColor = .gray
		button.layer.cornerRadius = 8
		button.addTarget(self, action: #selector(preferencesButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var rightStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .horizontal
		stackView.spacing = 8
		return stackView
	}()

	private lazy var rightCmdButton: UIButton = {
		createButton(title: "⌘")
	}()

	private lazy var rightShiftButton: UIButton = {
		createButton(title: "⇧")
	}()

	private lazy var dismissKeyboardButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(
			.init(resource: .keyboardChevronCompactDown).applyingSymbolConfiguration(.init(pointSize: 12)),
			for: .normal
		)
		button.configuration = buttonConfig()
		button.backgroundColor = .gray
		button.layer.cornerRadius = 8
		button.addTarget(self, action: #selector(dismissKeyboardButtonPushed), for: .touchUpInside)
		return button
	}()

	private var pushKey: ((Int) -> Void)?
	private var releaseKey: ((Int) -> Void)?
	private var didTapPreferencesButton: (() -> Void)?
	private var didTapDismissKeyboardButton: (() -> Void)?

	init() {
		super.init(
			frame: .init(
				origin: .zero,
				size: .init(
					width: 100,
					height: 44
				)
			)
		)

		addSubview(leftStackView)
		addSubview(rightStackView)


		if UIScreen.isPortraitMode {
			leftStackView.addArrangedSubview(leftCmdButton)
			leftStackView.addArrangedSubview(optButton)
			rightStackView.addArrangedSubview(preferencesButton)
			rightStackView.addArrangedSubview(ctrlButton)
			rightStackView.addArrangedSubview(rightShiftButton)
		} else {
			leftStackView.addArrangedSubview(leftCmdButton)
			leftStackView.addArrangedSubview(optButton)
			leftStackView.addArrangedSubview(ctrlButton)
			leftStackView.addArrangedSubview(leftShiftButton)

			rightStackView.addArrangedSubview(preferencesButton)
			rightStackView.addArrangedSubview(rightShiftButton)
			rightStackView.addArrangedSubview(rightCmdButton)
			rightStackView.addArrangedSubview(dismissKeyboardButton)
		}

		NSLayoutConstraint.activate([
			leftStackView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
			leftStackView.topAnchor.constraint(equalTo: topAnchor),
			leftStackView.bottomAnchor.constraint(equalTo: bottomAnchor),

			rightStackView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
			rightStackView.topAnchor.constraint(equalTo: topAnchor),
			rightStackView.bottomAnchor.constraint(equalTo: bottomAnchor)
		])

		leftCmdButton.addTarget(self, action: #selector(cmdPushed), for: .touchDown)
		optButton.addTarget(self, action: #selector(optPushed), for: .touchDown)
		ctrlButton.addTarget(self, action: #selector(ctrlPushed), for: .touchDown)
		leftShiftButton.addTarget(self, action: #selector(shiftPushed), for: .touchDown)

		leftCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpInside)
		optButton.addTarget(self, action: #selector(optReleased), for: .touchUpInside)
		ctrlButton.addTarget(self, action: #selector(ctrlReleased), for: .touchUpInside)
		leftShiftButton.addTarget(self, action: #selector(shiftReleased), for: .touchUpInside)
		leftCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpOutside)
		optButton.addTarget(self, action: #selector(optReleased), for: .touchUpOutside)
		ctrlButton.addTarget(self, action: #selector(ctrlReleased), for: .touchUpOutside)
		leftShiftButton.addTarget(self, action: #selector(shiftReleased), for: .touchUpOutside)

		rightCmdButton.addTarget(self, action: #selector(cmdPushed), for: .touchDown)
		rightShiftButton.addTarget(self, action: #selector(shiftPushed), for: .touchDown)

		rightCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpInside)
		rightShiftButton.addTarget(self, action: #selector(shiftReleased), for: .touchUpInside)
		rightCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpOutside)
		rightShiftButton.addTarget(self, action: #selector(shiftReleased), for: .touchUpOutside)
	}
	
	required init?(coder: NSCoder) { fatalError() }

	func configure(
		pushKey: ((Int) -> Void)?,
		releaseKey: ((Int) -> Void)?,
		didTapPreferencesButton: (() -> Void)?,
		didTapDismissKeyboardButton: (() -> Void)?
	) {
		self.pushKey = pushKey
		self.releaseKey = releaseKey
		self.didTapPreferencesButton = didTapPreferencesButton
		self.didTapDismissKeyboardButton = didTapDismissKeyboardButton
	}

	@objc private func cmdPushed() {
		pushKey?(SDLKey.cmd.enValue)
	}
	
	@objc private func cmdReleased() {
		releaseKey?(SDLKey.cmd.enValue)
	}

	@objc private func optPushed() {
		pushKey?(SDLKey.alt.enValue)
	}

	@objc private func optReleased() {
		releaseKey?(SDLKey.alt.enValue)
	}

	@objc private func ctrlPushed() {
		pushKey?(SDLKey.ctrl.enValue)
	}

	@objc private func ctrlReleased() {
		releaseKey?(SDLKey.ctrl.enValue)
	}

	@objc private func shiftPushed() {
		pushKey?(SDLKey.shift.enValue)
	}

	@objc private func shiftReleased() {
		releaseKey?(SDLKey.shift.enValue)
	}

	@objc private func preferencesButtonPushed() {
		didTapPreferencesButton?()
	}

	@objc private func dismissKeyboardButtonPushed() {
		didTapDismissKeyboardButton?()
	}

	private func createButton(title: String) -> UIButton {
		let button = UIButton.withoutConstraints()
		button.setTitle(title, for: .normal)
		button.configuration = buttonConfig()
		button.backgroundColor = .gray
		button.layer.cornerRadius = 8
		return button
	}
}

private func buttonConfig() -> UIButton.Configuration {
	var configuration = UIButton.Configuration.filled()
	configuration.baseForegroundColor = .white
	configuration.baseBackgroundColor = .lightGray
	configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
	configuration.background.cornerRadius = 8
	return configuration
}
