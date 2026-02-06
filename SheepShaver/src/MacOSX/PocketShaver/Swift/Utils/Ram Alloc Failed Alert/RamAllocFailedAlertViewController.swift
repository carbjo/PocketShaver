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

		let canLowerRam = PreferencesGeneralRamSetting.current == .n256 || PreferencesGeneralRamSetting.current == .n512

		let notificationAuthorizationStatus = await getNotificationAuthorizationStatus()
		let shouldRequestNotificationAuthorization = notificationAuthorizationStatus == .notDetermined

		var message = "The request for allocating \(sizeString) of RAM memory failed. PocketShaver needs to restart.\n\nUsually, one or two restarts will result in the operating system granting the RAM allocation."
		if canLowerRam {
			message += "\nIf not, consider lowering the amount of RAM in the settings."
		}
		if shouldRequestNotificationAuthorization {
			message += "\n\nPocketShaver will now ask for notification permission. If granted, a notification is displayed that makes restarting the app a bit easier."
		}

		var primaryActionTitle = "Restart"
		if canLowerRam {
			primaryActionTitle += " (recommended)"
		}

		let alertVC = UIAlertController(
			title: "The operating system refused the RAM memory allocation",
			message: message,
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: primaryActionTitle, style: .default, handler: { _ in
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

		if canLowerRam {
			alertVC.addAction(.init(title: "Lower RAM and restart", style: .destructive, handler: { _ in
				Task { @MainActor in
					if shouldRequestNotificationAuthorization {
						do {
							try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
						} catch {
							print("- presentAlertVC \(error)")
						}
					}

					PreferencesGeneralRamSetting.current = .n128
					PreferencesManager.shared.writePreferences()
					await UNUserNotificationCenter.current().scheduleRebootNotificationAndQuit()
				}
			}))
		}

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
