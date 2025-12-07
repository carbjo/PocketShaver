//
//  MonitorResolutions.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-18.
//

import UIKit

enum MonitorResolutionCategory: String, Codable, Equatable, CaseIterable {
	case pixelAlignedPortrait
	case pixelAlignedLandscape
	case standardResolution
	case standardWidthPortrait
	case standardHeightLandscape
}

struct MonitorResolution: Codable, Equatable {
	let width: Int
	let height: Int
}

struct MonitorResolutionOption: Codable, Equatable {
	let category: MonitorResolutionCategory
	let resolution: MonitorResolution
	let auxillaryInformation: String?

	init(category: MonitorResolutionCategory, resolution: MonitorResolution, auxillaryInformation: String? = nil) {
		self.category = category
		self.resolution = resolution
		self.auxillaryInformation = auxillaryInformation
	}
}

@objc
public class SDLVideoMonitorResolutionElement: NSObject {
	@objc public let width: Int
	@objc public let height: Int
	@objc public let index: Int

	init(width: Int, height: Int, index: Int) {
		self.width = width
		self.height = height
		self.index = index
	}
}

@objc @MainActor
public class MonitorResolutionManager: NSObject {
	@MainActor
	struct Margins {
		private let isPortrait: Bool
		private let edgeInsets: UIEdgeInsets

		init(isPortrait: Bool, edgeInsets: UIEdgeInsets) {
			self.isPortrait = isPortrait
			self.edgeInsets = edgeInsets
		}
	}

	@objc
	public static let shared = MonitorResolutionManager()

	static let maxNumberOfSimultaniousResolutions = 10

	private(set) var availableResolutions: [MonitorResolutionCategory: [MonitorResolutionOption]]

	private var enabledPortraitResolutions: [MonitorResolutionOption] {
		didSet {
			let encoder = JSONEncoder()
			guard let data = try? encoder.encode(enabledPortraitResolutions) else {
				return
			}
			Storage.shared.save(data, at: .portraitResolutions)
		}
	}

	private var enabledLandscapeResolutions: [MonitorResolutionOption] {
		didSet {
			let encoder = JSONEncoder()
			guard let data = try? encoder.encode(enabledLandscapeResolutions) else {
				return
			}
			Storage.shared.save(data, at: .landscapeResolutions)
		}
	}

	var willLaunchInPortraitMode: Bool {
		UIScreen.isPortraitMode && !MiscellaneousSettings.current.alwaysLandscapeMode
	}

	var enabledResolutionsCount: Int {
		if willLaunchInPortraitMode {
			return enabledPortraitResolutions.count
		} else {
			return enabledLandscapeResolutions.count
		}
	}

	var isEnabledResolutionsFull: Bool {
		enabledResolutionsCount >= Self.maxNumberOfSimultaniousResolutions
	}

	var is4to3ratioDevice: Bool {
		Self.getPortraitModeSize().width / Self.getPortraitModeSize().height == 3/4
	}

	private var hasRegisteredSafeAreaInsets = false
	private var needCompletingPreselectingLandscapeModeResolutions = false

	override init() {
		var availableResolutions = [MonitorResolutionCategory: [MonitorResolutionOption]]()
		for category in MonitorResolutionCategory.allCases {
			availableResolutions[category] = Self.getAvailableResolutions(for: category)
		}

		self.availableResolutions = availableResolutions

		let decoder = JSONDecoder()

		if let persistedEnabledPortraitResolutionsData = Storage.shared.load(from: .portraitResolutions),
		   let persistedEnabledPortraitResolutions = try? decoder.decode([MonitorResolutionOption].self, from: persistedEnabledPortraitResolutionsData) {
			enabledPortraitResolutions = persistedEnabledPortraitResolutions
		} else {
			enabledPortraitResolutions = [
				availableResolutions[.pixelAlignedPortrait]![0],
				availableResolutions[.standardResolution]![0]
			]
		}

		if let persistedEnabledLandscapeResolutionsData = Storage.shared.load(from: .landscapeResolutions),
		   let persistedEnabledLandscapeResolutions = try? decoder.decode([MonitorResolutionOption].self, from: persistedEnabledLandscapeResolutionsData) {
			enabledLandscapeResolutions = persistedEnabledLandscapeResolutions
		} else {
			enabledLandscapeResolutions = [
				availableResolutions[.pixelAlignedLandscape]![0],
				availableResolutions[.standardResolution]![0]
			]
			needCompletingPreselectingLandscapeModeResolutions = true
		}

		super.init()
	}

