//
//  PreferencesSetupInstructionsViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-15.
//

import UIKit

class PreferencesSetupInstructionsCell: UITableViewCell {
	private lazy var contentLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = .darkGray
		label.attributedText =
  """
1. Select a compatible Mac OS install disk to bootstrap PocketShaver.

2. Create an empty disk of reasonable size and toggle on Mount.

3. (Optional) If you want to use a different OS install disk than what was used to boostrap PocketShaver, import a Mac OS installation CD disk file (a version between 7.5 up to 9.0.4) and toggle on Mount and CDROM.

4. (Optional) Toggle on a monitor resolution of your liking in Resolutions tab and switch off the ones you do not want during installation. The operating system will always use the highest available during installation, without possibility to change it. Keep in mind, older OS versions are less likely to support high resolutions and might crash.

5. Critical for when installing Mac OS 8.0 or higher: In the Mac OS Installer app, at <b>Install software</b> step (not 'Select destination' step), Click button <b>Options...</b> and uncheck <b>Update Apple Hard Disk Drivers</b>. If you do not do this, there is a high risk the installation will get completely stuck in the beginning on a phase with title 'Updating Apple Hard Disk Drivers'.

6. Restart PocketShaver, un-toggle Mount for Mac OS installation CD and boot.

7. If audio is not working, you have to explicitly select <b>Built-in</b> as Sound out option in the <b>Sound</b> control panel (not 'Sound and monitors'), which, depending on Mac OS version, is either in <b>System Folder → Control Panels</b> or <b>Apple Extras → Sound Control Panel</b>.
""".withBoldTagsReplacedWith(
	font: .boldSystemFont(ofSize: 14),
	color: .black
)

		return label
	}()

	init() {
		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(contentLabel)

		NSLayoutConstraint.activate([
			contentLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
			contentLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			contentLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
			contentLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesSetupInstructionsViewController: UITableViewController {
	private lazy var doneButton: UIBarButtonItem = {
		UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(doneButtonPressed))
	}()

	override func viewDidLoad() {
		super.viewDidLoad()

		navigationItem.rightBarButtonItem = doneButton
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		1
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		PreferencesSetupInstructionsCell()
	}

	@objc
	private func doneButtonPressed() {
		dismiss(animated: true)
	}
}
