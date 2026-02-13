//
//  HardwareAddress.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-13.
//

struct HardwareAddress: Codable {
	let rawData: Data

	init() {
		var bytes = [UInt8]()
		bytes.append(0x52)
		bytes.append(0x54)
		bytes.append(0x00)
		bytes.append(randomByte())
		bytes.append(randomByte())
		bytes.append(randomByte())

		rawData = Data(bytes)

		print("- created new hardware address \(string)")
	}

	var string: String {
		var str = ""
		for byteIndex in 0..<6 {
			str += String(format: "%02x ", rawData[byteIndex])
		}
		return str
	}
}

private func randomByte() -> UInt8 {
	UInt8.random(in: UInt8.min ... UInt8.max)
}
