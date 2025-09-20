//
//  PreferencesGeneralModel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import Foundation
import Combine

enum PreferencesGeneralError: Error {
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

	var isDisplayingRomFileMissingError = false
	var isDisplayingNoDiskFilesError = false

	@MainActor
	var hasDismissedSetupInstructions: Bool {
		MiscellaneousSettings.current.hasDismissedSetupInstructions
	}

	@MainActor
	var hasRomFile: Bool {
		RomManager.shared.hasRomFile
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
			
			changeSubject.send(.changeRequiringRestartBeforeBootMade)
		}
	}

	var isIPadMouseEnabled: Bool {
		get {
			objc_findBool("ipadmousepassthrough")
		}
		set {
			objc_replaceBool("ipadmousepassthrough", newValue)
			objc_update_sdl_ipad_mouse_setting()

			changeSubject.send(.changeRequiringRestartAfterBootMade)
		}
	}

	init(changeSubject: PassthroughSubject<PreferencesChange, Never>) {
		self.changeSubject = changeSubject
	}

	@MainActor
	func reportHasDismissedSetupInstructions() {
		MiscellaneousSettings.current.reportHasDismissedSetupInstructions()
	}

	@MainActor
	func didSelectRomCandidate(url: URL) async throws {
		try await RomManager.shared.didSelectRomCandidate(url: url)
		changeSubject.send(.changeRequiringRestartAfterBootMade)
	}

	@MainActor
	func forceSelectTmpRom() throws {
		try RomManager.shared.forceSelectTmpRom()
		changeSubject.send(.changeRequiringRestartAfterBootMade)
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
		guard url.path.lowercased().hasSuffixMatchingSuffixes(in: DiskManager.supportedFileExtensions) else {
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

		changeSubject.send(.changeRequiringRestartAfterBootMade)
	}

	@MainActor
	func setDiskAsCdRom(filename: String, isCdRom: Bool) {
		guard var disk = disk(forFilename: filename) else {
			return
		}

		disk.isCdRom = isCdRom
		DiskManager.shared.set(disk)

		changeSubject.send(.changeRequiringRestartAfterBootMade)
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
