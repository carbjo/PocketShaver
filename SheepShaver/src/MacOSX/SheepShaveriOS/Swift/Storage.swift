//
//  Storage.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-30.
//

import Foundation

class Storage {
	@MainActor static let shared = Storage()

	enum File: String {
		case gamepad
	}

	private let appSupportUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

	init() {
		if !FileManager.default.fileExists(atPath: appSupportUrl.absoluteString) {
			do {
				try FileManager.default.createDirectory(at: appSupportUrl, withIntermediateDirectories: true, attributes: nil)
			} catch {
				print("Warning: failed to create file at \(appSupportUrl) error: \(error)")
			}
		}
	}

	func save(_ data: Data, at file: File) {
		let url = appSupportUrl.appendingPathComponent(file.rawValue)
		do {
			try data.write(to: url, options: .atomic)
		} catch {
			print("-- failed to persist data at file \(file.rawValue) error: \(error)")
		}
	}

	func load(from file: File) -> Data? {
		let url = appSupportUrl.appendingPathComponent(file.rawValue)
		do {
			let data = try Data(contentsOf: url)
			return data
		} catch {
			print("-- failed to load data from file \(file.rawValue) error: \(error)")
			return nil
		}
	}
}

