//
//  DiskManager.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-29.
//

import Foundation

struct Disk {
	let path: String
	var isCdRom: Bool
	var isEnabled: Bool

	init(
		path: String,
		isCdRom: Bool = false,
		isEnabled: Bool
	) {
		self.path = path
		self.isCdRom = isCdRom
		self.isEnabled = isEnabled
	}

	var filename: String {
		path.lastPathComponent
	}
}

struct DiskDataChange {
	let inserted: [Int]
	let updated: [Int]
	let removed: [Int]
}

class DiskManager {

	@MainActor static let shared = DiskManager()

	static let supportedFileExtensions = ["dsk", "dmg", "cdr", "iso", "toast", "img"]
	static let assumedCdRomFileExtensions = ["iso", "cdr", "toast"]

	private(set) var diskArray = [Disk]()

	init() {
		loadDiskData()
	}

	@discardableResult
	func loadDiskData() -> DiskDataChange {

		let oldDiskArray = diskArray
		diskArray = []

		// First we scan for all available disks in the Documents directory. Then we reconcile that
		// with the "disk" prefs, eliminating any existing prefs that we can't find in the Documents
		// directory. This we use to populate diskArray.
		diskArray.append(contentsOf: findDisks())
		diskArray.append(contentsOf: findCdroms())


		let allElements = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.documentUrl.path)) ?? []

		let candidateFilePaths = allElements.filter({
			$0.lowercased().hasSuffixMatchingSuffixes(in: Self.supportedFileExtensions)
		})

		// Compare the lists. For any disk that we have that doesn't actually exist, eliminate it from the disks list.
		// For any disk that actually exists that we don't already know about, create an entry but mark it disabled.
		// Note that we compare last path components only, because the path to the file may change as installations
		// on devices change.

		let candidateFilenames = candidateFilePaths.map({ $0.lastPathComponent })
		diskArray = diskArray.filter({ candidateFilenames.contains($0.filename) })

		// Now diskArray contains only things that actually exist, let's see if there is anything else to add to it,
		// that is, files that exist that aren't already accounted for.
		let diskArrayFilenames = diskArray.map({ $0.path }).map({ $0.lastPathComponent })
		for candidateFilePath in candidateFilePaths {
			let filename = candidateFilePath.lastPathComponent
			if diskArrayFilenames.contains(filename) {
				continue
			}
			let isCdRom = Self.assumedCdRomFileExtensions.contains(candidateFilePath.pathExtension.lowercased())
			let disk = Disk(path: candidateFilePath, isCdRom: isCdRom, isEnabled: false)
			diskArray.append(disk)
		}


		return .init(oldArray: oldDiskArray, newArray: diskArray)
	}

	@MainActor
	func set(_ disk: Disk) {
		remove(diskWithFilename: disk.filename)

		diskArray.append(disk)

		PreferencesManager.shared.writePreferences()
	}

	@MainActor
	func remove(diskWithFilename filename: String) {
		guard let index = diskArray.firstIndex(where: { $0.filename == filename }) else {
			return
		}

		diskArray.remove(at: index)

		PreferencesManager.shared.writePreferences()
	}

	private func findDisks() -> [Disk] {
		var result = [Disk]()
		var index = 0

		while let diskString = objc_findStringWithIndex("disk", Int32(index)) {
			let disk = Disk(path: diskString, isEnabled: true)
			result.append(disk)

			index += 1
		}

		return result
	}

	private func findCdroms() -> [Disk] {
		var result = [Disk]()
		var index = 0
		while let diskString = objc_findStringWithIndex("cdrom", Int32(index)) {
			guard !diskString.hasPrefix("/dev/") else {
				index += 1
				continue
			}

			let disk = Disk(path: diskString, isCdRom: true, isEnabled: true)
			result.append(disk)

			index += 1
		}

		return result
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
