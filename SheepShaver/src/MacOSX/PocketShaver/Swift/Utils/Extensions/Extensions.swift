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
		if UIDevice.isIPad {
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
}

extension UIDevice {
	static var isIPad: Bool {
		current.userInterfaceIdiom == .pad
	}

	static var isSimulator: Bool {
#if targetEnvironment(simulator)
		return true
#else
		return false
#endif
	}
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
	@objc
	static var documentUrl: URL {
		Self.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
	}

	static var appSupportUrl: URL {
		Self.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
		UIImage(resource: self)
			.withRenderingMode(.alwaysTemplate)
			.applyingSymbolConfiguration(.init(pointSize: 12))!
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

// Source - https://stackoverflow.com/a/41288197
// Posted by Naveed J., modified by community. See post 'Timeline' for change history
// Retrieved 2026-01-31, License - CC BY-SA 4.0

extension UIView {

	func asImage() -> UIImage {
		let renderer = UIGraphicsImageRenderer(bounds: bounds)
		return renderer.image { rendererContext in
			layer.render(in: rendererContext.cgContext)
		}
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
