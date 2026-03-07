//
//  PreferencesCompatibilityListViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-12.
//

import UIKit

class PreferencesCompatibilityListViewController: UITableViewController {

	private let model = PreferencesCompatibilityModel()

	private lazy var doneButton: DoneButton = {
		DoneButton(target: self, selector: #selector(doneButtonPressed))
	}()

	override func viewDidLoad() {
		super.viewDidLoad()

		navigationItem.rightBarButtonItem = doneButton
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		model.entries.count + 1
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		if indexPath.row == 0 {
			return PreferencesCompatibilityListPrefaceCell()
		}

		let entry = model.entries[indexPath.row - 1]

		switch entry {
		case .newWorldRomVersion(let newWorldRomVersion):
			return PreferencesCompatibilityListCell(
				title: newWorldRomVersion.description,
				isCompatible: newWorldRomVersion.isBootstrapCompatible
			)
		case .other(let description):
			return PreferencesCompatibilityListCell(
				title: description,
				isCompatible: false
			)
		}
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	@objc
	private func doneButtonPressed() {
		dismiss(animated: true)
	}
}
