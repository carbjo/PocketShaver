//
//  RomManager.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-15.
//

import Foundation

enum RomError: Error {
	case romMissingOnDisk
	case couldNotValidateRom
}

enum RomValidationResult {
	case success
	case incompatibleRom(NewWorldRomVersion)
	case invalidFile
	case error(Error)
}

class RomManager {
	@MainActor
	static let shared = RomManager()

	private let extractedRomUrl = Storage.urlForDocumentFile(filename: ".extracted_rom")
	private let tmpRomUrl = Storage.urlForDocumentFile(filename: ".tmp_rom")
	let romUrl = Storage.urlForDocumentFile(filename: ".rom")

	var hasRomFile: Bool {
		return FileManager.default.fileExists(atPath: romUrl.path)
	}

	var currentRomFileType: RomType {
		return validateROMType(romUrl.path)
	}

	var currentRomFileVersion: NewWorldRomVersion? {
		guard let md5Hash = try? Storage.getFileMd5Hash(romUrl) else {
			return nil
		}
		return NewWorldRomVersion(md5hash: md5Hash)
	}

	func didSelectMacOsInstallDiskCandidate(url: URL) async -> RomValidationResult {
		let success = DiskFileExtractor.extractRom(fromDiskUrl: url, to: extractedRomUrl)

		guard success else {
			return .invalidFile
		}

		return await didSelectRomCandidate(url: extractedRomUrl)
	}

	private func didSelectRomCandidate(url: URL) async -> RomValidationResult {
		var error: NSError?
		return await withCheckedContinuation { continuation in
			NSFileCoordinator().coordinate(readingItemAt: url, error: &error) { srcURL in
				do {
					if FileManager.default.fileExists(atPath: tmpRomUrl.path) {
						try FileManager.default.removeItem(at: tmpRomUrl)
					}
					try FileManager.default.moveItem(at: srcURL, to: tmpRomUrl)
				} catch {
					continuation.resume(returning: RomValidationResult.error(error))
				}

				guard let md5Hash = try? Storage.getFileMd5Hash(tmpRomUrl),
					  let newWorldRomVersion = NewWorldRomVersion(md5hash: md5Hash) else {
					continuation.resume(returning: RomValidationResult.invalidFile)
					return
				}

				guard newWorldRomVersion.isBootstrapCompatible else {
					continuation.resume(returning: RomValidationResult.incompatibleRom(newWorldRomVersion))
					return
				}

				do {
					if FileManager.default.fileExists(atPath: romUrl.path) {
						try FileManager.default.removeItem(at: romUrl)
					}
					try FileManager.default.moveItem(at: tmpRomUrl, to: romUrl)
					continuation.resume(returning: RomValidationResult.success)
				} catch {
					continuation.resume(returning: RomValidationResult.error(error))
				}
			}
		}
	}
}

extension RomType{
	var description: String {
		switch self {
		case .invalid:
			"Unverified ROM"
		case .oldWorldTnt:
			"Old world ROM type 'TNT' (PowerMac 7200, 7300, 7500, 7600, 8500, 8600, 9500, 9600 versions 1 and 2)"
		case .oldWorldAlchemy:
			"Old world ROM type 'Alchemy' (PowerMac/Performa 6400)"
		case .oldWorldZanzibar:
			"Old world ROM type 'Zanzibar' (PowerMac 4400)"
		case .oldWorldGazelle:
			"Old world ROM type 'Gazelle' (PowerMac 6500)"
		case .oldWorldGossamer:
			"Old world ROM type 'Gossamer' (PowerMac G3)"
		case .newWorld:
			"New world ROM"
		default:
			fatalError()
		}
	}
}

enum NewWorldRomVersion: String, Codable {
	case v110
	case v112
	case v115
	case v120
	case v121
	case v140
	case v160
	case v171
	case v181
	case v231
	case v251
	case v300
	case v311
	case v321
	case v350
	case v360
	case v370
	case v380
	case v390
	case v461
	case v491
	case v521
	case v531
	case v551
	case v610
	case v671
	case v701f1
	case v751
	case v781
	case v791
	case v800
	case v831
	case v840
	case v861
	case v870
	case v880
	case v891
	case v901
	case v911
	case v921
	case v921b
	case v931
	case v951
	case v961
	case v971
	case v981
	case v1011
	case v1021

