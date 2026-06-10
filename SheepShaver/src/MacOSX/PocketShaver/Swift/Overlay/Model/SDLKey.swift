//
//  SDLKey.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-05.
//

enum SDLKey: String, Codable, Hashable, CaseIterable {
	case a
	case b
	case c
	case d
	case e
	case f
	case g
	case h
	case i
	case j
	case k
	case l
	case m
	case n
	case o
	case p
	case q
	case r
	case s
	case t
	case u
	case v
	case w
	case x
	case y
	case z

	// Numbers above letter area on keyboard
	case paragraph
	case n1
	case n2
	case n3
	case n4
	case n5
	case n6
	case n7
	case n8
	case n9
	case n0

	case backquote
	case plus
	case minus
	case equals
	case leftsquarebracket
	case rightsquarebracket
	case backslash
	case semicolon
	case quote
	case comma
	case period
	case slash

	case tab
	case enter
	case space
	case backspace

	case delete
	case insert
	case home
	case end
	case pageup
	case pagedown

	case ctrl
	case shift
	case alt
	case cmd
	case capslock
	case numlockclear

	case up
	case down
	case left
	case right

	case escape

	case F1
	case F2
	case F3
	case F4
	case F5
	case F6
	case F7
	case F8
	case F9
	case F10
	case F11
	case F12

	case printscreen
	case scrollock
	case pause

	// Keypad keys
	case kp0
	case kp1
	case kp2
	case kp3
	case kp4
	case kp5
	case kp6
	case kp7
	case kp8
	case kp9
	case kpPeriod
	case kpPlus
	case kpMinus
	case kpMultiply
	case kpDivide
	case kpEnter
	case kpEquals

	case å
	case ä
	case ö
	case lessThan
}

enum Keyboard: String {
	case en = "en-US"
	case sv = "sv-SE"
}

extension SDLKey {

	var label: String {
		switch self {
		case .a: return "A"
		case .b: return "B"
		case .c: return "C"
		case .d: return "D"
		case .e: return "E"
		case .f: return "F"
		case .g: return "G"
		case .h: return "H"
		case .i: return "I"
		case .j: return "J"
		case .k: return "K"
		case .l: return "L"
		case .m: return "M"
		case .n: return "N"
		case .o: return "O"
		case .p: return "P"
		case .q: return "Q"
		case .r: return "R"
		case .s: return "S"
		case .t: return "T"
		case .u: return "U"
		case .v: return "V"
		case .w: return "W"
		case .x: return "X"
		case .y: return "Y"
		case .z: return "Z"
		case .paragraph: return "§"
		case .n1: return "1"
		case .n2: return "2"
		case .n3: return "3"
		case .n4: return "4"
		case .n5: return "5"
		case .n6: return "6"
		case .n7: return "7"
		case .n8: return "8"
		case .n9: return "9"
		case .n0: return "0"
		case .backquote: return "`"
		case .plus: return "+"
		case .minus: return "-"
		case .equals: return "="
		case .leftsquarebracket: return "["
		case .rightsquarebracket: return "]"
		case .backslash: return "\\"
		case .semicolon: return ":"
		case .quote: return "'"
		case .comma: return ","
		case .period: return "."
		case .slash: return "/"
		case .tab: return "⇥"
		case .enter: return "⏎"
		case .space: return "␣"
		case .backspace: return "⌫"
		case .delete: return "⌦"
		case .insert: return "Insert"
		case .home: return "Home"
		case .end: return "End"
		case .pageup: return "Pgup"
		case .pagedown: return "Pgdown"
		case .ctrl: return "Ctrl"
		case .shift: return "⇧"
		case .alt: return "Alt"
		case .cmd: return "⌘"
		case .capslock: return "⇪"
		case .numlockclear: return "Numclear"
		case .up: return "↑"
		case .down: return "↓"
		case .left: return "←"
		case .right: return "→"
		case .escape: return "Esc"
		case .F1: return "F1"
		case .F2: return "F2"
		case .F3: return "F3"
		case .F4: return "F4"
		case .F5: return "F5"
		case .F6: return "F6"
		case .F7: return "F7"
		case .F8: return "F8"
		case .F9: return "F9"
		case .F10: return "F10"
		case .F11: return "F11"
		case .F12: return "F12"
		case .printscreen: return "Print"
		case .scrollock: return "Lock"
		case .pause: return "Pause"
		case .kp0: return "kp0"
		case .kp1: return "kp1"
		case .kp2: return "kp2"
		case .kp3: return "kp3"
		case .kp4: return "kp4"
		case .kp5: return "kp5"
		case .kp6: return "kp6"
		case .kp7: return "kp7"
		case .kp8: return "kp8"
		case .kp9: return "kp9"
		case .kpPeriod: return "kp."
		case .kpPlus: return "kp+"
		case .kpMinus: return "kp-"
		case .kpMultiply: return "kp*"
		case .kpDivide: return "kp/"
		case .kpEnter: return "kp⏎"
		case .kpEquals: return "kp="
		case .å: return "å"
		case .ä: return "ä"
		case .ö: return "ö"
		case .lessThan: return "<"
		}
	}
}

