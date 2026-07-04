//
//  Extensions.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

extension UIView {
	static func withoutConstraints() -> Self {
		let view = Self()
		view.translatesAutoresizingMaskIntoConstraints = false
		return view
	}

	static func keyWindowSafeAreaInsets(from view: UIView) -> UIEdgeInsets {
		guard let windows = view.window?.windowScene?.windows,
			  let keyWindow = windows.first(where: \.isKeyWindow) else {
			return .zero
		}

		return keyWindow.safeAreaInsets
	}
}

extension NSObject {
	var ptrString: String {
		"\(Unmanaged.passUnretained(self).toOpaque())"
	}
}

extension UISegmentedControl {
	// Named distinctly from `withoutConstraints()` (declared on UIView) since
	// Swift can't override a static method declared in another extension.
	static func withVisibleSelection() -> Self {
		let segmentedControl = withoutConstraints()

		#if targetEnvironment(macCatalyst)
		// Mac Catalyst's Mac idiom fills the selected segment with a flat
		// system gray that barely stands out from the unselected segments;
		// use the app's accent color so the selection is actually visible.
		segmentedControl.selectedSegmentTintColor = Colors.primaryButton
		#endif

		return segmentedControl
	}
}

extension UISwitch {
	static func withAccentOnTint() -> Self {
		let uiSwitch = withoutConstraints()
		// Use the app's orange accent for the on-state, matching the segmented
		// controls and radio selections instead of the system green/blue.
		uiSwitch.onTintColor = Colors.primaryButton
		return uiSwitch
	}
}

extension UIScreen {
	static var isPortraitMode: Bool {
		main.bounds.height > main.bounds.width
	}

	static var hasNotch: Bool {
		let screenHeight = main.nativeBounds.height
		let notchlessDevicesHeights: [CGFloat] = [480, 960, 1136, 1334, 1920, 2208]

		return !notchlessDevicesHeights.contains(screenHeight)
	}

	static let sideMarginForButtons: CGFloat = 8

	static var isSmallSize: Bool {
		if UIDevice.isIPadIdiom {
			return false
		}

		return !hasNotch
	}

	static var isSESize: Bool {
		let deviceWidth = main.nativeBounds.width
		return deviceWidth == 640
	}

	@MainActor
	static var supportsHighRefreshRate: Bool {
		return main.maximumFramesPerSecond > 60
	}

	static var portraitModeSize: CGSize {
		let mainScreen = main
		let screenHeight = mainScreen.bounds.size.height
		let screenWidth = mainScreen.bounds.size.width
		if screenHeight > screenWidth {
			return .init(width: screenWidth, height: screenHeight)
		} else {
			return .init(width: screenHeight, height: screenWidth)
		}
	}

	static var landscapeModeSize: CGSize {
		let portraitModeSize = self.portraitModeSize
		return .init(width: portraitModeSize.height, height: portraitModeSize.width)
	}

	/// Height in points of the Mac camera-housing (notch) / menu-bar strip on Mac
	/// Catalyst — where UIKit does NOT surface it as a safe-area inset — sourced from
	/// AppKit's NSScreen via `catalyst_screen_top_inset()`. Zero off Catalyst and on
	/// notchless / external displays.
	static var macCatalystNotchInset: CGFloat {
		#if targetEnvironment(macCatalyst)
		return CGFloat(catalyst_screen_top_inset())
		#else
		return 0
		#endif
	}

	/// Landscape / portrait screen size with the Mac Catalyst camera-housing strip
	/// removed from the physical-vertical dimension, so pixel-aligned resolutions
	/// occupy the usable area below the notch — parity with Designed-for-iPad, whose
	/// `bounds` already exclude it. Identical to the plain sizes off Catalyst and on
	/// notchless / external displays (`macCatalystNotchInset` is 0 there).
	static var pixelAlignedLandscapeSize: CGSize {
		var size = landscapeModeSize
		size.height -= macCatalystNotchInset
		return size
	}

	static var pixelAlignedPortraitSize: CGSize {
		var size = portraitModeSize
		size.width -= macCatalystNotchInset
		return size
	}
}

enum DeviceType {
	case iPhone
	case iPad
	case mac
}

extension UIDevice {
	static var isIPadIdiom: Bool {
		current.userInterfaceIdiom == .pad
	}