	init?(md5hash: String) {
		switch md5hash {
		case "e0fc03faa589ee066c411b4603e0ac89": self = .v110
		case "17b134a0d837518498c06579aa4ff053": self = .v112
		case "133ef27acf2f360341870f212c7207d7": self = .v115
		case "3756f699eadaabf0abf8d3322bed70e5": self = .v120
		case "eca81482d307aa5d811aed9e825b1599": self = .v121
		case "1bf445c27513dba473cca51219184b07": self = .v140
		case "be65e1c4f04a3f2881d6e8de47d66454": self = .v160
		case "dd26176882d14c39219aca668d7e97cb": self = .v171
		case "02350bfe27c4dea1d2c13008efb3a036": self = .v181
		case "722fe6481b4d5c04e005e5ba000eb00e": self = .v231
		case "4bb3e019c5d7bfd5f3a296c13ad7f08f": self = .v251
		case "d387acd4503ce24e941f1131433bbc0f": self = .v300
		case "9e990cde6c30a3ab916c1390b29786c7": self = .v311
		case "bbfbb4c884741dd75e03f3de67bf9370": self = .v321
		case "386ea1c81730f9b06bfc2e6c36be8d59": self = .v350
		case "71d3bd057139e3b0fb152ab905a12d2a": self = .v360
		case "8f388ccf6f96c58bda5ae83d207ca85a": self = .v370
		case "3f182e059a60546f93114ed3798d5751": self = .v380
		case "91313ac92c9a91ce03a34990e710c3a1": self = .v390
		case "bf9f186ba2dcaaa0bc2b9762a4bf0c4a": self = .v461
		case "f66558f3c9416a6bb8d062c0343b3e69": self = .v491
		case "52ea9e30d59796ce8c4822eeeb0f543e": self = .v521
		case "ea03ebbfdff4febbff3a667deb921996": self = .v531
		case "ba420e82e0c69405299d6d72dc9dd735": self = .v551
		case "5e9a959067e1261d19427f983dd10162": self = .v610
		case "19d596fc3028612edb1553e4d2e0f345": self = .v671
		case "8b2e93bee15642964b45883745001af9": self = .v701f1
		case "14cd0b3d8a7e022620b815f4983269ce": self = .v751
		case "28a08b4d5d5e4ab113c5fc1b25955a7c": self = .v781
		case "1486fe0b293e23125c00b9209435365c": self = .v791
		case "8c91510b578bdfce7c5e77822f405478": self = .v800
		case "6fc4679862b2106055b1ce301822ffeb": self = .v831
		case "f97d43821fea307578697a64b1705f8b": self = .v840
		case "d81574f35e97a658eab99df52529251e": self = .v861
		case "97db5e70d05ab7568d8a1f7ddd3b901a": self = .v870
		case "fed4f785146d859d3c1b7fca42c07d9a": self = .v880
		case "65e3bc1fee886bbe1aabe0faa4b8cda2": self = .v891
		case "66210b4f71df8a580eb175f52b9d0f88": self = .v901
		case "c5f7aaaf28d7c7eac746e9f26b183816": self = .v911
		case "13889037360fe1567c7e7f89807453b0": self = .v921
		case "d69b40cf8fe0fa00c98c75dd41e888d4": self = .v921b
		case "e0a643f2cb441955c46b098c8fd1b21f": self = .v931
		case "b36a5f1d814291a22457adfa2331b379": self = .v951
		case "3c08de22aeaa7d7fdb14df848fbaa90d": self = .v961
		case "e74f8c6bb52a641b856d821be7a65275": self = .v971
		case "4e8d07f8e0d4af6d06336688013972c3": self = .v981
		case "1fb3de4d87889c26068dd88779dc20e2": self = .v1011
		case "48fd7a428aaebeaec2dea347795a4910": self = .v1021
		default:
			return nil
		}
	}

	var isBootstrapCompatible: Bool {
		switch self {
		case .v110, .v112, .v115, .v120, .v121, .v140, .v160:
			return true
		default:
			return false
		}
	}

	var isInstallCompatible: Bool {
		switch self {
		case .v110, .v112, .v115, .v120, .v121, .v140, .v160,
				.v181, .v231, .v251, .v300, .v311, .v321, .v350, .v360,
				.v370, .v380, .v390, .v461, .v491, .v521, .v531, .v551:
			return true
		default:
			return false
		}
	}

