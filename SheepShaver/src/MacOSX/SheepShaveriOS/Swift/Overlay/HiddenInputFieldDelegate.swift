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
		let key: SDLKey
		switch str {
		case "a": key = .a
		case "b": key = .b
		case "c": key = .c
		case "d": key = .d
		case "e": key = .e
		case "f": key = .f
		case "g": key = .g
		case "h": key = .h
		case "i": key = .i
		case "j": key = .j
		case "k": key = .k
		case "l": key = .l
		case "m": key = .m
		case "n": key = .n
		case "o": key = .o
		case "p": key = .p
		case "q": key = .q
		case "r": key = .r
		case "s": key = .s
		case "t": key = .t
		case "u": key = .u
		case "v": key = .v
		case "w": key = .w
		case "x": key = .x
		case "y": key = .y
		case "z": key = .z
		case "A": key = .a
		case "B": key = .b
		case "C": key = .c
		case "D": key = .d
		case "E": key = .e
		case "F": key = .f
		case "G": key = .g
		case "H": key = .h
		case "I": key = .i
		case "J": key = .j
		case "K": key = .k
		case "L": key = .l
		case "M": key = .m
		case "N": key = .n
		case "O": key = .o
		case "P": key = .p
		case "Q": key = .q
		case "R": key = .r
		case "S": key = .s
		case "T": key = .t
		case "U": key = .u
		case "V": key = .v
		case "W": key = .w
		case "X": key = .x
		case "Y": key = .y
		case "Z": key = .z
		case "1": key = .n1
		case "2": key = .n2
		case "3": key = .n3
		case "4": key = .n4
		case "5": key = .n5
		case "6": key = .n6
		case "7": key = .n7
		case "8": key = .n8
		case "9": key = .n9
		case "0": key = .n0
		case " ": key = .space
		case "\n": key = .a
		case "": key = .backspace
		case "+": key = .kpPlus
		case "-": key = .minus
		case "=": key = .equals
		case "[": key = .leftsquarebracket
		case "]": key = .rightsquarebracket
		case "/": key = .slash
		case "\\": key = .backslash
		case ";": key = .semicolon
		case ".": key = .period
		case ",": key = .comma
		case "*": key = .kpMultiply
		case "'": key = .quote
		case "`": key = .backquote
		case "å": key = .å
		case "ä": key = .ä
		case "ö": key = .ö
		case "Å": key = .å
		case "Ä": key = .ä
		case "Ö": key = .ö
		case "<": key = .lessThan
		default:
			return nil
		}

		let capitalLetters = "ABCDEFGHIJKLMNOPQRSTUVWXYZÅÄÖ"
		let withShift = capitalLetters.contains(str)

		return .init(key: key, withShift: withShift, keyboard: keyboard)
	}
}