	func isResolutionEnabled(_ resolution: MonitorResolutionOption) -> Bool {
		if willLaunchInPortraitMode {
			return enabledPortraitResolutions.contains(resolution)
		} else {
			return enabledLandscapeResolutions.contains(resolution)
		}
	}

	func setIsResolutionEnabled(_ resolution: MonitorResolutionOption, isEnabled: Bool) {
		if willLaunchInPortraitMode {
			if isEnabled,
			   !enabledPortraitResolutions.contains(resolution) {
				enabledPortraitResolutions.append(resolution)
			} else if !isEnabled,
					  let index = enabledPortraitResolutions.firstIndex(where: { $0 == resolution }) {
				enabledPortraitResolutions.remove(at: index)
			}
		} else {
			if isEnabled,
			   !enabledLandscapeResolutions.contains(resolution) {
				enabledLandscapeResolutions.append(resolution)
			} else if !isEnabled,
					  let index = enabledLandscapeResolutions.firstIndex(where: { $0 == resolution }) {
				enabledLandscapeResolutions.remove(at: index)
			}
		}
	}

	func isResolutionAlwaysEnabled(_ resolution: MonitorResolutionOption) -> Bool {
		resolution == availableResolutions[.pixelAlignedPortrait]?.first ||
		resolution == availableResolutions[.pixelAlignedLandscape]?.first
	}

	func registerSafeAreaInsets(_ safeAreaInsets: UIEdgeInsets) -> Bool {
		let largestInset = [safeAreaInsets.left, safeAreaInsets.top, safeAreaInsets.right, safeAreaInsets.bottom].max()!

		guard !hasRegisteredSafeAreaInsets else {
			return false
		}
		hasRegisteredSafeAreaInsets = true

		let isStatusbarInsetOnly = safeAreaInsets.top == 20 && safeAreaInsets.bottom == 0
		let hasInsets = !isStatusbarInsetOnly && largestInset > 0

		if hasInsets { // status bar alone does not count, since it will be hidden
			let portraitMargins = Margins(isPortrait: true, edgeInsets: .init(top: largestInset, left: 0, bottom: largestInset, right: 0))
			availableResolutions[.pixelAlignedPortrait]!.append(contentsOf: Self.getPixelAlignedResolutions(size: Self.getPortraitModeSize(), margins: portraitMargins))
			availableResolutions[.standardWidthPortrait]!.append(Self.getScaledToFitResolution(forWidth: 640, margins: portraitMargins))
			availableResolutions[.standardWidthPortrait]!.append(Self.getScaledToFitResolution(forWidth: 800, margins: portraitMargins))

			
			let landscapeMargins = Margins(isPortrait: false, edgeInsets: .init(top: 0, left: largestInset, bottom: 0, right: largestInset))
			let maxWidth480HeightWithMarginsResolution = Self.getScaledToFitResolution(forHeight: 480, margins: landscapeMargins)

			availableResolutions[.pixelAlignedLandscape]!.append(contentsOf: Self.getPixelAlignedResolutions(size: Self.getLandscapeModeSize(), margins: landscapeMargins))
			availableResolutions[.standardHeightLandscape]!.append(maxWidth480HeightWithMarginsResolution)
			availableResolutions[.standardHeightLandscape]!.append(Self.getScaledToFitResolution(forHeight: 600, margins: landscapeMargins))

			if needCompletingPreselectingLandscapeModeResolutions {
				needCompletingPreselectingLandscapeModeResolutions = false

				enabledLandscapeResolutions.append(maxWidth480HeightWithMarginsResolution)
			}
		} else {
			if needCompletingPreselectingLandscapeModeResolutions {
				needCompletingPreselectingLandscapeModeResolutions = true

				enabledLandscapeResolutions.append(Self.getAvailableResolutions(for: .standardHeightLandscape).first!)
			}
		}

		return true
	}