	static var deviceType: DeviceType {
		#if targetEnvironment(macCatalyst)
		// Mac Catalyst IS a Mac app, but ProcessInfo.isiOSAppOnMac is false here
		// (that flag is only true for "Designed for iPad" apps). Detect Catalyst
		// explicitly so all the app's existing `.mac` behaviour applies —
		// notably suppressing the on-screen gamepad and its (main-thread,
		// full-window) thumbnail rendering.
		return .mac
		#else
		if ProcessInfo.processInfo.isiOSAppOnMac {
			return .mac
		} else if current.userInterfaceIdiom == .pad {
			return .iPad
		} else {
			return .iPhone
		}
		#endif
	}

	static var isSimulator: Bool {
#if targetEnvironment(simulator)
		return true
#else
		return false
#endif
	}

	/// True when running as "Designed for iPad" (or Mac Catalyst) on macOS.
	/// The on-screen gamepad is pointless there — the user has a real keyboard
	/// and mouse/trackpad.
	static let isiOSAppOnMac: Bool = {
		if #available(iOS 14.0, *) {
			return ProcessInfo.processInfo.isiOSAppOnMac
		}
		return false
	}()
}

extension CGVector {
	static func +(lhs: Self, rhs: Self) -> Self {
		.init(dx: lhs.dx + rhs.dx, dy: lhs.dy + rhs.dy)
	}

	static func +=(lhs: inout Self, rhs: Self) {
		lhs = lhs + rhs
	}

	var abs: CGFloat {
		sqrt(dx*dx + dy*dy)
	}
}

extension UIButton.Configuration {
	@MainActor
	static var defaultConfig: Self {
		var configuration = UIButton.Configuration.filled()
		configuration.baseForegroundColor = .white
		configuration.baseBackgroundColor = .lightGray.withAlphaComponent(0.5)
		let horizontalInsets: CGFloat = UIScreen.isSmallSize ? 8 : 16
		configuration.contentInsets = NSDirectionalEdgeInsets(
			top: 0,
			leading: horizontalInsets,
			bottom: 0,
			trailing: horizontalInsets
		)
		configuration.background.cornerRadius = 8
		return configuration
	}

	@MainActor
	static var primaryActionConfig: Self {
		var config = defaultConfig
		config.baseBackgroundColor = Colors.primaryButton
		return config
	}

	@MainActor
	static var secondaryActionConfig: Self {
		var config = defaultConfig
		config.baseBackgroundColor = Colors.secondaryButton
		return config
	}
}

extension UIButton {
   func setTargetWidth(_ width: CGFloat) {
	   let totalMargin: CGFloat = width - image(for: .normal)!.size.width
	   let margin = totalMargin / 2
	   configuration!.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
   }
}

extension FileManager {
	// On the (unsandboxed) Mac Catalyst build we deliberately store all app data
	// under the app's container Data directory
	// (~/Library/Containers/<bundle-id>/Data) rather than the user's visible
	// home, to keep it out of casual sight and reduce accidental corruption.
	// Kept byte-identical to utils_ios.mm's pocketshaver_home_directory() so
	// Swift and the emulator core agree on the same container path.
	// NSHomeDirectory() (not FileManager.homeDirectoryForCurrentUser, which is
	// unavailable on Mac Catalyst) returns the real user home here because the
	// build is unsandboxed.
	static var pocketShaverHome: URL {
		let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
		let bundleID = Bundle.main.bundleIdentifier ?? "com.carbjo.pocketshaver"
		return home
			.appendingPathComponent("Library/Containers", isDirectory: true)
			.appendingPathComponent(bundleID, isDirectory: true)
			.appendingPathComponent("Data", isDirectory: true)
	}

	@objc
	static var documentUrl: URL {
		#if targetEnvironment(macCatalyst)
		return pocketShaverHome.appendingPathComponent("Documents")
		#else
		return Self.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		#endif
	}

	static var appSupportUrl: URL {
		#if targetEnvironment(macCatalyst)
		return pocketShaverHome.appendingPathComponent("Library/Application Support")
		#else
		return Self.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		#endif
	}
}

extension UIAlertController {
	static func with(title: String, message: String) -> Self {
		let alertVC = Self(title: title, message: message, preferredStyle: .alert)
		alertVC.addAction(.init(title: "Ok", style: .default))
		return alertVC
	}

	static func withMessage(_ message: String) -> Self {
		let alertVC = Self(title: nil, message: message, preferredStyle: .alert)
		alertVC.addAction(.init(title: "Ok", style: .default))
		return alertVC
	}

	static func withError(_ error: Error) -> Self {
		return withMessage("Something went wrong: \(error.localizedDescription)")
	}
}

