//
//  HiddenInputFieldKeyboardAccessoryView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-19.
//

import UIKit

private enum DeviceScreenSize {
	case normal
	case small
	case tiny
}

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

	private lazy var relativeMouseModeButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(
			.init(resource: .computermouse).applyingSymbolConfiguration(.init(pointSize: 12)),
			for: .normal
		)
		button.configuration = buttonConfig()
		button.layer.cornerRadius = 8
		button.addTarget(self, action: #selector(relativeMouseModeButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var preferencesButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(
			.init(resource: .gearshape).applyingSymbolConfiguration(.init(pointSize: 12)),
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
		button.setImage(
			.init(resource: .keyboardChevronCompactDown).applyingSymbolConfiguration(.init(pointSize: 12)),
			for: .normal
		)
		button.configuration = buttonConfig()
		button.layer.cornerRadius = 8
		button.addTarget(self, action: #selector(dismissKeyboardButtonPushed), for: .touchUpInside)
		return button
	}()

	private var pushKey: ((Int) -> Void)?
	private var releaseKey: ((Int) -> Void)?
	private var didTapRelativeMouseModeButton: (() -> Void)?
	private var didTapPreferencesButton: (() -> Void)?
	private var didTapDismissKeyboardButton: (() -> Void)?

	private let deviceScreenSize = UIScreen.deviceScreenSize

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

		let spacing: CGFloat
		let sideMargin: CGFloat
		switch deviceScreenSize {
		case .normal:
			spacing = 8
			sideMargin = 16
		case .small:
			spacing = 4
			sideMargin = 8
			relativeMouseModeButton.setTargetWidth(44)
			preferencesButton.setTargetWidth(44)
			dismissKeyboardButton.setTargetWidth(44)
		case .tiny:
			spacing = 3
			sideMargin = 4
			relativeMouseModeButton.setTargetWidth(38)
			preferencesButton.setTargetWidth(38)
			dismissKeyboardButton.setTargetWidth(38)
		}

		leftStackView.spacing = spacing
		rightStackView.spacing = spacing

		leftStackView.addArrangedSubview(leftCmdButton)
		leftStackView.addArrangedSubview(optButton)
		leftStackView.addArrangedSubview(ctrlButton)
		leftStackView.addArrangedSubview(shiftButton)

		rightStackView.addArrangedSubview(relativeMouseModeButton)
		rightStackView.addArrangedSubview(preferencesButton)
		if !UIScreen.isPortraitMode || UIDevice.isIPad {
			rightStackView.addArrangedSubview(rightCmdButton)
		}
		rightStackView.addArrangedSubview(dismissKeyboardButton)


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
	}
	
	required init?(coder: NSCoder) { fatalError() }

	func configure(
		pushKey: ((Int) -> Void)?,
		releaseKey: ((Int) -> Void)?,
		canToggleRelativeMouseMode: Bool,
		isRelativeMouseModeEnabled: Bool,
		didTapRelativeMouseModeButton: (() -> Void)?,
		didTapPreferencesButton: (() -> Void)?,
		didTapDismissKeyboardButton: (() -> Void)?
	) {
		self.pushKey = pushKey
		self.releaseKey = releaseKey
		self.didTapRelativeMouseModeButton = didTapRelativeMouseModeButton
		self.didTapPreferencesButton = didTapPreferencesButton
		self.didTapDismissKeyboardButton = didTapDismissKeyboardButton

		configure(canToggleRelativeMouseMode: canToggleRelativeMouseMode)
		configure(isRelativeMouseModeEnabled: isRelativeMouseModeEnabled)
	}

	func configure(canToggleRelativeMouseMode: Bool) {
		relativeMouseModeButton.isHidden = !canToggleRelativeMouseMode
	}

	func configure(isRelativeMouseModeEnabled: Bool) {
		relativeMouseModeButton.configuration!.baseBackgroundColor = isRelativeMouseModeEnabled ? .gray : .lightGray
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

	@objc private func relativeMouseModeButtonPushed() {
		didTapRelativeMouseModeButton?()
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

private extension UIButton {
	func setTargetWidth(_ width: CGFloat) {
		let totalMargin: CGFloat = width - image(for: .normal)!.size.width
		let margin = totalMargin / 2
		configuration!.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
	}
}

private extension UIScreen {
	static var deviceScreenSize: DeviceScreenSize {
		if isSESize,
		   isPortraitMode {
			return .tiny
		} else if !UIDevice.isIPad,
				  isPortraitMode {
			return .small
		} else {
			return .normal
		}
	}
}
