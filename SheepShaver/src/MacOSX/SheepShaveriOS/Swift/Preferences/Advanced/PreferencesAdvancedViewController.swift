//
//  PreferencesAdvancedViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit

class PreferencesAdvancedViewController: UIViewController {
	override func viewDidLoad() {
		super.viewDidLoad()

		view.translatesAutoresizingMaskIntoConstraints = false
		view.backgroundColor = .white

		let label = UILabel.withoutConstraints()
		label.text = "Advanced"

		view.addSubview(label)

		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
		])
	}
}