	@objc
	public func getAllSDLVideoMonitorResolutionElements() -> [SDLVideoMonitorResolutionElement] {
		var resolutions: [MonitorResolution]
		if UIScreen.isPortraitMode {
			resolutions = enabledPortraitResolutions.map({ $0.resolution })
		} else {
			resolutions = enabledLandscapeResolutions.map({ $0.resolution })
		}

		resolutions = Array(resolutions.prefix(10))

		var outputResolutions = [SDLVideoMonitorResolutionElement]()
		var index: Int = 0x81 // Lowest monitor index video driver expects

		for resolution in resolutions {
			outputResolutions.append(
				.init(width: resolution.width, height: resolution.height, index: index)
			)
			index += 1
		}

		return outputResolutions
	}

	private static func getAvailableResolutions(for category: MonitorResolutionCategory) -> [MonitorResolutionOption] {
		switch category {
		case .pixelAlignedPortrait:
			return Self.getPixelAlignedResolutions(size: getPortraitModeSize())
		case .pixelAlignedLandscape:
			return Self.getPixelAlignedResolutions(size: getLandscapeModeSize())
		case .standardResolution:
			return [
				.init(
					category: .standardResolution,
					resolution: .init(width: 640, height: 480),
					auxillaryInformation: "Many Mac OS apps are designed for this resolution"
				),
				.init(
					category: .standardResolution,
					resolution: .init(width: 800, height: 600),
					auxillaryInformation: "Many Mac OS apps are designed for this resolution"
				),
				.init(
					category: .standardResolution,
					resolution: .init(width: 1024, height: 768)
				),
				.init(
					category: .standardResolution,
					resolution: .init(width: 1152, height: 870)
				),
			]
		case .standardWidthPortrait:
			return [
				Self.getScaledToFitResolution(forWidth: 640),
				Self.getScaledToFitResolution(forWidth: 800)
			]
		case .standardHeightLandscape:
			return [
				Self.getScaledToFitResolution(forHeight: 480),
				Self.getScaledToFitResolution(forHeight: 600)
				]
		}
	}

	private static func getPixelAlignedResolutions(size: CGSize, margins: Margins? = nil) -> [MonitorResolutionOption] {
		let mainScreen = UIScreen.main
		let screenScale = Int(mainScreen.scale)

		let screenWidth: Int
		let screenHeight: Int
		if let margins {
			if UIScreen.isPortraitMode {
				screenWidth = Int(size.width)
				screenHeight = Int(size.width * margins.ratioWithFixedSide())
			} else {
				screenHeight = Int(size.height)
				screenWidth = Int(size.height * margins.ratioWithFixedSide())
			}
		} else {
			screenWidth = Int(size.width)
			screenHeight = Int(size.height)
		}

		let pixelWidth = screenWidth*screenScale
		let pixelHeight = screenHeight*screenScale

		let isPortrait = UIScreen.isPortraitMode
		let category: MonitorResolutionCategory = screenWidth < screenHeight ? .pixelAlignedPortrait : .pixelAlignedLandscape

		var resolutions = [MonitorResolutionOption]()
		for scale in (1..<screenScale + 1) {
			let height = pixelHeight / scale
			let width = pixelWidth / scale

			let scaleString = "Scale: \(scale)x"

			let nativeScaleString = scale == screenScale ? " (native scale)" : ""

			let neededForBootSequenceString = scale == screenScale && margins == nil ? "\nNeeded for boot sequence. Cannot be deselected." : ""

			let orientationString = isPortrait ? "vertical" : "horizontal"
			let marginString = margins != nil ? "\nWith \(orientationString) margins" : ""

			let auxillaryInformation = scaleString + nativeScaleString + neededForBootSequenceString + marginString

			resolutions.append(
				.init(
					category: category,
					resolution: .init(width: width, height: height),
					auxillaryInformation: auxillaryInformation
				)
			)
		}

		return resolutions.reversed()
	}

