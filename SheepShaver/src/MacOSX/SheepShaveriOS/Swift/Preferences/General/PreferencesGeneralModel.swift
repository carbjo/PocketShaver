//
//  PreferencesGeneralModel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import Foundation
import Combine

enum PreferencesGeneralError: Error {
	case couldNotValidateRom
	case fileWithFilenameAleadyExists
	case fileCreationFailedOtherError
	case fileCreationInvalidSize
	case fileImportWrongSuffix
}

enum PreferencesGeneralRamSetting: Int, CaseIterable {
	case n32
	case n64
	case n128
	case n256
	case n512 // Maximum that Mac OS 9.0.4 recognizes
}

class PreferencesGeneralModel {

	private let changeSubject: PassthroughSubject<PreferencesChange, Never>

	private let romFilename = PreferencesModel.romFilename
	private let tmpRomFilename = ".tmp_rom"

	var isDisplayingRomFileMissingError = false
	var isDisplayingNoDiskFilesError = false

	var hasRomFile: Bool {
		let romUrl = FileManager.documentUrl.appendingPathComponent(romFilename)
		return FileManager.default.fileExists(atPath: romUrl.path)
	}

	@MainActor
	var hasDskFile: Bool {
		DiskManager.shared.diskArray.contains(where: { $0.path.pathExtension == "dsk" })
	}

	@MainActor
	var numberOfDisks: Int {
		DiskManager.shared.diskArray.count
	}

	var ramSetting: PreferencesGeneralRamSetting {
		get {
			PreferencesGeneralRamSetting.current
		}
		set {
			PreferencesGeneralRamSetting.current = newValue
			
			changeSubject.send(.changeRequiringRestartMade)
		}
	}

	var isIPadMouseEnabled: Bool {
		get {
			objc_findBool("ipadmousepassthrough")
		}
		set {
			objc_replaceBool("ipadmousepassthrough", newValue)
			objc_update_sdl_ipad_mouse_setting()
		}
	}

	init(changeSubject: PassthroughSubject<PreferencesChange, Never>) {
		self.changeSubject = changeSubject
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

				let isRomValid = validateROM(tmpURL.path)

				if isRomValid {
					var destURL = tmpURL.deletingLastPathComponent()
					destURL = destURL.appendingPathComponent(romFilename)
					do {
						try FileManager.default.moveItem(at: tmpURL, to: destURL)
						print("all good")
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
			throw PreferencesGeneralError.couldNotValidateRom
		}
	}

	func forceSelectTmpRom() throws {
		let tmpURL = FileManager.documentUrl.appendingPathComponent(tmpRomFilename)
		var destURL = tmpURL.deletingLastPathComponent()
		destURL = destURL.appendingPathComponent(romFilename)
		do {
			try FileManager.default.moveItem(at: tmpURL, to: destURL)
			print("all good")
		} catch {
			print("-- write fail \(error)")
		}
	}

	@MainActor
	func createNewDisk(name: String, sizeInMb: Int) throws -> DiskDataChange {
		guard sizeInMb > 0 else {
			throw PreferencesGeneralError.fileCreationInvalidSize
		}

		let fixedName = name.hasSuffix(".dsk") ? name : "\(name).dsk"

		let path = FileManager.documentUrl.appendingPathComponent(fixedName).path
		guard !FileManager.default.fileExists(atPath: path) else {
			throw PreferencesGeneralError.fileWithFilenameAleadyExists
		}

		let success = objc_createDiskWithName(fixedName, sizeInMb)
		if !success {
			throw PreferencesGeneralError.fileCreationFailedOtherError
		}

		return DiskManager.shared.loadDiskData()
	}

	@MainActor
	func didSelectFileImport(url: URL) async throws -> DiskDataChange {
		guard url.path.hasSuffixMatchingSuffixes(in: DiskManager.supportedFileExtensions) else {
			throw PreferencesGeneralError.fileImportWrongSuffix
		}

		let docsUrl = FileManager.documentUrl
		let destUrl = docsUrl.appendingPathComponent(url.lastPathComponent)

		if FileManager.default.fileExists(atPath: destUrl.path) {
			throw PreferencesGeneralError.fileWithFilenameAleadyExists
		}

		var error: NSError?
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			NSFileCoordinator().coordinate(readingItemAt: url, error: &error) { srcURL in
				do {
					try FileManager.default.moveItem(at: srcURL, to: destUrl)
					continuation.resume(returning: ())
				} catch {
					print("-- write fail \(error)")
					continuation.resume(throwing: error)
				}
			}
		}

		return DiskManager.shared.loadDiskData()
	}

	@MainActor
	func didSelectReload() async throws -> DiskDataChange {
		DiskManager.shared.loadDiskData()
	}

	@MainActor
	func disk(forIndex index: Int) -> Disk {
		DiskManager.shared.diskArray[index]
	}

	@MainActor
	func disk(forFilename filename: String) -> Disk? {
		DiskManager.shared.diskArray.first(where: { $0.filename == filename })
	}

	@MainActor
	func setDiskEnabled(filename: String, isEnabled: Bool) {
		guard var disk = disk(forFilename: filename) else {
			return
		}

		disk.isEnabled = isEnabled
		DiskManager.shared.set(disk)
	}

	@MainActor
	func setDiskAsCdRom(filename: String, isCdRom: Bool) {
		guard var disk = disk(forFilename: filename) else {
			return
		}

		disk.isCdRom = isCdRom
		DiskManager.shared.set(disk)
	}
}

extension PreferencesGeneralRamSetting {

	static var current: Self {
		get {
			let persistedRamInMbValue = objc_findInt32("ramsize")
			return .init(ramInMB: persistedRamInMbValue)
		}
		set {
			objc_replaceInt32("ramsize", newValue.ramInMB)
		}
	}

	var ramInMB: Int {
		switch self {
		case .n32: 32
		case .n64: 64
		case .n128: 128
		case .n256: 256
		case .n512: 512
		}
	}

	var label: String {
		"\(ramInMB) MB"
	}

	init(ramInMB: Int) {
		if ramInMB >= Self.n512.ramInMB {
			self = .n512
		} else if ramInMB >= Self.n256.ramInMB {
			self = .n256
		} else if ramInMB >= Self.n128.ramInMB {
			self = .n128
		} else if ramInMB >= Self.n64.ramInMB {
			self = .n64
		} else {
			self = .n32
		}
	}
}
