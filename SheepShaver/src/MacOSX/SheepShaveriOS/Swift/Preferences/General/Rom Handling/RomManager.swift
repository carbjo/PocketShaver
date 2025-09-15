//
//  RomManager.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-15.
//

import Foundation

enum RomError: Error {
	case couldNotValidateRom
}

class RomManager {
	@MainActor
	static let shared = RomManager()

	static let romFilename = "Mac OS ROM"
	private let tmpRomFilename = ".tmp_rom"

	var hasRomFile: Bool {
		let romUrl = FileManager.documentUrl.appendingPathComponent(Self.romFilename)
		return FileManager.default.fileExists(atPath: romUrl.path)
	}

	var currentRomFileType: RomType {
		let romUrl = FileManager.documentUrl.appendingPathComponent(Self.romFilename)
		return validateROM(romUrl.path)
	}

	func didSelectRomCandidate(url: URL) async throws {
		var error: NSError?
		let success = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
			NSFileCoordinator().coordinate(readingItemAt: url, error: &error) { srcURL in

				let docsUrl = FileManager.documentUrl

				let tmpURL = docsUrl.appendingPathComponent(tmpRomFilename)

				do {
					if FileManager.default.fileExists(atPath: tmpURL.path) {
						try FileManager.default.removeItem(at: tmpURL)
					}
					try FileManager.default.moveItem(at: srcURL, to: tmpURL)
				} catch {
					print("-- write fail \(error)")
					continuation.resume(throwing: error)
				}

				let isRomValid = validateROM(tmpURL.path) != .invalid

				if isRomValid {
					var destURL = tmpURL.deletingLastPathComponent()
					destURL = destURL.appendingPathComponent(Self.romFilename)
					do {
						if FileManager.default.fileExists(atPath: destURL.path) {
							try FileManager.default.removeItem(at: destURL)
						}
						try FileManager.default.moveItem(at: tmpURL, to: destURL)
						continuation.resume(returning: true)
					} catch {
						print("-- write fail \(error)")
						continuation.resume(throwing: error)
					}
				} else {
					continuation.resume(returning: false)
				}
			}
		}

		if !success {
			throw RomError.couldNotValidateRom
		}
	}

	func forceSelectTmpRom() throws {
		let tmpURL = FileManager.documentUrl.appendingPathComponent(tmpRomFilename)
		var destURL = tmpURL.deletingLastPathComponent()
		destURL = destURL.appendingPathComponent(Self.romFilename)
		do {
			if FileManager.default.fileExists(atPath: destURL.path) {
				try FileManager.default.removeItem(at: destURL)
			}
			try FileManager.default.moveItem(at: tmpURL, to: destURL)
		} catch {
			print("-- write fail \(error)")
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
