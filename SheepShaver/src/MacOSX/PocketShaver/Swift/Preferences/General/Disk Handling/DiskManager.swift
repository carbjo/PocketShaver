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
	var type: DiskType
	var isEnabled: Bool

	init(
		_ path: String,
		type: DiskType = .disk,
		isEnabled: Bool
	) {
		self.filename = path.lastPathComponent
		self.type = type
		self.isEnabled = isEnabled
	}

	static func == (lhs: Disk, rhs: Disk) -> Bool {
		lhs.filename == rhs.filename &&
		lhs.type == rhs.type &&
		lhs.isEnabled == rhs.isEnabled
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

	mutating func sortAndSaveAsCurrent() {
		sortDisks()

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
}

@MainActor
class DiskManager {

	static let shared = DiskManager()

	static let supportedFileExtensions = ["dsk", "dmg", "cdr", "iso", "cue", "toast", "img"]
	static let assumedCdRomFileExtensions = ["iso", "cdr", "toast", "cue"]

	private var diskConfig = DiskConfig.current
	var diskArray: [Disk] {
		diskConfig.disks
	}

	init() {
		loadDiskData()
	}

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

		let diskArrayFilenames = diskArray.map({ $0.filename })
		for candidateFilePath in candidateFilePaths {
			let filename = candidateFilePath.lastPathComponent
			if diskArrayFilenames.contains(filename) {
				continue
			}
			let isCdRom = Self.assumedCdRomFileExtensions.contains(candidateFilePath.pathExtension.lowercased())
			let isEnbled = filename == enableDiskWithFilename
			let disk = Disk(filename, type: isCdRom ? .cd : .disk, isEnabled: isEnbled)
			diskArray.append(disk)
		}

		diskConfig.disks = diskArray
		diskConfig.sortAndSaveAsCurrent()

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

		diskConfig.sortAndSaveAsCurrent()

		PreferencesManager.shared.writePreferences()
	}

	@MainActor
	func remove(diskWithFilename filename: String) {
		guard let index = index(forFilename: filename) else {
			return
		}

		diskConfig.disks.remove(at: index)

		diskConfig.sortAndSaveAsCurrent()

		PreferencesManager.shared.writePreferences()
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
