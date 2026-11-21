//
//  GamepadThumbnailCacheKey.swift
//  PocketShaver
//
//  Created by Sierra Burkhart on 2026-07-02.
//

import Foundation
import CryptoKit

// Stable, content-addressed cache key for a gamepad thumbnail. `hashValue`
// can't name a disk file because Swift seeds `Hasher` per process.
enum GamepadThumbnailCacheKey {
	// SHA-256 hex digest of `data`.
	static func stableKey(for data: Data) -> String {
		SHA256.hash(data: data)
			.map { String(format: "%02hhx", $0) }
			.joined()
	}

	// Whether `name` is a legacy "\(config.hashValue)" thumbnail: an optional "-"
	// then digits. Nothing else in Application Support is numeric, and new keys
	// live in a subdirectory, so this only matches legacy orphans.
	static func isLegacyThumbnailName(_ name: String) -> Bool {
		var digits = Substring(name)
		if digits.first == "-" {
			digits = digits.dropFirst()
		}
		return !digits.isEmpty && digits.allSatisfy { $0 >= "0" && $0 <= "9" }
	}
}
