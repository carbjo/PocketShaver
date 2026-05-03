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
		let hash = "\(config.hashValue)"
		return FileManager.appSupportUrl.appendingPathComponent(hash)
	}
}
