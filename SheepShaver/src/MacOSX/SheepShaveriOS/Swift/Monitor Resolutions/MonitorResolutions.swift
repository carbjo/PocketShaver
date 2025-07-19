//
//  MonitorResolutions.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-18.
//

import UIKit

@objc
public class MonitorResolutionElement: NSObject {
	@objc public let width: Int
	@objc public let height: Int
	@objc public let index: Int

	init(width: Int, height: Int, index: Int) {
		self.width = width
		self.height = height
		self.index = index
	}
}

@objc
public class MonitorResolutions: NSObject {
	struct Resolution {
		let width: Int
		let height: Int
	}

	private static let standardResolutions: [Resolution] = [
		.init(width: 640, height: 480),
		.init(width: 800, height: 600),
		.init(width: 1024, height: 768),
		.init(width: 1152, height: 870),
		.init(width: 1280, height: 1024),
		.init(width: 1600, height: 1200)
	]

	@objc @MainActor
	public static func getAllMonitorResolutions() -> [MonitorResolutionElement] {
		let screenSize = UIScreen.main.bounds

		var resolutions = [Resolution]()
		resolutions.append( // The native resolution, with native scaling must appear first
			.init(
				width: Int(screenSize.width),
				height: Int(screenSize.height)
			)
		)

		resolutions.append(contentsOf: standardResolutions)

		// The rest of the pixel aligned, full screen resolutions, in addition to the native resolution - native scale one
		resolutions.append(contentsOf: getAdditionalPixelAlignedResolutions())

		// Add these, since so much software is designed with 480 or 600 height screen resolutions in mind
		resolutions.append(getScaledToFitResolution(forHeight: 480))
		resolutions.append(getScaledToFitResolution(forHeight: 600))

		resolutions = Array(resolutions.prefix(10)) // TODO: The OS can't handle more than 10 resolutions. Create better handling

		var outputResolutions = [MonitorResolutionElement]()
		var index: Int = 0x81 // Lowest monitor index video driver expects

		for resolution in resolutions {
			outputResolutions.append(
				.init(width: resolution.width, height: resolution.height, index: index)
			)
			index += 1
		}

		return outputResolutions
	}

	@MainActor
	private static func getAdditionalPixelAlignedResolutions() -> [Resolution] {
		let mainScreen = UIScreen.main
		let screenHeight = Int(mainScreen.bounds.size.height)
		let screenWidth = Int(mainScreen.bounds.size.width)
		let screenScale = Int(mainScreen.scale)
		let pixelHeight = screenHeight*screenScale
		let pixelWidth = screenWidth*screenScale

		var resolutions = [Resolution]()
		for scale in (1..<screenScale) {
			let height = pixelHeight / scale
			let width = pixelWidth / scale
			resolutions.append(.init(width: width, height: height))
		}

		return resolutions
	}

	@MainActor
	private static func getScaledToFitResolution(forHeight height: Int) -> Resolution {
		let mainScreen = UIScreen.main
		let screenHeight = mainScreen.bounds.size.height
		let screenWidth = mainScreen.bounds.size.width
		let widthToHeightRatio = screenWidth / screenHeight
		let width = Int(CGFloat(height) * widthToHeightRatio)

		return .init(width: width, height: height)
	}
}
