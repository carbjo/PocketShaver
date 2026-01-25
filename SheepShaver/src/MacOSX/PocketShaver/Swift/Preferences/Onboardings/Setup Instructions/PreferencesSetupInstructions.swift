//
//  PreferencesSetupInstructions.swift
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
		label.textColor = Colors.secondaryText
		label.attributedText =
  """
1. Select a compatible Mac OS install disc to bootstrap PocketShaver (check 'Compatibility list' to see which install discs can be used for this).

2. Create an empty disk of reasonable size and toggle on Mount.

3. Import a Mac OS install disc file and toggle on Mount and CDROM. This does not have to be the same disk image as in step 1. But in general, it must be a OS version equal or higher to what you used in the bootstrapping process. The maximum Mac OS version PocketShaver supports is <b>9.0.4</b>.

4. Boot, let Mac OS format your empty virtual harddrive and launch 'Mac OS Installer' app from the disc.

5. In the 'Mac OS Installer' app, at <b>Install software</b> step (not 'Select destination' step), Click button <b>Options...</b> and uncheck <b>Update Apple Hard Disk Drivers</b>. If you do not do this, the installation will get completely stuck on a phase with title 'Updating Apple Hard Disk Drivers'.

6. After installation, restart PocketShaver, un-toggle Mount for Mac OS installation CD and boot.

7. Quit 'Mac OS Setup Assistant' app (since one of the later steps in it, involving network detection, will get the Assistant app and the OS stuck).

8. To get audio working, you have to explicitly select <b>Built-in</b> as Sound out option in the <b>Sound</b> control panel (not 'Sound and monitors'), which, depending on Mac OS version, is either located in <b> (Mac HD) → System Folder → Control Panels</b> or <b> (Mac HD) → Apple Extras → Sound Control Panel</b>. This only has to be done once.
""".withTagsReplaced(by: .init(boldAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.primaryText)))

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

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	@objc
	private func doneButtonPressed() {
		dismiss(animated: true)
	}
}