extension SDLKey {
	func value(for keyboard: Keyboard) -> Int {
		switch keyboard {
		case .en: return enValue
		case .sv: return svValue
		}
	}
}

extension SDLKey {

	var enValue: Int {
		switch self {
		case .a: return 0x00
		case .b: return 0x0b
		case .c: return 0x08
		case .d: return 0x02
		case .e: return 0x0e
		case .f: return 0x03
		case .g: return 0x05
		case .h: return 0x04
		case .i: return 0x22
		case .j: return 0x26
		case .k: return 0x28
		case .l: return 0x25
		case .m: return 0x2e
		case .n: return 0x2d
		case .o: return 0x1f
		case .p: return 0x23
		case .q: return 0x0c
		case .r: return 0x0f
		case .s: return 0x01
		case .t: return 0x11
		case .u: return 0x20
		case .v: return 0x09
		case .w: return 0x0d
		case .x: return 0x07
		case .y: return 0x10
		case .z: return 0x06

		// Numbers above letter area on keyboard
		case .paragraph: return 0x0a
		case .n1: return 0x12
		case .n2: return 0x13
		case .n3: return 0x14
		case .n4: return 0x15
		case .n5: return 0x17
		case .n6: return 0x16
		case .n7: return 0x1a
		case .n8: return 0x1c
		case .n9: return 0x19
		case .n0: return 0x1d

		case .backquote: return 0x32
		case .minus: return 0x1b
		case .equals: return 0x18
		case .leftsquarebracket: return 0x21
		case .rightsquarebracket: return 0x1e
		case .backslash: return 0x2a
		case .semicolon: return 0x29
		case .quote: return 0x27
		case .comma: return 0x2b
		case .period: return 0x2f
		case .slash: return 0x2c

		case .tab: return 0x30
		case .enter: return 0x24
		case .space: return 0x31
		case .backspace: return 0x33

		case .delete: return 0x75
		case .insert: return 0x72
		case .home: return 0x73
		case .end: return 0x77
		case .pageup: return 0x74
		case .pagedown: return 0x79

		case .ctrl: return 0x36
		case .shift: return 0x38
		case .alt: return 0x3a
		case .cmd: return 0x37
		case .capslock: return 0x39
		case .numlockclear: return 0x47

		case .up: return 0x3e
		case .down: return 0x3d
		case .left: return 0x3b
		case .right: return 0x3c

		case .escape: return 0x35

		case .F1: return 0x7a
		case .F2: return 0x78
		case .F3: return 0x63
		case .F4: return 0x76
		case .F5: return 0x60
		case .F6: return 0x61
		case .F7: return 0x62
		case .F8: return 0x64
		case .F9: return 0x65
		case .F10: return 0x6d
		case .F11: return 0x67
		case .F12: return 0x6f

		case .printscreen: return 0x69
		case .scrollock: return 0x6b
		case .pause: return 0x71

		// Keypad keys
		case .kp0: return 0x52
		case .kp1: return 0x53
		case .kp2: return 0x54
		case .kp3: return 0x55
		case .kp4: return 0x56
		case .kp5: return 0x57
		case .kp6: return 0x58
		case .kp7: return 0x59
		case .kp8: return 0x5b
		case .kp9: return 0x5c
		case .kpPeriod: return 0x41
		case .kpPlus: return 0x45
		case .kpMinus: return 0x4e
		case .kpMultiply: return 0x43
		case .kpDivide: return 0x4b
		case .kpEnter: return 0x4c
		case .kpEquals: return 0x51

		default:
			return 0x31 // Space
		}
	}
}

extension SDLKey {

	var svValue: Int { // Should make optional and return nil when key is unsupported
		switch self {
		case .å: return 0x21
		case .ä: return 0x27
		case .ö: return 0x29
		case .plus: return 0x1d
		case .backquote: return 0x18
		case .quote: return 0x2a
		case .minus: return 0x2c
		case .lessThan: return 0x32

		default:
			return enValue
		}
	}
}

// MARK: - UIKeyboardHIDUsage → SDLKey mapping (for physical keyboard interception on DFiP)

import UIKit

extension SDLKey {