	private static func getScaledToFitResolution(forHeight height: Int, margins: Margins? = nil) -> MonitorResolutionOption {
		let screenSize = getLandscapeModeSize()
		let widthToHeightRatio = screenSize.width / screenSize.height
		let width: Int
		if let margins {
			width = Int(CGFloat(height) * margins.ratioWithFixedSide())
		} else {
			width = Int(CGFloat(height) * widthToHeightRatio)
		}

		let auxillaryInformation = margins != nil ? "With horizontal margins" : nil
		return .init(
			category: .standardHeightLandscape,
			resolution: .init(width: width, height: height),
			auxillaryInformation: auxillaryInformation
		)
	}

	private static func getScaledToFitResolution(forWidth width: Int, margins: Margins? = nil) -> MonitorResolutionOption {
		let screenSize = getPortraitModeSize()
		let heightToWidthRatio = screenSize.height / screenSize.width
		let height: Int
		if let margins {
			height = Int(CGFloat(width) * margins.ratioWithFixedSide())
		} else {
			height = Int(CGFloat(width) * heightToWidthRatio)
		}

		let auxillaryInformation = margins != nil ? "With vertical margins" : nil
		return .init(
			category: .standardWidthPortrait,
			resolution: .init(width: width, height: height),
			auxillaryInformation: auxillaryInformation
		)
	}

	private static func getPortraitModeSize() -> CGSize {
		let mainScreen = UIScreen.main
		let screenHeight = mainScreen.bounds.size.height
		let screenWidth = mainScreen.bounds.size.width
		if screenHeight > screenWidth {
			return .init(width: screenWidth, height: screenHeight)
		} else {
			return .init(width: screenHeight, height: screenWidth)
		}
	}

	private static func getLandscapeModeSize() -> CGSize {
		let portraitModeSize = getPortraitModeSize()
		return .init(width: portraitModeSize.height, height: portraitModeSize.width)
	}
}

extension MonitorResolutionCategory {
	var explanation: String {
		switch self {
		case .pixelAlignedPortrait,
				.pixelAlignedLandscape:
			"Resolutions that are pixel aligned with your device screen, for maximum crispness"
		case .standardResolution:
			"The most common Classic Mac OS resolutions, for maximum compatibility"
		case .standardHeightLandscape:
			"Resolutions with the most common Classic Mac OS screen heights, but fullscreen width"
		case .standardWidthPortrait:
			"Resolutions with the most common Classic Mac OS screen widths, but fullscreen height"
		}
	}
}

extension MonitorResolutionOption {
	var label: String {
		"\(resolution.width) x \(resolution.height)"
	}
}

extension MonitorResolutionManager.Margins {
	// Translate what the edge insets means in terms of dimension ratio, assuming the
	// "non-edge inset affected" side takes the full length
	func ratioWithFixedSide() -> CGFloat {
		if isPortrait {
			let portraitScreenSize = MonitorResolutionManager.getPortraitModeSize()
			let maxInset = max(edgeInsets.top, edgeInsets.bottom)
			let preferedTotalVerticalInset = maxInset*2
			let adjustedHeight = portraitScreenSize.height - preferedTotalVerticalInset
			return adjustedHeight / portraitScreenSize.width
		} else {
			let landscapeScreenSize = MonitorResolutionManager.getLandscapeModeSize()
			let maxInset = max(edgeInsets.left, edgeInsets.right)
			let preferedTotalHorizontalInset = maxInset*2
			let adjustedWidth = landscapeScreenSize.width - preferedTotalHorizontalInset
			return adjustedWidth / landscapeScreenSize.height
		}
	}
}
