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
		if let key = sdlKey(for: string) {
			didInputSDLKey(key)
		} else {
			print("Could not find SDLKey for \(string)")
		}

		textField.text = "  " // Needed so that it is always possible to backspace

		return true
	}

	private func sdlKey(for str: String) -> HiddenInputFieldOutput? {
		switch str {
		case "a": return .init(key: .a, withShift: false)
		case "b": return .init(key: .b, withShift: false)
		case "c": return .init(key: .c, withShift: false)
		case "d": return .init(key: .d, withShift: false)
		case "e": return .init(key: .e, withShift: false)
		case "f": return .init(key: .f, withShift: false)
		case "g": return .init(key: .g, withShift: false)
		case "h": return .init(key: .h, withShift: false)
		case "i": return .init(key: .i, withShift: false)
		case "j": return .init(key: .j, withShift: false)
		case "k": return .init(key: .k, withShift: false)
		case "l": return .init(key: .l, withShift: false)
		case "m": return .init(key: .m, withShift: false)
		case "n": return .init(key: .n, withShift: false)
		case "o": return .init(key: .o, withShift: false)
		case "p": return .init(key: .p, withShift: false)
		case "q": return .init(key: .q, withShift: false)
		case "r": return .init(key: .r, withShift: false)
		case "s": return .init(key: .s, withShift: false)
		case "t": return .init(key: .t, withShift: false)
		case "u": return .init(key: .u, withShift: false)
		case "v": return .init(key: .v, withShift: false)
		case "w": return .init(key: .w, withShift: false)
		case "x": return .init(key: .x, withShift: false)
		case "y": return .init(key: .y, withShift: false)
		case "z": return .init(key: .z, withShift: false)
		case "A": return .init(key: .a, withShift: true)
		case "B": return .init(key: .b, withShift: true)
		case "C": return .init(key: .c, withShift: true)
		case "D": return .init(key: .d, withShift: true)
		case "E": return .init(key: .e, withShift: true)
		case "F": return .init(key: .f, withShift: true)
		case "G": return .init(key: .g, withShift: true)
		case "H": return .init(key: .h, withShift: true)
		case "I": return .init(key: .i, withShift: true)
		case "J": return .init(key: .j, withShift: true)
		case "K": return .init(key: .k, withShift: true)
		case "L": return .init(key: .l, withShift: true)
		case "M": return .init(key: .m, withShift: true)
		case "N": return .init(key: .n, withShift: true)
		case "O": return .init(key: .o, withShift: true)
		case "P": return .init(key: .p, withShift: true)
		case "Q": return .init(key: .q, withShift: true)
		case "R": return .init(key: .r, withShift: true)
		case "S": return .init(key: .s, withShift: true)
		case "T": return .init(key: .t, withShift: true)
		case "U": return .init(key: .u, withShift: true)
		case "V": return .init(key: .v, withShift: true)
		case "W": return .init(key: .w, withShift: true)
		case "X": return .init(key: .x, withShift: true)
		case "Y": return .init(key: .y, withShift: true)
		case "Z": return .init(key: .z, withShift: true)
		case " ": return .init(key: .space, withShift: false)
		case "\n": return .init(key: .return, withShift: false)
		case "": return .init(key: .backspace, withShift: false)
		case "-": return .init(key: .minus, withShift: false)
		case "=": return .init(key: .equals, withShift: false)
		case "(": return .init(key: .leftbracket, withShift: false)
		case ")": return .init(key: .rightbracket, withShift: false)
		case "\\": return .init(key: .backslash, withShift: false)
		case ";": return .init(key: .semicolon, withShift: false)
		case ".": return .init(key: .period, withShift: false)
		case ",": return .init(key: .comma, withShift: false)
		case "*": return .init(key: .kpMultiply, withShift: false)
		case "\"": return .init(key: .quote, withShift: false)
		default:
			return nil
		}
	}
}
