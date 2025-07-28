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
		accessoryView.configure(pushKey: pushKey, releaseKey: releaseKey)
		inputAccessoryView = accessoryView
	}
	
	required init?(coder: NSCoder) { fatalError() }
}
