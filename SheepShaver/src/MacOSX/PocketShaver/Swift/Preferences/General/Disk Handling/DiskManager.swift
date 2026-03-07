//
//  DiskManager.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-29.
//

import Foundation

enum DiskType: String, Codable {
	case disk
	case cd
}

struct Disk: Codable, Equatable {
	let filename: String
	var isBootable: Bool
	let romVersion: NewWorldRomVersion?
	var type: DiskType
	fileprivate var shouldReevaluateBootability: Bool
	var isEnabled: Bool

	var naturalDiskType: DiskType {
		Self.naturalDiskType(forFilename: filename)
	}

	var isNonCompatibleInstallDisc: Bool {
		if let romVersion {
			return !romVersion.isInstallCompatible
		} else {
			return false
		}
	}

	var installDiscString: String? {
		return romVersion?.osString
	}

	init(
		_ pathOrFilename: String,
		isEnabled: Bool
	) {
		let filename = pathOrFilename.lastPathComponent
		let naturalDiskType = Self.naturalDiskType(forFilename: pathOrFilename)

		self.filename = filename
		type = Self.naturalDiskType(forFilename: pathOrFilename)
		isBootable = fileIsBootable(filename: filename)
		switch naturalDiskType {
		case .disk:
			romVersion = nil
		case .cd:
			romVersion = fileRomVersion(filename: filename)
		}
		shouldReevaluateBootability = false
		self.isEnabled = isEnabled
	}

	fileprivate mutating func reevaluateBootability() {
		guard shouldReevaluateBootability else {
			return
		}
		isBootable = fileIsBootable(filename: filename)
		shouldReevaluateBootability = false
	}

	static func == (lhs: Disk, rhs: Disk) -> Bool {
		lhs.filename == rhs.filename &&
		lhs.type == rhs.type &&
		lhs.isEnabled == rhs.isEnabled
	}

	static func naturalDiskType(forFilename filename: String) -> DiskType {
		let pathExtension = filename.pathExtension.lowercased()
		if DiskManager.assumedCdRomFileExtensions.contains(pathExtension) {
			return .cd
		}
		return .disk
	}
}

struct DiskDataChange {
	let inserted: [Int]
	let updated: [Int]
	let removed: [Int]
}

@MainActor
private struct DiskConfig: Codable {
	var disks: [Disk]

	static var current: DiskConfig = {
		if let data = Storage.shared.load(from: .diskConfig),
		   let settings = try? JSONDecoder().decode(DiskConfig.self, from: data) {
			return settings
		}

		return DiskConfig(disks: [])
	}()

	mutating func processAndSaveAsCurrent() {
		sortDisks()
		reevaluateBootabilityOnDisks()
		saveAsCurrent()
	}

	mutating func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .diskConfig)
		} catch {}
	}

	private mutating func sortDisks() {
		let enabledDisks = disks.filter({ $0.isEnabled })
		let sortedDisabledDisks = disks
			.filter({ !$0.isEnabled })
			.sorted(by: { lhs, rhs in
			if lhs.isEnabled, !rhs.isEnabled {
				return true
			} else if !lhs.isEnabled, rhs.isEnabled {
				return false
			}
			return lhs.filename.lowercased() < rhs.filename.lowercased()
		})

		disks = enabledDisks + sortedDisabledDisks
	}

	private mutating func reevaluateBootabilityOnDisks() {
		var disks = self.disks
		for diskIndex in 0..<disks.count {
			disks[diskIndex].reevaluateBootability()
		}
		self.disks = disks
	}
}


class DiskManager {

	@MainActor
	static let shared = DiskManager()

	static let supportedFileExtensions = ["dsk", "dmg", "cdr", "iso", "cue", "toast", "img"]
	static let assumedCdRomFileExtensions = ["iso", "cdr", "toast", "cue"]

	@MainActor
	private var diskConfig = DiskConfig.current

	@MainActor
	var diskArray: [Disk] {
		diskConfig.disks
	}

	@MainActor
	var willBootFromCD: Bool {
		let selectedDisks = diskArray.filter({ $0.isEnabled })
		guard selectedDisks.contains(where: { $0.type == .cd && $0.isBootable }) else {
			return false
		}
		
		return !selectedDisks.contains(where: { $0.type == .disk && $0.isBootable })
	}

	@MainActor
	init() {
		loadDiskData()
	}

