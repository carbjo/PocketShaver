//
//  SDLKey.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-05.
//

@objc
public enum SDLKey: Int {
	case a = 0x00
	case b = 0x0b
	case c = 0x08
	case d = 0x02
	case e = 0x0e
	case f = 0x03
	case g = 0x05
	case h = 0x04
	case i = 0x22
	case j = 0x26
	case k = 0x28
	case l = 0x25
	case m = 0x2e
	case n = 0x2d
	case o = 0x1f
	case p = 0x23
	case q = 0x0c
	case r = 0x0f
	case s = 0x01
	case t = 0x11
	case u = 0x20
	case v = 0x09
	case w = 0x0d
	case x = 0x07
	case y = 0x10
	case z = 0x06

	// Numbers above letter area on keyboard
	case n1 = 0x12
	case n2 = 0x13
	case n3 = 0x14
	case n4 = 0x15
	case n5 = 0x17
	case n6 = 0x16
	case n7 = 0x1a
	case n8 = 0x1c
	case n9 = 0x19
	case n0 = 0x1d

	case backquote = 0x32
	case minus = 0x1b
	case equals = 0x18
	case leftbracket = 0x21
	case rightbracket = 0x1e
	case backslash = 0x2a
	case semicolon = 0x29
	case quote = 0x27
	case comma = 0x2b
	case period = 0x2f
	case slash = 0x2c

	case tab = 0x30
	case `return` = 0x24
	case space = 0x31
	case backspace = 0x33

	case delete = 0x75
	case insert = 0x72
	case home = 0x73
	case end = 0x77
	case pageup = 0x74
	case pagedown = 0x79

	case ctrl = 0x36
	case shift = 0x38
	case alt = 0x3a
	case cmd = 0x37
	case capslock = 0x39
	case numlockclear = 0x47

	case up = 0x3e
	case down = 0x3d
	case left = 0x3b
	case right = 0x3c

	case escape = 0x35

	case F1 = 0x7a
	case F2 = 0x78
	case F3 = 0x63
	case F4 = 0x76
	case F5 = 0x60
	case F6 = 0x61
	case F7 = 0x62
	case F8 = 0x64
	case F9 = 0x65
	case F10 = 0x6d
	case F11 = 0x67
	case F12 = 0x6f

	case printscreen = 0x69
	case scrollock = 0x6b
	case pause = 0x71

	// Keypad keys
	case kp0 = 0x52
	case kp1 = 0x53
	case kp2 = 0x54
	case kp3 = 0x55
	case kp4 = 0x56
	case kp5 = 0x57
	case kp6 = 0x58
	case kp7 = 0x59
	case kp8 = 0x5b
	case kp9 = 0x5c
	case kpPeriod = 0x41
	case kpPlus = 0x45
	case kpMinus = 0x4e
	case kpMultiply = 0x43
	case kpDivide = 0x4b
	case kpEnter = 0x4c
	case kpEquals = 0x51
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
		case .minus: return "-"
		case .equals: return "="
		case .leftbracket: return "["
		case .rightbracket: return "]"
		case .backslash: return "\\"
		case .semicolon: return ":"
		case .quote: return "'"
		case .comma: return ","
		case .period: return "."
		case .slash: return "/"
		case .tab: return "⇥"
		case .`return`: return "⏎"
		case .space: return "␣"
		case .backspace: return "⌫"
		case .delete: return "⌦"
		case .insert: return "INSERT"
		case .home: return "HOME"
		case .end: return "END"
		case .pageup: return "PGUP"
		case .pagedown: return "PGDOWN"
		case .ctrl: return "CTRL"
		case .shift: return "⇧"
		case .alt: return "ALT"
		case .cmd: return "⌘"
		case .capslock: return "⇪"
		case .numlockclear: return "NUMCLEAR"
		case .up: return "↑"
		case .down: return "↓"
		case .left: return "←"
		case .right: return "→"
		case .escape: return "ESC"
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
		case .printscreen: return "PRINT"
		case .scrollock: return "LOCK"
		case .pause: return "PAUSE"
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
		}
	}
}
