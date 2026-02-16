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
