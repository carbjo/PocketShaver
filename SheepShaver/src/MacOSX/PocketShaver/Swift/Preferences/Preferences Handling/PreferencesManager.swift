//
//  PreferencesManager.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-30.
//

import Foundation
import UIKit

@MainActor
class PreferencesManager {

	public static let shared = PreferencesManager()

	func writePreferences() {
		writeDiskPrefs()

		objc_addString("seriala", "/dev/null")
		objc_addString("serialb", "/dev/null")
		objc_addString("ether", "slirp")

		let screenSize = UIScreen.main.bounds.size
		let width = Int(screenSize.width)
		let height = Int(screenSize.height)
		let screenString = "dga/\(width)/\(height)"
		objc_replaceString("screen", screenString)

		objc_replaceString("sdlrender", "metal")
		objc_replaceString("extfs", FileManager.documentUrl.path)

		objc_savePrefs()
	}

	private func writeDiskPrefs() {
		let diskArray = DiskManager.shared.diskArray

		// Clear the prefs and rewrite them. If there is but one real disk and no remaining prefs disks, we should just
		// set the one as the prefs disk without bothering the user.
		while objc_findString("disk") != nil {
			objc_removeItem("disk")
		}
		while objc_findString("cdrom") != nil {
			objc_removeItem("cdrom")
		}

		for disk in diskArray {
			guard disk.isEnabled else {
				continue
			}

			let filePath = (FileManager.documentUrl.path as NSString).appendingPathComponent(disk.filename)
			let name = disk.type == .cd ? "cdrom" : "disk"
			objc_addString(name, filePath)
		}

		// Ensure that /dev/poll/cdrom is present exactly once.
		var hasPollCdRom = false
		var index = 0
		while let diskString = objc_findStringWithIndex("cdrom", Int32(index)) {
			if diskString == "/dev/poll/cdrom" {
				hasPollCdRom = true
				break
			}

			index += 1
		}
		if !hasPollCdRom {
			objc_addString("cdrom", "/dev/poll/cdrom")
		}
	}
}
