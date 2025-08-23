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

	private let requestedRamMB: Int

	init(requestedRamMB: Int) {
		self.requestedRamMB = requestedRamMB

		super.init(nibName: nil, bundle: nil)
	}

	private var sizeString: String {
		if requestedRamMB % 1024 == 0 {
			let requestedGB = requestedRamMB / 1024
			return "\(requestedGB) GB"
		} else {
			let requestedMB = requestedRamMB
			return "\(requestedMB) MB"
		}
	}

	required init?(coder: NSCoder) { fatalError() }

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
		let alertVC = UIAlertController(
			title: "The operating system refused the RAM memory allocation",
			message: "The request for allocating \(sizeString) of RAM memory failed. SheepShaver needs to restart.\n\nUsually, one or two restarts will result in the operating system granting the RAM allocation.\n If not, consider lowering the amount of RAM in the settings.\n\nPress Ok to restart.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default, handler: { [weak self] _ in
			Task { @MainActor in
				await self?.scheduleRebootNotificationAndQuit()
			}
		}))

		return alertVC
	}

	private func scheduleRebootNotificationAndQuit() async {
		let content = UNMutableNotificationContent()
		content.body = "Tap to restart SheepShaver"

		let oneSecondIntoTheFuture = Date(timeInterval: 1, since: Date())
		let trigger = UNTimeIntervalNotificationTrigger(timeInterval: oneSecondIntoTheFuture.timeIntervalSinceNow, repeats: false)


		let request = UNNotificationRequest(identifier: "reboot", content: content, trigger: trigger)
		do {
			try await UNUserNotificationCenter.current().add(request)
			exit(0)
		} catch {
			print("schedule error \(error)")
		}
	}

	@objc public static func present(withRequestedRamMB requestedRamMB: Int) {
		let vc = RamAllocFailedAlertViewController(requestedRamMB: requestedRamMB)

		let win = UIWindow()

		win.rootViewController = vc
		win.makeKeyAndVisible()
	}
}
