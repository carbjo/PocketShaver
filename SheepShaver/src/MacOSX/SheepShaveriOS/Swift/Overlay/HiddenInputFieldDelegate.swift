//
//  HiddenInputFieldDelegate.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-14.
//

import UIKit

struct HiddenInputFieldOutput {
	let key: SDLKey
	let withShift: Bool
	let keyboard: Keyboard?

	var value: Int {
		key.value(for: keyboard ?? .en)
	}
}

class HiddenInputFieldDelegate: NSObject, UITextFieldDelegate {
	private let didInputSDLKey: ((HiddenInputFieldOutput) -> Void)

	init(
		didInputSDLKey: @escaping ((HiddenInputFieldOutput) -> Void)
	) {
		self.didInputSDLKey = didInputSDLKey

		super.init()
	}

	func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
		var keyboard: Keyboard?
		if let primaryLanguage = textField.textInputMode?.primaryLanguage {
			keyboard = Keyboard(rawValue: primaryLanguage)
		}

		if let key = sdlKey(for: string, keyboard: keyboard) {
			didInputSDLKey(key)
		} else {
			print("Could not find SDLKey for \(string)")
		}

		textField.text = "  " // Needed so that it is always possible to backspace

		return true
	}

	private func sdlKey(for str: String, keyboard: Keyboard?) -> HiddenInputFieldOutput? {
		switch str {
		case "a": return .init(key: .a, withShift: false, keyboard: keyboard)
		case "b": return .init(key: .b, withShift: false, keyboard: keyboard)
		case "c": return .init(key: .c, withShift: false, keyboard: keyboard)
		case "d": return .init(key: .d, withShift: false, keyboard: keyboard)
		case "e": return .init(key: .e, withShift: false, keyboard: keyboard)
		case "f": return .init(key: .f, withShift: false, keyboard: keyboard)
		case "g": return .init(key: .g, withShift: false, keyboard: keyboard)
		case "h": return .init(key: .h, withShift: false, keyboard: keyboard)
		case "i": return .init(key: .i, withShift: false, keyboard: keyboard)
		case "j": return .init(key: .j, withShift: false, keyboard: keyboard)
		case "k": return .init(key: .k, withShift: false, keyboard: keyboard)
		case "l": return .init(key: .l, withShift: false, keyboard: keyboard)
		case "m": return .init(key: .m, withShift: false, keyboard: keyboard)
		case "n": return .init(key: .n, withShift: false, keyboard: keyboard)
		case "o": return .init(key: .o, withShift: false, keyboard: keyboard)
		case "p": return .init(key: .p, withShift: false, keyboard: keyboard)
		case "q": return .init(key: .q, withShift: false, keyboard: keyboard)
		case "r": return .init(key: .r, withShift: false, keyboard: keyboard)
		case "s": return .init(key: .s, withShift: false, keyboard: keyboard)
		case "t": return .init(key: .t, withShift: false, keyboard: keyboard)
		case "u": return .init(key: .u, withShift: false, keyboard: keyboard)
		case "v": return .init(key: .v, withShift: false, keyboard: keyboard)
		case "w": return .init(key: .w, withShift: false, keyboard: keyboard)
		case "x": return .init(key: .x, withShift: false, keyboard: keyboard)
		case "y": return .init(key: .y, withShift: false, keyboard: keyboard)
		case "z": return .init(key: .z, withShift: false, keyboard: keyboard)
		case "A": return .init(key: .a, withShift: true, keyboard: keyboard)
		case "B": return .init(key: .b, withShift: true, keyboard: keyboard)
		case "C": return .init(key: .c, withShift: true, keyboard: keyboard)
		case "D": return .init(key: .d, withShift: true, keyboard: keyboard)
		case "E": return .init(key: .e, withShift: true, keyboard: keyboard)
		case "F": return .init(key: .f, withShift: true, keyboard: keyboard)
		case "G": return .init(key: .g, withShift: true, keyboard: keyboard)
		case "H": return .init(key: .h, withShift: true, keyboard: keyboard)
		case "I": return .init(key: .i, withShift: true, keyboard: keyboard)
		case "J": return .init(key: .j, withShift: true, keyboard: keyboard)
		case "K": return .init(key: .k, withShift: true, keyboard: keyboard)
		case "L": return .init(key: .l, withShift: true, keyboard: keyboard)
		case "M": return .init(key: .m, withShift: true, keyboard: keyboard)
		case "N": return .init(key: .n, withShift: true, keyboard: keyboard)
		case "O": return .init(key: .o, withShift: true, keyboard: keyboard)
		case "P": return .init(key: .p, withShift: true, keyboard: keyboard)
		case "Q": return .init(key: .q, withShift: true, keyboard: keyboard)
		case "R": return .init(key: .r, withShift: true, keyboard: keyboard)
		case "S": return .init(key: .s, withShift: true, keyboard: keyboard)
		case "T": return .init(key: .t, withShift: true, keyboard: keyboard)
		case "U": return .init(key: .u, withShift: true, keyboard: keyboard)
		case "V": return .init(key: .v, withShift: true, keyboard: keyboard)
		case "W": return .init(key: .w, withShift: true, keyboard: keyboard)
		case "X": return .init(key: .x, withShift: true, keyboard: keyboard)
		case "Y": return .init(key: .y, withShift: true, keyboard: keyboard)
		case "Z": return .init(key: .z, withShift: true, keyboard: keyboard)
		case "1": return .init(key: .n1, withShift: false, keyboard: keyboard)
		case "2": return .init(key: .n2, withShift: false, keyboard: keyboard)
		case "3": return .init(key: .n3, withShift: false, keyboard: keyboard)
		case "4": return .init(key: .n4, withShift: false, keyboard: keyboard)
		case "5": return .init(key: .n5, withShift: false, keyboard: keyboard)
		case "6": return .init(key: .n6, withShift: false, keyboard: keyboard)
		case "7": return .init(key: .n7, withShift: false, keyboard: keyboard)
		case "8": return .init(key: .n8, withShift: false, keyboard: keyboard)
		case "9": return .init(key: .n9, withShift: false, keyboard: keyboard)
		case "0": return .init(key: .n0, withShift: false, keyboard: keyboard)
		case " ": return .init(key: .space, withShift: false, keyboard: keyboard)
		case "\n": return .init(key: .return, withShift: false, keyboard: keyboard)
		case "": return .init(key: .backspace, withShift: false, keyboard: keyboard)
		case "+": return .init(key: .kpPlus, withShift: false, keyboard: keyboard)
		case "-": return .init(key: .minus, withShift: false, keyboard: keyboard)
		case "=": return .init(key: .equals, withShift: false, keyboard: keyboard)
		case "[": return .init(key: .leftbracket, withShift: false, keyboard: keyboard)
		case "]": return .init(key: .rightbracket, withShift: false, keyboard: keyboard)
		case "/": return .init(key: .slash, withShift: false, keyboard: keyboard)
		case "\\": return .init(key: .backslash, withShift: false, keyboard: keyboard)
		case ";": return .init(key: .semicolon, withShift: false, keyboard: keyboard)
		case ".": return .init(key: .period, withShift: false, keyboard: keyboard)
		case ",": return .init(key: .comma, withShift: false, keyboard: keyboard)
		case "*": return .init(key: .kpMultiply, withShift: false, keyboard: keyboard)
		case "'": return .init(key: .quote, withShift: false, keyboard: keyboard)
		case "`": return .init(key: .backquote, withShift: false, keyboard: keyboard)
		case "å": return .init(key: .å, withShift: false, keyboard: keyboard)
		case "ä": return .init(key: .ä, withShift: false, keyboard: keyboard)
		case "ö": return .init(key: .ö, withShift: false, keyboard: keyboard)
		case "Å": return .init(key: .å, withShift: true, keyboard: keyboard)
		case "Ä": return .init(key: .ä, withShift: true, keyboard: keyboard)
		case "Ö": return .init(key: .ö, withShift: true, keyboard: keyboard)
		case "<": return .init(key: .lessThan, withShift: false, keyboard: keyboard)
		default:
			return nil
		}
	}
}
