//
//  NetworkSettings.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-13.
//

import UIKit

enum NetworkServiceType: Codable {
	case slirp
	case bonjour
}

class NetworkSettings: Codable {
	private(set) var serviceType: NetworkServiceType
	private(set) var bonjourName: String
	private(set) var bonjourRole: BonjourManager.Role
	private(set) var hasDismissedOsWarning: Bool
	private(set) var reportIpAddressAssignment: Bool
	private(set) var autojoinHardwareAddresses: Set<String>
	let hardwareAddress: HardwareAddress // This device as a Classic Mac
	let routerHardwareAddress: HardwareAddress // This device as a router

	@MainActor
	init() {
		serviceType = .slirp
		bonjourName = UIDevice.modelName
		bonjourRole = .host
		hasDismissedOsWarning = false
		reportIpAddressAssignment = true
		autojoinHardwareAddresses = []
		hardwareAddress = HardwareAddress.withRandomBytes()
		routerHardwareAddress = HardwareAddress.withRandomBytes()

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
	func set(serviceType: NetworkServiceType) {
		guard self.serviceType != serviceType else {
			return
		}

		self.serviceType = serviceType

		updateCachedResponses()
		saveAsCurrent()

		switch serviceType {
		case .slirp:
			BonjourManager.shared.stop()
		case .bonjour:
			BonjourManager.shared.start()
		}
	}

	@MainActor
	func set(bonjourName: String) {
		self.bonjourName = bonjourName

		saveAsCurrent()
	}

	@MainActor
	func set(bonjourRole: BonjourManager.Role) {
		self.bonjourRole = bonjourRole

		saveAsCurrent()
	}

	@MainActor
	func set(hasDismissedOsWarning: Bool) {
		self.hasDismissedOsWarning = hasDismissedOsWarning

		saveAsCurrent()
	}

	@MainActor
	func set(reportIpAddressAssignment: Bool) {
		self.reportIpAddressAssignment = reportIpAddressAssignment

		saveAsCurrent()
	}

	@MainActor
	func set(autojoinHardwareAddresses: Set<String>) {
		self.autojoinHardwareAddresses = autojoinHardwareAddresses

		saveAsCurrent()
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
		NetworkSettingsCachedSettings.serviceType = serviceType
		NetworkSettingsCachedSettings.hardwareAddress = hardwareAddress
		NetworkSettingsCachedSettings.routerHardwareAddress = routerHardwareAddress
	}
}

class NetworkSettingsCachedSettings {
	nonisolated(unsafe) static var serviceType: NetworkServiceType = .slirp
	nonisolated(unsafe) static var hardwareAddress:
	HardwareAddress?
	nonisolated(unsafe) static var routerHardwareAddress:
	HardwareAddress?
}

@objcMembers
class NetworkSettingsObjCProxy: NSObject {
	static func getNetworkServiceTypeIsBonjour() -> Bool {
		return NetworkSettingsCachedSettings.serviceType == .bonjour
	}

	static func getHardwareAddressData() -> NSData? {
		guard let hardwareAddress = NetworkSettingsCachedSettings.hardwareAddress else {
			return nil
		}
		return NSData(data: hardwareAddress.asData)
	}

	static func getRouterHardwareAddressData() -> NSData? {
		guard let routerHardwareAddress = NetworkSettingsCachedSettings.routerHardwareAddress else {
			return nil
		}
		return NSData(data: routerHardwareAddress.asData)
	}

	static func reportGotIpAddress(_ ipAddress: IpAddress) {
		NotificationCenter.default.post(name: LocalNotifications.gotIpAddress, object: ipAddress)
	}
}
