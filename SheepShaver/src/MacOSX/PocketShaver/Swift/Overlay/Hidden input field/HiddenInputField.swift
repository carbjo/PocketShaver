//
//  HiddenInputField.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-28.
//

import UIKit

class HiddenInputField: UITextField {
	init(
		inputInteractionModel: InputInteractionModel,
		didTapPreferencesButton: @escaping (() -> Void),
		didTapDismissKeyboardButton: @escaping (() -> Void),
		hiddenInputFieldDelegate: HiddenInputFieldDelegate
	) {
		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		autocapitalizationType = .none
		text = " "
		autocorrectionType = .no
		spellCheckingType = .no
		delegate = hiddenInputFieldDelegate
		let accessoryView = HiddenInputFieldKeyboardAccessoryView(
			inputInteractionModel: inputInteractionModel,
			didTapPreferencesButton: didTapPreferencesButton,
			didTapDismissKeyboardButton: didTapDismissKeyboardButton
		)
		inputAccessoryView = accessoryView
	}
	
	required init?(coder: NSCoder) { fatalError() }
}
