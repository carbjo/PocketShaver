//
//  GamepadThumbnailCacheKey.swift
//  PocketShaver
//
//  Created by Sierra Burkhart on 2026-07-02.
//

import Foundation
import CryptoKit

// Derives a stable, content-addressed cache key for a gamepad thumbnail.
//
// A gamepad config's `hashValue` cannot be used to name an on-disk cache file:
// Swift seeds `Hasher` with a per-process random value, so `hashValue` differs
// on every launch. Naming the file by `hashValue` meant the disk cache never
// hit across launches and a fresh file was written for the same config each
// time, both re-rendering every layout on the main thread at startup and
// accreting orphaned files in Application Support.
//
// SHA-256 over the config's encoded bytes has no such seed: identical content
// always maps to the same key, on every launch and every device.
enum GamepadThumbnailCacheKey {
	// SHA-256 hex digest of `data`. Deterministic across processes and devices.
	static func stableKey(for data: Data) -> String {
		SHA256.hash(data: data)
			.map { String(format: "%02hhx", $0) }
			.joined()
	}

	// Whether `name` was written by the old cache, which named thumbnails
	// "\(config.hashValue)" — the decimal string of a Swift `Int`: an optional
	// leading "-" followed by ASCII digits. No other file PocketShaver stores in
	// Application Support has that shape (Storage's names are all alphabetic), so
	// a purely numeric name uniquely identifies a legacy orphan to clean up.
	//
	// New keys from `stableKey(for:)` are 64-char hex and live in a subdirectory,
	// so they are never matched here even in the astronomically unlikely event a
	// digest is all-digits.
	static func isLegacyThumbnailName(_ name: String) -> Bool {
		var digits = Substring(name)
		if digits.first == "-" {
			digits = digits.dropFirst()
		}
		return !digits.isEmpty && digits.allSatisfy { $0 >= "0" && $0 <= "9" }
	}
}
