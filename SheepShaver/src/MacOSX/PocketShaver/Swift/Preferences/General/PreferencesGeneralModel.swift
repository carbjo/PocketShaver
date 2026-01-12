//
//  PreferencesGeneralModel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import Foundation
import Combine
import CoreHaptics

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

	private let mode: PreferencesLaunchMode

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

	@MainActor
	var soundDisabled: Bool {
		get {
			MiscellaneousSettings.current.soundDisabled
		}
		set {
			let previousValue = MiscellaneousSettings.current.soundDisabled
			MiscellaneousSettings.current.set(soundDisabled: newValue)

			if mode == .duringEmulation,
				newValue != previousValue {
				objc_update_audio_disabled_setting(newValue)
			}
		}
	}

	@MainActor
	var isIPadMouseEnabled: Bool {
		get {
			MiscellaneousSettings.current.iPadMousePassthrough
		}
		set {
			MiscellaneousSettings.current.set(iPadMousePassthrough: newValue)
			objc_update_sdl_ipad_mouse_setting(newValue)
		}
	}

	@MainActor
	var rightClickSetting: RightClickSetting {
		get {
			MiscellaneousSettings.current.rightClickSetting
		}
		set {
			MiscellaneousSettings.current.set(rightClickSetting: newValue)
		}
	}

	lazy var supportsHaptics: Bool = {
		CHHapticEngine.capabilitiesForHardware().supportsHaptics
	}()

	@MainActor
	var isGestureHapticFeedbackOn: Bool {
		get {
			MiscellaneousSettings.current.gestureHapticFeedback
		}
		set {
			MiscellaneousSettings.current.set(gestureHapticFeedback: newValue)
		}
	}

	@MainActor
	var isMouseHapticFeedbackOn: Bool {
		get {
			MiscellaneousSettings.current.mouseHapticFeedback
		}
		set {
			MiscellaneousSettings.current.set(mouseHapticFeedback: newValue)
		}
	}

	@MainActor
	var isKeyHapticFeedbackOn: Bool {
		get {
			MiscellaneousSettings.current.keyHapticFeedback
		}
		set {
			MiscellaneousSettings.current.set(keyHapticFeedback: newValue)
		}
	}

	@MainActor
	var showHints: Bool {
		get {
			MiscellaneousSettings.current.showHints
		}
		set {
			MiscellaneousSettings.current.set(showHints: newValue)
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
		MiscellaneousSettings.current.reportHasDismissedSetupInstructions()
	}

	@MainActor
	func didSelectMacOsInstallDiskCandidate(url: URL) async -> RomValidationResult {
		let result = await RomManager.shared.didSelectMacOsInstallDiskCandidate(url: url)
		changeSubject.send(.changeRequiringRestartAfterBootMade)
		return result
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
