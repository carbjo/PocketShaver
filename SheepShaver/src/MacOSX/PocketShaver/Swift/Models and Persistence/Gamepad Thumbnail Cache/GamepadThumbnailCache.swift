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
		// Deterministic output so equal configs hash to the same cache key.
		encoder.outputFormatting = [.sortedKeys]
		return encoder
	}()

	// Thumbnails get their own subdirectory, apart from Storage's files. Its
	// absence also signals that the legacy cleanup below hasn't run yet.
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

	// Content-addressed filename, stable across launches (unlike `hashValue`).
	private func stableIdentifier(for config: GamepadConfig) -> String {
		guard let data = try? Self.encoder.encode(config) else {
			// Encoding should never fail. If it does, fall back to the
			// per-process hash; the prefix keeps it out of the legacy cleanup.
			return "unstable-\(config.hashValue)"
		}
		return GamepadThumbnailCacheKey.stableKey(for: data)
	}

	// One-time cleanup of legacy thumbnails named "\(config.hashValue)" in
	// Application Support; that key changed every launch, so orphans piled up.
	// Gated on `thumbnailsDirectory` not existing yet.
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