	/// Map a `UIKeyboardHIDUsage` value from a physical key press to the
	/// corresponding `SDLKey`.  Returns `nil` for unmapped HID codes.
	init?(fromHIDUsage usage: UIKeyboardHIDUsage) {
		switch usage {
		// Letters
		case .keyboardA: self = .a
		case .keyboardB: self = .b
		case .keyboardC: self = .c
		case .keyboardD: self = .d
		case .keyboardE: self = .e
		case .keyboardF: self = .f
		case .keyboardG: self = .g
		case .keyboardH: self = .h
		case .keyboardI: self = .i
		case .keyboardJ: self = .j
		case .keyboardK: self = .k
		case .keyboardL: self = .l
		case .keyboardM: self = .m
		case .keyboardN: self = .n
		case .keyboardO: self = .o
		case .keyboardP: self = .p
		case .keyboardQ: self = .q
		case .keyboardR: self = .r
		case .keyboardS: self = .s
		case .keyboardT: self = .t
		case .keyboardU: self = .u
		case .keyboardV: self = .v
		case .keyboardW: self = .w
		case .keyboardX: self = .x
		case .keyboardY: self = .y
		case .keyboardZ: self = .z

		// Digits
		case .keyboard0: self = .n0
		case .keyboard1: self = .n1
		case .keyboard2: self = .n2
		case .keyboard3: self = .n3
		case .keyboard4: self = .n4
		case .keyboard5: self = .n5
		case .keyboard6: self = .n6
		case .keyboard7: self = .n7
		case .keyboard8: self = .n8
		case .keyboard9: self = .n9

		// Symbols
		case .keyboardHyphen:              self = .minus
		case .keyboardEqualSign:           self = .equals
		case .keyboardOpenBracket:         self = .leftsquarebracket
		case .keyboardCloseBracket:        self = .rightsquarebracket
		case .keyboardBackslash:           self = .backslash
		case .keyboardSemicolon:           self = .semicolon
		case .keyboardQuote:               self = .quote
		case .keyboardComma:               self = .comma
		case .keyboardPeriod:              self = .period
		case .keyboardSlash:               self = .slash
		case .keyboardGraveAccentAndTilde: self = .backquote
		case .keyboardSpacebar:            self = .space

		// Modifiers
		case .keyboardLeftShift, .keyboardRightShift:     self = .shift
		case .keyboardLeftAlt, .keyboardRightAlt:         self = .alt
		case .keyboardLeftControl, .keyboardRightControl: self = .ctrl
		case .keyboardLeftGUI, .keyboardRightGUI:         self = .cmd
		case .keyboardCapsLock:                           self = .capslock

		// Function keys
		case .keyboardF1:  self = .F1
		case .keyboardF2:  self = .F2
		case .keyboardF3:  self = .F3
		case .keyboardF4:  self = .F4
		case .keyboardF5:  self = .F5
		case .keyboardF6:  self = .F6
		case .keyboardF7:  self = .F7
		case .keyboardF8:  self = .F8
		case .keyboardF9:  self = .F9
		case .keyboardF10: self = .F10
		case .keyboardF11: self = .F11
		case .keyboardF12: self = .F12

		// Navigation
		case .keyboardReturnOrEnter:     self = .enter
		case .keyboardDeleteOrBackspace: self = .backspace
		case .keyboardDeleteForward:     self = .delete
		case .keyboardTab:               self = .tab
		case .keyboardEscape:            self = .escape
		case .keyboardInsert:            self = .insert
		case .keyboardHome:              self = .home
		case .keyboardEnd:               self = .end
		case .keyboardPageUp:            self = .pageup
		case .keyboardPageDown:          self = .pagedown

		// Arrows
		case .keyboardUpArrow:    self = .up
		case .keyboardDownArrow:  self = .down
		case .keyboardLeftArrow:  self = .left
		case .keyboardRightArrow: self = .right

		// Keypad
		case .keypad0:         self = .kp0
		case .keypad1:         self = .kp1
		case .keypad2:         self = .kp2
		case .keypad3:         self = .kp3
		case .keypad4:         self = .kp4
		case .keypad5:         self = .kp5
		case .keypad6:         self = .kp6
		case .keypad7:         self = .kp7
		case .keypad8:         self = .kp8
		case .keypad9:         self = .kp9
		case .keypadPeriod:    self = .kpPeriod
		case .keypadPlus:      self = .kpPlus
		case .keypadHyphen:    self = .kpMinus
		case .keypadAsterisk:  self = .kpMultiply
		case .keypadSlash:     self = .kpDivide
		case .keypadEnter:     self = .kpEnter
		case .keypadEqualSign: self = .kpEquals

		default: return nil
		}
	}
}

@objcMembers
class SDLKeyObjCProxy: NSObject {
	static var cmdValue: NSInteger {
		return SDLKey.cmd.enValue
	}

	static var wValue: NSInteger {
		return SDLKey.w.enValue
	}
}
