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
		isHidden = true
		delegate = hiddenInputFieldDelegate
		let accessoryView = HiddenInputFieldKeyboardAccessoryView(
			inputInteractionModel: inputInteractionModel,
			didTapPreferencesButton: didTapPreferencesButton,
			didTapDismissKeyboardButton: didTapDismissKeyboardButton
		)
		if UIDevice.deviceType != .mac {
			inputAccessoryView = accessoryView
		}
	}
	
	required init?(coder: NSCoder) { fatalError() }

	func reportKeyboardWillChangePosition(_ keyboardRect: CGRect) {
		guard let inputAccessoryView else {
			return
		}

		if !keyboardRect.isDocked {
			inputAccessoryView.alpha = 0
		}
	}

	func reportKeyboardDidChangePosition(_ keyboardRect: CGRect) {
		guard let inputAccessoryView else {
			return
		}

		var frame = inputAccessoryView.frame

		if #available(iOS 26.0, *) {
			frame.origin.y = 0
		} else if #available(iOS 17.0, *) {
			// Addresses a bug on iOS 17 and 18 where the inputAccessoryView would hide underneath the keyboard when not docked on iPad
			frame.origin.y = keyboardRect.isDocked ? 0 : -52
		} else {
			// Bug not present on iOS 15 and 16
			frame.origin.y = 0
		}

		inputAccessoryView.frame = frame

		UIView.animate(withDuration: 0.2) {
			inputAccessoryView.alpha = 1
		}
	}
}

private extension CGRect {
	var isDocked: Bool {
		return (origin.y + size.height) == UIScreen.main.bounds.size.height
	}
}
