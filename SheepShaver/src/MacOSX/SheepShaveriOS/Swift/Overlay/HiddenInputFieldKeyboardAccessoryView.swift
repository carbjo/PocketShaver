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
		return stackView
	}()

	private lazy var leftCmdButton: UIButton = {
		createButton(title: "⌘")
	}()

	private lazy var leftOptButton: UIButton = {
		createButton(title: "opt")
	}()

	private lazy var leftCtrlButton: UIButton = {
		createButton(title: "ctrl")
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

	private lazy var rightOptButton: UIButton = {
		createButton(title: "opt")
	}()

	private lazy var rightCtrlButton: UIButton = {
		createButton(title: "ctrl")
	}()

	private var pushKey: ((Int) -> Void)?
	private var releaseKey: ((Int) -> Void)?

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
		leftStackView.addArrangedSubview(leftCmdButton)
		leftStackView.addArrangedSubview(leftOptButton)
		leftStackView.addArrangedSubview(leftCtrlButton)

		addSubview(rightStackView)
		rightStackView.addArrangedSubview(rightCtrlButton)
		rightStackView.addArrangedSubview(rightOptButton)
		rightStackView.addArrangedSubview(rightCmdButton)

		NSLayoutConstraint.activate([
			leftStackView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
			leftStackView.topAnchor.constraint(equalTo: topAnchor),
			leftStackView.bottomAnchor.constraint(equalTo: bottomAnchor),

			rightStackView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
			rightStackView.topAnchor.constraint(equalTo: topAnchor),
			rightStackView.bottomAnchor.constraint(equalTo: bottomAnchor)
		])

		leftCmdButton.addTarget(self, action: #selector(cmdPushed), for: .touchDown)
		leftOptButton.addTarget(self, action: #selector(optPushed), for: .touchDown)
		leftCtrlButton.addTarget(self, action: #selector(ctrlPushed), for: .touchDown)

		leftCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpInside)
		leftOptButton.addTarget(self, action: #selector(optReleased), for: .touchUpInside)
		leftCtrlButton.addTarget(self, action: #selector(ctrlReleased), for: .touchUpInside)
		leftCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpOutside)
		leftOptButton.addTarget(self, action: #selector(optReleased), for: .touchUpOutside)
		leftCtrlButton.addTarget(self, action: #selector(ctrlReleased), for: .touchUpOutside)

		rightCmdButton.addTarget(self, action: #selector(cmdPushed), for: .touchDown)
		rightOptButton.addTarget(self, action: #selector(optPushed), for: .touchDown)
		rightCtrlButton.addTarget(self, action: #selector(ctrlPushed), for: .touchDown)

		rightCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpInside)
		rightOptButton.addTarget(self, action: #selector(optReleased), for: .touchUpInside)
		rightCtrlButton.addTarget(self, action: #selector(ctrlReleased), for: .touchUpInside)
		rightCmdButton.addTarget(self, action: #selector(cmdReleased), for: .touchUpOutside)
		rightOptButton.addTarget(self, action: #selector(optReleased), for: .touchUpOutside)
		rightCtrlButton.addTarget(self, action: #selector(ctrlReleased), for: .touchUpOutside)
	}
	
	required init?(coder: NSCoder) { fatalError() }

	func configure(
		pushKey: ((Int) -> Void)?,
		releaseKey: ((Int) -> Void)?
	) {
		self.pushKey = pushKey
		self.releaseKey = releaseKey
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