	var description: String {
		switch self {
		case .v110: return "Mac OS 8.1 bundled on iMac, Rev A"
		case .v112: return "Mac OS 8.5 Retail CD, iMac Update 1.0"
		case .v115: return "Mac OS 8.5 bundled on iMac, Rev B"
		case .v120: return "Mac OS 8.5.1 bundled on Power Macintosh G3 (Blue and White), Macintosh Server G3 (Blue and White)"
		case .v121: return "Mac OS 8.5.1 bundled on Colors iMac 266 MHz"
		case .v140: return "Mac OS 8.6 Retail CD, bundled on Colors iMac 333 MHz, Power Macintosh G3 (Blue and White)"
		case .v160: return "Mac OS 8.6 bundled on PowerBook G3 Series 8.6"
		case .v171: return "Mac OS 8.6 bundled on Power Mac G4 (PCI)"
		case .v181: return "Mac OS 8.6 Power Mac G4 ROM 1.8.1 Update CD"
		case .v231: return "Mac OS 8.6 bundled on iMac (Slot Loading), iBook"
		case .v251: return "Mac OS 8.6 bundled on Power Mac G4 (AGP)"
		case .v300: return "Mac OS 9.0 Retail CD, bundled on Power Macintosh G3 (Blue and White), iMac, PowerBook G3 Bronze"
		case .v311: return "Mac OS 9.0 bundled on iBook, Power Mac G4 (AGP), iMac (Slot-Loading)"
		case .v321: return "Mac OS 9.0Z bundled on Power Mac G4 (AGP)"
		case .v350: return "Mac OS 9.0.2 bundled on Power Mac G4 (AGP), iBook, PowerBook (FireWire)"
		case .v360: return "Mac OS 9.0.3 bundled on iMac (Slot Loading)"
		case .v370: return "Mac OS 9.0.4 Retail/Software Update CD, bundled on PowerBook (FireWire) (Summer 2000)"
		case .v380: return "Mac OS 9.0.4 Ethernet Update 1.0"
		case .v390: return "Mac OS 9.0.4 Internal Edition"
		case .v461: return "Mac OS 9.0.4 bundled on iMac (Summer 2000), Power Mac G4 (Summer 2000)"
		case .v491: return "Mac OS 9.0.4 bundled on Power Mac G4 MP (Summer 2000), Power Mac G4 (Gigabit Ethernet)"
		case .v521: return "Mac OS 9.0.4 bundled on Power Mac G4 Cube"
		case .v531: return "Mac OS 9.0.4 bundled on iBook (Summer 2000)"
		case .v551: return "Mac OS 9.0.4 International bundled on Power Mac G4 Cube"
		case .v610: return "Mac OS 9.1 Update CD"
		case .v671: return "Mac OS 9.1 bundled on Power Mac G4 (Digital Audio)"
		case .v701f1: return "Mac OS 9.1 (2001-02 MacTest Pro G4 CD)"
		case .v751: return "Mac OS 9.1 bundled on iMac (Early 2001), iMac (Summer 2001), PowerBook G4"
		case .v781: return "Mac OS 9.1 bundled on iBook (Dual USB)"
		case .v791: return "Mac OS 9.1 bundled on PowerBook G4"
		case .v800: return "Mac OS 9.2 Install CD for Power Mac G4"
		case .v831: return "Mac OS 9.2 bundled on iMac (Summer 2001), Power Mac G4 (QuickSilver)"
		case .v840: return "Mac OS 9.2.1 Retail CD, bundled on Power Mac G4 (QuickSilver)"
		case .v861: return "Mac OS 9.2.1 bundled on iBook G3 (Late 2001)"
		case .v870: return "Mac OS 9.2.2 Update SMI"
		case .v880: return "Mac OS 9.2.2 Update CD"
		case .v891: return "Mac OS 9.2.2 bundled on iBook"
		case .v901: return "Mac OS 9.2.2 bundled on iMac (Summer 2001), iMac (Flat Panel), Power Mac G4 (QuickSilver 2002)"
		case .v911: return "Mac OS 9.2.2 bundled on iMac G4"
		case .v921: return "Mac OS 9.2.2 bundled on eMac"
		case .v921b: return "Mac OS 9.2.2 bundled on eMac v1"
		case .v931: return "Mac OS 9.2.2 bundled on PowerBook G4"
		case .v951: return "Mac OS 9.2.2 bundled on iMac (17-inch Flat Panel)"
		case .v961: return "Mac OS 9.2.2 Update CD (CPU Software 5.4)"
		case .v971: return "Mac OS 9.2.2 bundled on PowerBook (Titanium)"
		case .v981: return "Mac OS 9.2.2 (691-4571-A MacTest Pro G4 CD)"
		case .v1011: return "Mac OS 9.2.2 bundled on eMac 800MHz"
		case .v1021: return "Mac OS 9.2.2 Retail International CD"
		}
	}

	var osString: String {
		switch self {
		case .v110:
			return "8.1"
		case .v112, .v115:
			return "8.5"
		case .v120, .v121:
			return "8.5.1"
		case .v140, .v160, .v171, .v181, .v231, .v251:
			return "8.6"
		case .v300, .v311:
			return "9.0"
		case .v321:
			return "9.0Z"
		case .v350:
			return "9.0.2"
		case .v360:
			return "9.0.3"
		case .v370, .v380, .v390, .v461, .v491, .v521, .v531, .v551:
			return "9.0.4"
		case .v610, .v671, .v701f1, .v751, .v781, .v791:
			return "9.1"
		case .v800, .v831:
			return "9.2"
		case .v840, .v861:
			return "9.2.1"
		case .v870, .v880, .v891, .v901, .v911, .v921, .v921b, .v931,
				.v951, .v961, .v971, .v981, .v1011, .v1021:
			return "9.2.2"
		}
	}
}
