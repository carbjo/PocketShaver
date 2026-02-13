//
//  NetworkSettings.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-13.
//

import Foundation

class NetworkSettings: Codable {
	let hardwareAddress: HardwareAddress
	let des: Bool

	@MainActor
	init() {
		hardwareAddress = HardwareAddress()
		des = false

		updateCachedResponses()
	}

	@MainActor
	static var current: NetworkSettings = {
		if let data = Storage.shared.load(from: .network),
		   let settings = try? JSONDecoder().decode(NetworkSettings.self, from: data) {
			settings.updateCachedResponses()
			return settings
		}

		return NetworkSettings()
	}()

	@MainActor
	static func initIfNeeded() {
		self.current.saveAsCurrent()
	}

	@MainActor
	private func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .network)
		} catch {}
	}

	@MainActor
	func updateCachedResponses() {
		NetworkSettingsCachedSettings.hardwareAddress = hardwareAddress
		print("- did read hardwareAddress \(hardwareAddress.string)")
	}
}

class NetworkSettingsCachedSettings {
	nonisolated(unsafe) static var hardwareAddress:
	HardwareAddress?
}

@objcMembers
class NetworkSettingsObjCProxy: NSObject {
	static func getHardwareAddressData() -> NSData? {
		guard let hardwareAddress = NetworkSettingsCachedSettings.hardwareAddress else {
			return nil
		}
		return NSData(data: hardwareAddress.rawData)
	}
}