	@MainActor
	@discardableResult
	func loadDiskData(
		requestEnableDiskWithFilename enableDiskWithFilename: String? = nil
	) -> DiskDataChange {

		let oldDiskArray = diskArray
		var diskArray = diskArray

		let allElements = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.documentUrl.path)) ?? []

		let candidateFilePaths = allElements.filter({
			$0.lowercased().hasSuffixMatchingSuffixes(in: Self.supportedFileExtensions)
		})
		let candidateFilenames = candidateFilePaths.map({ $0.lastPathComponent })


		diskArray = diskArray.filter({ candidateFilenames.contains($0.filename) })

		let timestamp = Date()
		var didAddFile = false
		let diskArrayFilenames = diskArray.map({ $0.filename })
		for candidateFilePath in candidateFilePaths {
			let filename = candidateFilePath.lastPathComponent
			if diskArrayFilenames.contains(filename) {
				continue
			}

			let isEnabled = filename == enableDiskWithFilename
			let disk = Disk(filename, isEnabled: isEnabled)
			print("- created \(disk)")
			diskArray.append(disk)
			didAddFile = true
		}

		if didAddFile {
			let time = Date().timeIntervalSince(timestamp)
			print(String(format: "- crating filelist took %.3f s", time))
		}

		diskConfig.disks = diskArray
		diskConfig.processAndSaveAsCurrent()

		let newDiskArray = diskConfig.disks

		return .init(oldArray: oldDiskArray, newArray: newDiskArray)
	}

	@MainActor
	func index(forFilename filename: String) -> Int? {
		diskArray.firstIndex(where: { $0.filename == filename })
	}

	@MainActor
	func set(_ disk: Disk) {
		guard let index = index(forFilename: disk.filename) else {
			return
		}
		diskConfig.disks[index] = disk

		diskConfig.processAndSaveAsCurrent()

		PreferencesManager.shared.writePreferences()
	}

	@MainActor
	func remove(diskWithFilename filename: String) {
		guard let index = index(forFilename: filename) else {
			return
		}

		let url = Storage.urlForDocumentFile(filename: filename)
		Storage.deleteIfExists(url)

		diskConfig.disks.remove(at: index)

		diskConfig.processAndSaveAsCurrent()

		PreferencesManager.shared.writePreferences()
	}

	@MainActor
	func reportWillBoot() {
		guard willBootFromCD else {
			return
		}

		for diskIndex in 0..<diskArray.count {
			var disk = diskArray[diskIndex]
			guard disk.type == .disk,
				  disk.isEnabled else {
				continue
			}
			disk.shouldReevaluateBootability = true

			diskConfig.disks[diskIndex] = disk
		}

		diskConfig.saveAsCurrent()
	}
}

extension DiskDataChange {
	init(oldArray: [Disk], newArray: [Disk]) {
		var inserted = [Int]()
		let surplusCount = newArray.count - oldArray.count
		if surplusCount > 0 {
			for i in 0..<surplusCount {
				inserted.append(i + oldArray.count)
			}
		}

		var updated = [Int]()
		let maxCount = min(oldArray.count, newArray.count)
		for i in 0..<maxCount {
			if oldArray[i].filename != newArray[i].filename {
				updated.append(i)
			}
		}

		var removed = [Int]()
		let lossCount = oldArray.count - newArray.count
		if lossCount > 0 {
			for i in 0..<lossCount {
				removed.append(i + newArray.count)
			}
		}

		self.inserted = inserted
		self.updated = updated
		self.removed = removed
	}
}

fileprivate func fileIsBootable(filename: String) -> Bool {
	let path = Storage.urlForDocumentFile(filename: filename)

	let destFileUrl = Storage.urlForDocumentFile(filename: ".extractedFinder")
	Storage.deleteIfExists(destFileUrl)

	var success = DiskFileExtractor.extractFile(fromDiskUrl: path, to: destFileUrl, quarryNameOrPath: ":System Folder:Finder")

	if !success {
		success = DiskFileExtractor.extractFile(fromDiskUrl: path, to: destFileUrl, quarryNameOrPath: "Finder")
	}

	Storage.deleteIfExists(destFileUrl)

	return success
}

fileprivate func fileRomVersion(filename: String) -> NewWorldRomVersion? {
	let path = Storage.urlForDocumentFile(filename: filename)
	let destFileUrl = Storage.urlForDocumentFile(filename: ".extractedRom")
	defer {
		Storage.deleteIfExists(destFileUrl)
	}

	Storage.deleteIfExists(destFileUrl)

	var success = DiskFileExtractor.extractFile(fromDiskUrl: path, to: destFileUrl, quarryNameOrPath: ":System Folder:Mac OS ROM")

	if !success {
		success = DiskFileExtractor.extractFile(fromDiskUrl: path, to: destFileUrl, quarryNameOrPath: "Mac OS ROM")
	}

	if !success {
		return nil
	}

	guard let md5Hash = try? Storage.getFileMd5Hash(destFileUrl) else {
		return nil
	}

	return NewWorldRomVersion(md5hash: md5Hash)
}
