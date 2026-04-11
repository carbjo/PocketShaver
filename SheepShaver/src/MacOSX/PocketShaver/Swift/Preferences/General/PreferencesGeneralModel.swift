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
	case n512 // Maximum that Mac OS 9.0.4 recognizes (for now)
}

class PreferencesGeneralModel {
	struct DiskSelectionChangeResult {
		let prevIndex: Int
		let newIndex: Int
		let willBootFromCDChanged: Bool
	}

	struct DiskEntry: Hashable {
		let index: Int
		let filename: String
		let type: DiskType
	}

	let mode: PreferencesLaunchMode

	@MainActor
	private var miscSettings: MiscellaneousSettings {
		.current
	}

	let changeSubject: PassthroughSubject<PreferencesChange, Never>

	var isDisplayingRomFileMissingError = false
	var isDisplayingNoDiskFilesError = false

	@MainActor
	var hasDismissedSetupInstructions: Bool {
		InformationConsumption.current.hasDismissedSetupInstructions
	}

	@MainActor
	var shouldDisplayBootstrapSection = !RomManager.shared.hasRomFile

	@MainActor
	var hasDskFile: Bool {
		DiskManager.shared.diskArray.contains(where: { $0.filename.pathExtension == "dsk" })
	}

	@MainActor
	var numberOfDisks: Int {
		DiskManager.shared.diskArray.count
	}

	var supportedFileExtensions: [String] {
		DiskManager.supportedFileExtensions
	}

	@MainActor
	var isIPadMouseEnabled: Bool {
		get {
			miscSettings.iPadMousePassthrough
		}
		set {
			miscSettings.set(iPadMousePassthrough: newValue)
			objc_update_sdl_ipad_mouse_setting(newValue)

			changeSubject.send(.iPadMouseEnabledChanged)
		}
	}

	@MainActor
	var gamepadConfigs: [GamepadConfig] {
		GamepadManager.shared.allConfigs
	}

	@MainActor
	var twoFingerSteeringSetting: TwoFingerSteeringSetting {
		get {
			miscSettings.twoFingerSteeringSetting
		}
		set {
			if twoFingerSteeringSetting == .off,
			   newValue != .off {
				miscSettings.set(relativeMouseModeClickGestureSetting: .secondFingerClick)
			} else if twoFingerSteeringSetting != .off,
					  newValue == .off,
					  miscSettings.relativeMouseModeClickGestureSetting == .secondFingerClick {
				miscSettings.set(relativeMouseModeClickGestureSetting: .tap)
			}

			miscSettings.set(twoFingerSteeringSetting: newValue)
		}
	}

	@MainActor
	var rightClickSetting: RightClickSetting {
		get {
			miscSettings.rightClickSetting
		}
		set {
			miscSettings.set(rightClickSetting: newValue)
		}
	}

	@MainActor
	var keyboardAutoOffsetSetting: KeyboardAutoOffsetSetting {
		get {
			miscSettings.keyboardAutoOffsetSetting
		}
		set {
			miscSettings.set(keyboardAutoOffsetSetting: newValue)
		}
	}

	@MainActor
	var audioEnabled: Bool {
		get {
			miscSettings.audioEnabled
		}
		set {
			let previousValue = miscSettings.audioEnabled
			miscSettings.set(audioEnabled: newValue)

			if mode == .duringEmulation,
				newValue != previousValue {
				objc_update_audio_enabled_setting(newValue)
			}
		}
	}

	@MainActor
	var showHints: Bool {
		get {
			miscSettings.showHints
		}
		set {
			miscSettings.set(showHints: newValue)
		}
	}

	init(
		mode: PreferencesLaunchMode,
		changeSubject: PassthroughSubject<PreferencesChange, Never>
	) {
		self.mode = mode
		self.changeSubject = changeSubject
	}

	@MainActor
	func reportHasDismissedSetupInstructions() {
		InformationConsumption.current.reportHasDismissedSetupInstructions()
	}

	@MainActor
	func didSelectMacOsInstallDiskCandidate(url: URL) async -> RomValidationResult {
		await RomManager.shared.didSelectMacOsInstallDiskCandidate(url: url)
	}

	@MainActor
	func createNewDisk(name: String, sizeInMb: Int) throws -> Disk? {
		guard sizeInMb > 0 else {
			throw PreferencesGeneralError.fileCreationInvalidSize
		}

		let fixedName = name.hasSuffix(".dsk") ? name : "\(name).dsk"

		let path = Storage.urlForDocumentFile(filename: fixedName).path
		guard !FileManager.default.fileExists(atPath: path) else {
			throw PreferencesGeneralError.fileWithFilenameAleadyExists
		}

		let success = objc_createDiskWithName(fixedName, sizeInMb)
		if !success {
			throw PreferencesGeneralError.fileCreationFailedOtherError
		}

		DiskManager.shared.loadDiskData(
			requestEnableDiskWithFilename: fixedName
		)

		return disk(forFilename: fixedName)
	}

	@MainActor
	func didSelectFileImport(url: URL) async throws -> Disk? {
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

		let filename = url.lastPathComponent

		DiskManager.shared.loadDiskData(
			requestEnableDiskWithFilename: filename
		)

		return disk(forFilename: filename)
	}

	@MainActor
	func didSelectReload() async throws {
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
	func diskEntry(for disk: Disk) -> DiskEntry {
		let index = DiskManager.shared.diskArray.firstIndex(of: disk)!
		return .init(index: index, filename: disk.filename, type: disk.type)
	}

	@MainActor
	@discardableResult
	func setDiskEnabled(filename: String, isEnabled: Bool) -> DiskSelectionChangeResult {
		guard var disk = disk(forFilename: filename) else {
			return .init(prevIndex: 0, newIndex: 0, willBootFromCDChanged: false)
		}

		guard let prevIndex = DiskManager.shared.diskArray.firstIndex(where: {$0 == disk}) else {
			fatalError()
		}

		let prevWillBootFromCD = DiskManager.shared.willBootFromCD

		disk.isEnabled = isEnabled
		DiskManager.shared.set(disk)

		guard let newIndex = DiskManager.shared.diskArray.firstIndex(where: {$0 == disk}) else {
			fatalError()
		}

		let newWillBootFromCD = DiskManager.shared.willBootFromCD
		let willBootFromCDChanged = prevWillBootFromCD != newWillBootFromCD

		changeSubject.send(.changeRequiringRestartAfterBootMade)

		return .init(
			prevIndex: prevIndex,
			newIndex: newIndex,
			willBootFromCDChanged: willBootFromCDChanged
		)
	}

	@MainActor
	func setDiskType(filename: String, diskType: DiskType) {
		guard var disk = disk(forFilename: filename) else {
			return
		}
		
		disk.type = diskType
		DiskManager.shared.set(disk)
		
		changeSubject.send(.changeRequiringRestartAfterBootMade)
	}

	@MainActor
	func deleteDisk(_ disk: Disk) {
		DiskManager.shared.remove(diskWithFilename: disk.filename)
	}
}
