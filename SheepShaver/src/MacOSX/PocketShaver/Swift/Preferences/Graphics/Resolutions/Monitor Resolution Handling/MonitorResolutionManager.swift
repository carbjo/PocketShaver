//
//  MonitorResolutions.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-18.
//

import UIKit

enum MonitorResolutionCategory: String, Codable, Equatable, CaseIterable, Hashable {
	case pixelAlignedPortrait
	case pixelAlignedLandscape
	case standardResolution
	case standardWidthPortrait
	case standardHeightLandscape
}

struct MonitorResolution: Codable, Equatable, Hashable {
	let width: Int
	let height: Int
}

struct MonitorResolutionOption: Codable, Equatable, Hashable {
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
	private var maxWidth480HeightWithMarginsResolution: MonitorResolutionOption?

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

	private var bootFromCDPortraitResolutions: [MonitorResolutionOption] {
		return [availableResolutions[.pixelAlignedPortrait]![0],
				availableResolutions[.standardResolution]![0]]
	}

	private var bootFromCDLandscapeResolutions: [MonitorResolutionOption] {
		return [availableResolutions[.pixelAlignedLandscape]![0],
				maxWidth480HeightWithMarginsResolution ?? availableResolutions[.standardResolution]![0]]
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
		UIScreen.portraitModeSize.width / UIScreen.portraitModeSize.height == 3/4
	}

	var enabledResolutions: [MonitorResolutionOption] {
		if willLaunchInPortraitMode {
			if DiskManager.shared.willBootFromCD {
				return bootFromCDPortraitResolutions
			} else {
				return enabledPortraitResolutions
			}
		} else {
			if DiskManager.shared.willBootFromCD {
				return bootFromCDLandscapeResolutions
			} else {
				return enabledLandscapeResolutions
			}
		}
	}

	/// The always-on boot resolution — the native-scale, pixel-aligned mode the UI marks
	/// "cannot be deselected / needed for boot sequence" — for the launch orientation,
	/// freshly detected from the current display each launch (never a persisted copy).
	/// `availableResolutions` is rebuilt from the live screen in init(), so this always
	/// reflects the current device; `isResolutionAlwaysEnabled` pins this same value.
	private var freshBootResolutionOption: MonitorResolutionOption? {
		let category: MonitorResolutionCategory = willLaunchInPortraitMode ? .pixelAlignedPortrait : .pixelAlignedLandscape
		return availableResolutions[category]?.first
	}

	/// The resolution PocketShaver records into the "screen" pref to boot into. Sourced
	/// from `freshBootResolutionOption` — the freshly-detected "cannot be deselected"
	/// pixel-aligned mode — not the live UIScreen point size and not a stale persisted
	/// value. On Mac Catalyst the pixel-aligned modes are already computed from the
	/// camera-housing-excluded screen size (see `UIScreen.pixelAligned*Size`), so this
	/// boots the usable-below-the-notch resolution without any extra trim here.
	var bootScreenResolution: MonitorResolution {
		return freshBootResolutionOption?.resolution
			?? enabledResolutions.first?.resolution
			?? MonitorResolution(width: Int(UIScreen.main.bounds.width), height: Int(UIScreen.main.bounds.height))
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
			enabledPortraitResolutions = Self.withRefreshedBootResolution(persistedEnabledPortraitResolutions, category: .pixelAlignedPortrait, available: availableResolutions)
		} else {
			enabledPortraitResolutions = [
				availableResolutions[.pixelAlignedPortrait]![0],
				availableResolutions[.standardResolution]![0],
				availableResolutions[.standardResolution]![1]
			]
		}