extension String {
	var lastPathComponent: String {
		(self as NSString).lastPathComponent
	}

	var pathExtension: String {
		(self as NSString).pathExtension
	}

	func hasSuffixMatchingSuffixes(in suffixes: [String]) -> Bool {
		for fileExtension in suffixes {
			if hasSuffix(fileExtension) {
				return true
			}
		}
		return false
	}

	func substring(from: Int, to: Int) -> String {
		String(self[index(startIndex, offsetBy: from)..<index(startIndex, offsetBy: to)])
	}
}

extension NSLayoutConstraint {
	func withPriority(_ priority: UILayoutPriority) -> Self {
		self.priority = priority

		return self
	}
}

extension UITableViewCell {
	func hideSeparator() {
		separatorInset = .init(top: 0, left: 4000, bottom: 0, right: 0)
	}
}

extension UNUserNotificationCenter {
	func scheduleRebootNotificationAndQuit() async {
		let content = UNMutableNotificationContent()
		content.body = "Tap to restart PocketShaver"

		let oneSecondIntoTheFuture = Date(timeInterval: 1, since: Date())
		let trigger = UNTimeIntervalNotificationTrigger(timeInterval: oneSecondIntoTheFuture.timeIntervalSinceNow, repeats: false)


		let request = UNNotificationRequest(identifier: "reboot", content: content, trigger: trigger)
		do {
			try await self.add(request)
		} catch {
			print("schedule error \(error)")
		}

		exit(0)
	}
}

extension UITableViewCell {
	static var reuseIdentifier: String {
		NSStringFromClass(self)
	}
}

extension UITableViewCell {
	static func register(in tableView: UITableView) {
		tableView.register(self, forCellReuseIdentifier: reuseIdentifier)
	}
}

extension UIApplication {
	static var safeAreaInsets: UIEdgeInsets {
		shared.windows.first!.safeAreaInsets
	}
}

extension ImageResource {
	func asSymbolImage() -> UIImage {
		UIImage(resource: self).asSymbolImage()
	}
}

extension UIImage {
	func asSymbolImage() -> UIImage {
		withRenderingMode(.alwaysTemplate)
			.applyingSymbolConfiguration(.init(pointSize: 12))!
	}
}

extension UIImage {
	func withUltraLightConfiguration() -> UIImage? {
		let symbolConfiguration = UIImage.SymbolConfiguration(weight: .ultraLight)
		return applyingSymbolConfiguration(symbolConfiguration)
	}
}

extension UIViewController {
	func embed(_ childVC: UIViewController) {
		childVC.willMove(toParent: self)

		addChild(childVC)
		view.addSubview(childVC.view)

		NSLayoutConstraint.activate([
			childVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			childVC.view.topAnchor.constraint(equalTo: view.topAnchor),
			childVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			childVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])

		childVC.didMove(toParent: self)
	}
}

extension Data {
	func printHexString() {
		for i in 0..<count {
			print(String(format:"%02x", self[i]), terminator: "")
		}
		print("")
	}
}

protocol ImageDerivable: UIView {
	var resolutionMultiplier: CGFloat { get }

	func asImage() -> UIImage
}

extension ImageDerivable {
	var resolutionMultiplier: CGFloat {
		switch UIDevice.deviceType {
			// Will render in quadruple resolution when run on mac due to
			// default resolution being way too blurry
		case .mac:
			return 4
		default:
			return 1
		}
	}

	func asImage() -> UIImage {
		switch UIDevice.deviceType {
		case .mac:
			asQuadrupleResolutionImage()
		default:
			asDefaultResolutionImage()
		}
	}

	private func asDefaultResolutionImage() -> UIImage {
		let renderer = UIGraphicsImageRenderer(bounds: bounds)
		return renderer.image { rendererContext in
			layer.render(in: rendererContext.cgContext)
		}
	}

	private func asQuadrupleResolutionImage() -> UIImage {
		let renderer = UIGraphicsImageRenderer(
			bounds: .init(
				origin: .init(
					x: 0,
					y: bounds.size.height / 2
				),
				size: .init(
					width: bounds.size.width,
					height: bounds.size.height / resolutionMultiplier
			 )
			)
		)

		let height = self.bounds.height

		return renderer.image { rendererContext in
			rendererContext.cgContext.translateBy(x: 0, y: height / 2)
			rendererContext.cgContext.scaleBy(
				x: 1 / resolutionMultiplier,
				y: 1 / resolutionMultiplier
			)
			layer.render(in: rendererContext.cgContext)
		}
	}
}
