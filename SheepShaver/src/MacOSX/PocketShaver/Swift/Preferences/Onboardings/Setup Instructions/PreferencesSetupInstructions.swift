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
		let warningTriangle = ImageResource.exclamationmarkTriangle.asSymbolImage()
		label.attributedText =
  """
1. Select a compatible Mac OS install disc to bootstrap PocketShaver (check 'Compatibility list' to see which install discs can be used for this).

2. Select 'Create empty disk' (recommended minimum size is around 500 MB) and let mount toggle be on.

3. Import a Mac OS install disc file and toggle on Mount. This does not have to be the same disk image as in step 1. But in general, it must be a OS version equal or higher to what you used in the bootstrapping process. The maximum Mac OS version PocketShaver supports is <b>9.0.4</b> and is recommended if you are planning to use network.

4. Boot, let Mac OS format your empty virtual harddrive and launch <mark>Mac OS Installer</mark> app from the disc.

5. <b><img/> Important <img/></b> In the <mark>Mac OS Installer</mark> app, at 'Install software' step (not 'Select destination' step), Click button 'Options...' and uncheck <b>Update Apple Hard Disk Drivers</b> and install Mac OS.

6. After installation, restart PocketShaver, un-toggle Mount for Mac OS installation CD and boot.

7. Quit <mark>Mac OS Setup Assistant</mark> app. The assistant cannot be completed without getting stuck.

8. <b><img/> Important <img/></b> To get audio working, you have to explicitly select <b>Built-in</b> as Sound out option in the <mark>Sound</mark> control panel (not <mark>Sound and monitors</mark>), which, depending on Mac OS version, is either located in <mark>(Mac HD)</mark> <b>→</b> <mark>System Folder</mark> <b>→</b> <mark>Control Panels</mark> or <mark>(Mac HD)</mark> <b>→</b> <mark>Apple Extras</mark> <b>→</b> <mark>Sound Control Panel</mark>. This only has to be done once.
""".withTagsReplaced(
	by: .init(
		boldAppearance: .init(
			font: .boldSystemFont(ofSize: 14),
			color: Colors.primaryText
		),
		highlightedAppearance: .init(
			font: Fonts.geneva.ofSize(14)!,
			color: Colors.primaryText
		),
		images: [
			warningTriangle,
			warningTriangle,
			warningTriangle,
			warningTriangle
		]
	)
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

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	@objc
	private func doneButtonPressed() {
		dismiss(animated: true)
	}
}
