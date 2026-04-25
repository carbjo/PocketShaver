//
//  Storage.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-30.
//

import Foundation
import CryptoKit

class Storage {
	@MainActor static let shared = Storage()

	enum File: String {
		case gamepad
		case portraitResolutions
		case landscapeResolutions
		case miscellaneous
		case informationConsumption
		case diskConfig
		case network
	}

	init() {
		let appSupportUrl = FileManager.appSupportUrl

		if !Self.fileOrDictionaryExists(at: appSupportUrl) {
			do {
				try FileManager.default.createDirectory(at: appSupportUrl, withIntermediateDirectories: true, attributes: nil)
			} catch {
				print("Warning: failed to create file at \(appSupportUrl) error: \(error)")
			}
		}
	}

	func save(_ data: Data, at file: File) {
		let url = Self.urlForAppSupportFile(filename: file.rawValue)
		do {
			try data.write(to: url, options: .atomic)
		} catch {
			print("-- failed to persist data at file \(file.rawValue) error: \(error)")
		}
	}

	func load(from file: File) -> Data? {
		let url = Self.urlForAppSupportFile(filename: file.rawValue)
		do {
			let data = try Data(contentsOf: url)
			return data
		} catch {
			print("-- failed to load data from file \(file.rawValue) error: \(error)")
			return nil
		}
	}

	func delete(file: File) {
		let url = Self.urlForAppSupportFile(filename: file.rawValue)
		Self.deleteIfExists(url)
	}

	static func urlForAppSupportFile(filename: String) -> URL {
		FileManager.appSupportUrl.appendingPathComponent(filename)
	}

	static func urlForDocumentFile(filename: String) -> URL {
		FileManager.documentUrl.appendingPathComponent(filename)
	}

	static func fileOrDictionaryExists(at url: URL) -> Bool {
		FileManager.default.fileExists(atPath: url.path)
	}

	static func deleteIfExists(_ url: URL) {
		do {
			try FileManager.default.removeItem(atPath: url.path)
		} catch {
			print("-- failed to delete file \(url.path.lastPathComponent) error: \(error)")
		}
	}

	static func getFileMd5Hash(_ url: URL) throws -> String {
		let data = try Data(contentsOf: url)
		let digest = Insecure.MD5.hash(data: data)
		return digest.map {
			String(format: "%02hhx", $0)
		}.joined()
	}
}

