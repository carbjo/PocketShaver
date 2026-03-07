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

	@MainActor
	private func presentAlertVC() async {
		let sizeString = PreferencesGeneralRamSetting.current.label

		let notificationAuthorizationStatus = await getNotificationAuthorizationStatus()
		let shouldRequestNotificationAuthorization = notificationAuthorizationStatus == .notDetermined

		var message = "The request for allocating \(sizeString) of RAM memory failed. PocketShaver needs to restart.\n\nUsually, one or two restarts will result in the operating system granting the RAM allocation."
		if shouldRequestNotificationAuthorization {
			message += "\n\nPocketShaver will now ask for notification permission. If granted, a notification is displayed that makes restarting the app a bit easier."
		}

		let alertVC = UIAlertController(
			title: "The operating system refused the RAM memory allocation",
			message: message,
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Restart", style: .default, handler: { _ in
			Task { @MainActor in
				if shouldRequestNotificationAuthorization {
					do {
						try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
					} catch {
						print("- presentAlertVC \(error)")
					}
				}
				await UNUserNotificationCenter.current().scheduleRebootNotificationAndQuit()
			}
		}))

		present(alertVC, animated: true)
	}

	nonisolated func getNotificationAuthorizationStatus() async -> UNAuthorizationStatus {
			await UNUserNotificationCenter.current()
				.notificationSettings()
				.authorizationStatus
		}

	@objc public static func present() {
		let vc = RamAllocFailedAlertViewController()

		let window = UIWindow()

		window.rootViewController = vc
		window.makeKeyAndVisible()
	}
}