		if let persistedEnabledLandscapeResolutionsData = Storage.shared.load(from: .landscapeResolutions),
		   let persistedEnabledLandscapeResolutions = try? decoder.decode([MonitorResolutionOption].self, from: persistedEnabledLandscapeResolutionsData) {
			enabledLandscapeResolutions = Self.withRefreshedBootResolution(persistedEnabledLandscapeResolutions, category: .pixelAlignedLandscape, available: availableResolutions)
		} else {
			enabledLandscapeResolutions = [
				availableResolutions[.pixelAlignedLandscape]![0],
				availableResolutions[.standardResolution]![0],
				availableResolutions[.standardResolution]![1]
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

	func registerSafeAreaInsets(_ safeAreaInsets: UIEdgeInsets) {
		let largestInset = [safeAreaInsets.left, safeAreaInsets.top, safeAreaInsets.right, safeAreaInsets.bottom].max()!

		guard !hasRegisteredSafeAreaInsets else {
			return
		}
		hasRegisteredSafeAreaInsets = true

		let isStatusbarInsetOnly = safeAreaInsets.top == 20 && safeAreaInsets.bottom == 0
		let hasInsets = !isStatusbarInsetOnly && largestInset > 0

		if hasInsets { // status bar alone does not count, since it will be hidden
			let portraitMargins = Margins(isPortrait: true, edgeInsets: .init(top: largestInset, left: 0, bottom: largestInset, right: 0))
			availableResolutions[.pixelAlignedPortrait]!.append(contentsOf: Self.getPixelAlignedResolutions(size: UIScreen.portraitModeSize, margins: portraitMargins))
			availableResolutions[.standardWidthPortrait]!.append(Self.getScaledToFitResolution(forWidth: 640, margins: portraitMargins))
			availableResolutions[.standardWidthPortrait]!.append(Self.getScaledToFitResolution(forWidth: 800, margins: portraitMargins))

			
			let landscapeMargins = Margins(isPortrait: false, edgeInsets: .init(top: 0, left: largestInset, bottom: 0, right: largestInset))
			let maxWidth480HeightWithMarginsResolution = Self.getScaledToFitResolution(forHeight: 480, margins: landscapeMargins)

			availableResolutions[.pixelAlignedLandscape]!.append(contentsOf: Self.getPixelAlignedResolutions(size: UIScreen.landscapeModeSize, margins: landscapeMargins))
			availableResolutions[.standardHeightLandscape]!.append(maxWidth480HeightWithMarginsResolution)
			availableResolutions[.standardHeightLandscape]!.append(Self.getScaledToFitResolution(forHeight: 600, margins: landscapeMargins))
			self.maxWidth480HeightWithMarginsResolution = maxWidth480HeightWithMarginsResolution

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

		return
	}

	@objc
	public func getAllSDLVideoMonitorResolutionElements() -> [SDLVideoMonitorResolutionElement] {
		var resolutions = enabledResolutions.map({ $0.resolution })
		resolutions = Array(resolutions.prefix(10))

		// The first enabled resolution is the pixel-aligned "cannot be deselected"
		// boot entry. Force it to exactly match `bootScreenResolution` (which the
		// screen pref is written from), so the guest always boots a mode that is
		// present in VModes[]. This also carries the Catalyst safe-area (menu bar /
		// notch) trim into the registered mode list, keeping pref == VMode entry.
		if !resolutions.isEmpty {
			resolutions[0] = bootScreenResolution
		}

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

	/// Refresh a persisted enabled list against the freshly-detected pixel-aligned modes for
	/// the current display, and guarantee the always-on boot resolution (the first pixel-aligned
	/// entry — the one the UI marks "cannot be deselected") is present. Persisted entries carry
	/// concrete pixel dimensions, so any pixel-aligned entry saved on a previous display or a
	/// pre-notch build would otherwise show stale values in the UI and diverge from what the
	/// guest receives (e.g. a Mac Catalyst 1x mode saved as 4112x2658 before the camera-housing
	/// strip was excluded, now 4112x2582). Every persisted entry of `category` is re-matched to
	/// the current option by the notch-invariant axis — width in landscape, height in portrait,
	/// since the camera housing only trims the other axis — keeping `enabledResolutions` the
	/// single fresh source of truth read by both the Preferences UI and the SDL mode list.
	private static func withRefreshedBootResolution(
		_ persisted: [MonitorResolutionOption],
		category: MonitorResolutionCategory,
		available: [MonitorResolutionCategory: [MonitorResolutionOption]]
	) -> [MonitorResolutionOption] {
		guard let freshList = available[category], let freshBoot = freshList.first else { return persisted }
		let isLandscape = category == .pixelAlignedLandscape
		var list = persisted.map { option -> MonitorResolutionOption in
			guard option.category == category else { return option }
			let match = freshList.first {
				isLandscape ? $0.resolution.width == option.resolution.width
							: $0.resolution.height == option.resolution.height
			}
			return match ?? option
		}
		if !list.contains(where: { $0 == freshBoot }) {
			if let index = list.firstIndex(where: { $0.category == category }) {
				list[index] = freshBoot
			} else {
				list.insert(freshBoot, at: 0)
			}
		}
		return list
	}

	private static func getAvailableResolutions(for category: MonitorResolutionCategory) -> [MonitorResolutionOption] {
		switch category {
		case .pixelAlignedPortrait:
			return Self.getPixelAlignedResolutions(size: UIScreen.pixelAlignedPortraitSize)
		case .pixelAlignedLandscape:
			return Self.getPixelAlignedResolutions(size: UIScreen.pixelAlignedLandscapeSize)
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
			if size.height > size.width {
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
		let screenSize = UIScreen.landscapeModeSize
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
		let screenSize = UIScreen.portraitModeSize
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
}

extension MonitorResolutionCategory {
	var description: String {
		switch self {
		case .pixelAlignedPortrait, .pixelAlignedLandscape:
			return "Pixel aligned"
		case .standardResolution:
			return "Common Classic Mac OS"
		case .standardWidthPortrait:
			return "Standard width fullscreen"
		case .standardHeightLandscape:
			return "Standard height fullscreen"
		}
	}
	
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
			let portraitScreenSize = UIScreen.portraitModeSize
			let maxInset = max(edgeInsets.top, edgeInsets.bottom)
			let preferedTotalVerticalInset = maxInset*2
			let adjustedHeight = portraitScreenSize.height - preferedTotalVerticalInset
			return adjustedHeight / portraitScreenSize.width
		} else {
			let landscapeScreenSize = UIScreen.landscapeModeSize
			let maxInset = max(edgeInsets.left, edgeInsets.right)
			let preferedTotalHorizontalInset = maxInset*2
			let adjustedWidth = landscapeScreenSize.width - preferedTotalHorizontalInset
			return adjustedWidth / landscapeScreenSize.height
		}
	}
}
