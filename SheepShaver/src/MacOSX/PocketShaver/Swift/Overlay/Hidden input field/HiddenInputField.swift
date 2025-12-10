//
//  HiddenInputField.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-28.
//

import UIKit

class HiddenInputField: UITextField {
	init(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void),
		canToggleRelativeMouseMode: Bool,
		isRelativeMouseModeEnabled: Bool,
		didTapRelativeMouseModeButton: @escaping (() -> Void),
		didTapPreferencesButton: @escaping (() -> Void),
		didTapDismissKeyboardButton: (() -> Void)?,
		hiddenInputFieldDelegate: HiddenInputFieldDelegate
	) {
		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		autocapitalizationType = .none
		text = " "
		autocorrectionType = .no
		spellCheckingType = .no
		delegate = hiddenInputFieldDelegate
		let accessoryView = HiddenInputFieldKeyboardAccessoryView.withoutConstraints()
		accessoryView.configure(
			pushKey: pushKey,
			releaseKey: releaseKey,
			canToggleRelativeMouseMode: canToggleRelativeMouseMode,
			isRelativeMouseModeEnabled: isRelativeMouseModeEnabled,
			didTapRelativeMouseModeButton: didTapRelativeMouseModeButton,
			didTapPreferencesButton: didTapPreferencesButton,
			didTapDismissKeyboardButton: didTapDismissKeyboardButton
		)
		inputAccessoryView = accessoryView
	}
	
	required init?(coder: NSCoder) { fatalError() }

	func configure(canToggleRelativeMouseMode: Bool) {
		guard let inputAccessoryView = inputAccessoryView as? HiddenInputFieldKeyboardAccessoryView else {
			return
		}
		inputAccessoryView.configure(canToggleRelativeMouseMode: canToggleRelativeMouseMode)
	}

	func configure(isRelativeMouseModeEnabled: Bool) {
		guard let inputAccessoryView = inputAccessoryView as? HiddenInputFieldKeyboardAccessoryView else {
			return
		}
		inputAccessoryView.configure(isRelativeMouseModeEnabled: isRelativeMouseModeEnabled)
	}
}
