//
//  HardwareAddress.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-13.
//

struct HardwareAddress: Codable, Equatable, Hashable {
	let byte0: UInt8
	let byte1: UInt8
	let byte2: UInt8
	let byte3: UInt8
	let byte4: UInt8
	let byte5: UInt8

	init(_ byte0: UInt8, _ byte1: UInt8, _ byte2: UInt8,
		 _ byte3: UInt8, _ byte4: UInt8, _ byte5: UInt8) {
		self.byte0 = byte0
		self.byte1 = byte1
		self.byte2 = byte2
		self.byte3 = byte3
		self.byte4 = byte4
		self.byte5 = byte5
	}

	init?(_ string: String) {
		guard string.count == 17 else {
			return nil
		}

		do {
			byte0 = try UInt8(byteString: string.substring(from: 0, to: 2))
			byte1 = try UInt8(byteString: string.substring(from: 3, to: 5))
			byte2 = try UInt8(byteString: string.substring(from: 6, to: 8))
			byte3 = try UInt8(byteString: string.substring(from: 9, to: 11))
			byte4 = try UInt8(byteString: string.substring(from: 12, to: 14))
			byte5 = try UInt8(byteString: string.substring(from: 15, to: 17))
		} catch {
			return nil
		}
	}

	var string: String {
		String(format: "%02x:%02x:%02x:%02x:%02x:%02x", byte0, byte1, byte2, byte3, byte4, byte5)
	}

	var byteArray: [UInt8] {
		[byte0, byte1, byte2, byte3, byte4, byte5]
	}

	var asData: Data {
		.init(byteArray)
	}

	func matchesHardwareAddress(in data: Data, atOffset offset: Int) -> Bool {
		guard offset + 6 < data.count else {
			return false
		}

		return data[offset] == byte0 &&
		data[offset + 1] == byte1 &&
		data[offset + 2] == byte2 &&
		data[offset + 3] == byte3 &&
		data[offset + 4] == byte4 &&
		data[offset + 5] == byte5
	}

	static func withRandomBytes() -> HardwareAddress {
		return .init(
			0x52,
			0x54,
			0x00,
			randomByte(),
			randomByte(),
			randomByte()
		)
	}

	static func fromData(in data: Data, atOffset offset: Int) -> HardwareAddress? {
		guard offset + 6 <= data.count else {
			return nil
		}

		return .init(data[offset], data[offset + 1], data[offset + 2],
					 data[offset + 3], data[offset + 4], data[offset + 5])
	}
}

@objcMembers
class IpAddress: NSObject {
	let byte0: UInt8
	let byte1: UInt8
	let byte2: UInt8
	let byte3: UInt8

	init(_ byte0: UInt8, _ byte1: UInt8, _ byte2: UInt8, _ byte3: UInt8) {
		self.byte0 = byte0
		self.byte1 = byte1
		self.byte2 = byte2
		self.byte3 = byte3
	}

	var string: String {
		"\(byte0).\(byte1).\(byte2).\(byte3)"
	}

	static func fromData(in data: Data, atOffset offset: Int) -> IpAddress? {
		guard offset + 4 <= data.count else {
			return nil
		}

		return .init(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
	}

	override func isEqual(_ object: Any?) -> Bool {
		guard let object = object as? IpAddress else {
			return false
		}
		
		return byte0 == object.byte0 &&
		byte1 == object.byte1 &&
		byte2 == object.byte2 &&
		byte3 == object.byte3
	}
}

private func randomByte() -> UInt8 {
	UInt8.random(in: UInt8.min ... UInt8.max)
}

private enum ByteDecodeErrors: Error {
	case stringCharWasNotByte
	case byteStringWasIncorrectLength
}

private extension UInt8 {

	init(byteString: String) throws {
		guard byteString.count == 2 else {
			throw ByteDecodeErrors.byteStringWasIncorrectLength
		}

		let firstCharValue = try UInt8(byteChar: byteString[byteString.startIndex]) * 16
		let secondCharValue = try UInt8(byteChar: byteString[byteString.index(byteString.startIndex, offsetBy: 1)])

		self = firstCharValue + secondCharValue
	}

	init(byteChar: Character) throws {
		switch byteChar {
		case "0":
			self = 0
		case "1":
			self = 1
		case "2":
			self = 2
		case "3":
			self = 3
		case "4":
			self = 4
		case "5":
			self = 5
		case "6":
			self = 6
		case "7":
			self = 7
		case "8":
			self = 8
		case "9":
			self = 9
		case "a":
			self = 10
		case "b":
			self = 11
		case "c":
			self = 12
		case "d":
			self = 13
		case "e":
			self = 14
		case "f":
			self = 15
		default:
			throw ByteDecodeErrors.stringCharWasNotByte
		}
	}
}
