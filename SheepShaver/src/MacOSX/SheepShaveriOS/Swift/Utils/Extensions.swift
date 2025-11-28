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
		main.bounds.height > UIScreen.main.bounds.width
	}
}

extension UIDevice {
	static var hasNotch: Bool {
		let screenHeight = UIScreen.main.nativeBounds.height
		let notchlessDevicesHeights: [CGFloat] = [480, 960, 1136, 1334, 1920, 2208]

		return !notchlessDevicesHeights.contains(screenHeight)
	}

	static var sideMarginForButtons: CGFloat {
		if UIScreen.isPortraitMode {
			return 8
		} else {
			return hasNotch ? 64 : 8
		}
	}

	static var isSmallScreenSize: Bool {
		if isIPad {
			return false
		}

		return !hasNotch
	}

	static var isIPad: Bool {
		current.userInterfaceIdiom == .pad
	}

	static var isNarrowWidth: Bool {
		let deviceWidth = UIScreen.main.nativeBounds.width
		return deviceWidth == 640
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
		let horizontalInsets: CGFloat = UIDevice.isSmallScreenSize ? 8 : 16
		configuration.contentInsets = NSDirectionalEdgeInsets(
			top: 0,
			leading: horizontalInsets,
			bottom: 0, trailing: horizontalInsets
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

extension FileManager {
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
		return withMessage("Soemthing went wrong: \(error.localizedDescription)")
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


extension String {
	func withBoldTagsReplacedWith(font: UIFont, color: UIColor) -> NSAttributedString {
		let attrString = NSMutableAttributedString()
		var workString = self

		while let beginningTagIndex = workString.range(of: "<b>"),
			  let endTagIndex = workString.range(of: "</b>") {
			let prefix = String(workString[workString.startIndex..<beginningTagIndex.lowerBound])
			let boldPart = String(workString[beginningTagIndex.upperBound..<endTagIndex.lowerBound])

			attrString.append(.init(string: prefix))
			attrString.append(
				.init(
					string: boldPart,
					attributes: [
						.font: font,
						.foregroundColor: color
					]
				)
			)

			workString = String(workString[endTagIndex.upperBound..<workString.endIndex])
		}

		attrString.append(.init(string: workString))

		return attrString
	}
}
