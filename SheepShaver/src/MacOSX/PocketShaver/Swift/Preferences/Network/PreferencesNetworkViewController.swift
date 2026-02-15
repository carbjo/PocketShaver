//
//  PreferencesNetworkViewController.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-15.
//

import UIKit

class PreferencesNetworkViewController: UITableViewController {
	override func viewDidLoad() {
		super.viewDidLoad()

		let label = UILabel.withoutConstraints()

		label.text = "Network"

		view.addSubview(label)

		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
		])

		view.translatesAutoresizingMaskIntoConstraints = false
	}
}
