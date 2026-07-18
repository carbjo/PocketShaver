//
//  GamepadThumbnailCache.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-04-28.
//

import UIKit

class GamepadThumbnailCache {
	static let shared = GamepadThumbnailCache()

	private var inMemoryCache = [Int: UIImage]() // Move out to PreferencesGamepadThumbnailsViewController?

	private static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		// Deterministic output so equal configs always encode to the same bytes,
		// and therefore hash to the same on-disk cache key.
		encoder.outputFormatting = [.sortedKeys]
		return encoder
	}()

	// Thumbnails live in their own subdirectory rather than loose in Application
	// Support. That keeps them clearly separated from Storage's named files and,
	// because the directory did not exist under the old (top-level) scheme, its
	// absence doubles as the "haven't migrated yet" signal below.
	private let thumbnailsDirectory = FileManager.appSupportUrl
		.appendingPathComponent("GamepadThumbnails", isDirectory: true)

	private init() {
		let fileManager = FileManager.default
		let hasMigrated = fileManager.fileExists(atPath: thumbnailsDirectory.path)

		try? fileManager.createDirectory(
			at: thumbnailsDirectory,
			withIntermediateDirectories: true
		)

		if !hasMigrated {
			removeLegacyOrphanedThumbnails()
		}
	}

	func register(
		oldConfig: GamepadConfig? = nil,
		newConfig: GamepadConfig
	) {
		if let oldConfig {
			let oldConfigUrl = self.url(for: oldConfig)
			Storage.deleteIfExists(oldConfigUrl)
		}

		image(for: newConfig)
	}

	@discardableResult
	func image(for config: GamepadConfig) -> UIImage {
		let imageUrl = url(for: config)

		if let image = inMemoryCache[config.hashValue] {
			return image
		} else if Storage.fileOrDictionaryExists(at: imageUrl),
				  let data = try? Data(contentsOf: imageUrl),
				  let image = UIImage(data: data, scale: UIScreen.main.nativeScale) {

			inMemoryCache[config.hashValue] = image

			return image
		}

		let image = GamepadLayerView.asImage(
			config: config,
			size: UIScreen.landscapeModeSize
		)

		try? image.pngData()?.write(to: imageUrl)

		inMemoryCache[config.hashValue] = image

		return image
	}

	@MainActor
	func preloadImages() {
		for config in GamepadManager.shared.allConfigs {
			image(for: config)
		}
	}

	private func url(for config: GamepadConfig) -> URL {
		thumbnailsDirectory.appendingPathComponent(stableIdentifier(for: config))
	}

	// A content-addressed filename that is stable across launches, unlike
	// `config.hashValue` (whose `Hasher` is seeded with a per-process random
	// value). See GamepadThumbnailCacheKey for the rationale.
	private func stableIdentifier(for config: GamepadConfig) -> String {
		guard let data = try? Self.encoder.encode(config) else {
			// Encoding a Codable config should never fail; if it somehow does,
			// fall back to the process-local hash so the cache still functions
			// for this launch (it just won't hit across launches). The prefix
			// keeps it out of the legacy-orphan cleanup's numeric-name filter.
			return "unstable-\(config.hashValue)"
		}
		return GamepadThumbnailCacheKey.stableKey(for: data)
	}

	// One-time cleanup of files written by the old cache, which named thumbnails
	// "\(config.hashValue)" directly in Application Support. Because that key
	// changed every launch, a fresh orphan accreted for each config on each
	// launch (thousands were observed in one container). Runs once, gated by the
	// existence of `thumbnailsDirectory`.
	private func removeLegacyOrphanedThumbnails() {
		let fileManager = FileManager.default
		guard let entries = try? fileManager.contentsOfDirectory(
			at: FileManager.appSupportUrl,
			includingPropertiesForKeys: [.isDirectoryKey]
		) else {
			return
		}

		for url in entries {
			let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
			guard !isDirectory, GamepadThumbnailCacheKey.isLegacyThumbnailName(url.lastPathComponent) else {
				continue
			}
			try? fileManager.removeItem(at: url)
		}
	}
}
