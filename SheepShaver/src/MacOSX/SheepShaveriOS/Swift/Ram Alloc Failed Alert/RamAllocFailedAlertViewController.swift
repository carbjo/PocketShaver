//
//  RamAllocFailedAlertViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-23.
//

import UIKit
import UserNotifications

@objc
public class RamAllocFailedAlertViewController: UIViewController {

	public override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		Task { @MainActor in
			await presentAlertVC()
		}
	}

	private func presentAlertVC() async {
		do {
			try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
			let alertVC = createAlertVC()
			present(alertVC, animated: true)
		} catch {
			print("- presentAlertVC \(error)")
		}
	}

	private func createAlertVC() -> UIAlertController {
		let sizeString = PreferencesGeneralRamSetting.current.label

		let alertVC = UIAlertController(
			title: "The operating system refused the RAM memory allocation",
			message: "The request for allocating \(sizeString) of RAM memory failed. SheepShaver needs to restart.\n\nUsually, one or two restarts will result in the operating system granting the RAM allocation.\n If not, consider lowering the amount of RAM in the settings.\n\nPress Ok to restart.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Restart (recommended)", style: .default, handler: { _ in
			Task { @MainActor in
				await UNUserNotificationCenter.current().scheduleRebootNotificationAndQuit()
			}
		}))

		alertVC.addAction(.init(title: "Lower RAM and restart", style: .destructive, handler: { _ in
			Task { @MainActor in
				PreferencesGeneralRamSetting.current = .n128
				await UNUserNotificationCenter.current().scheduleRebootNotificationAndQuit()
			}
		}))

		return alertVC
	}

	@objc public static func present() {
		let vc = RamAllocFailedAlertViewController()

		let window = UIWindow()

		window.rootViewController = vc
		window.makeKeyAndVisible()
	}
}
