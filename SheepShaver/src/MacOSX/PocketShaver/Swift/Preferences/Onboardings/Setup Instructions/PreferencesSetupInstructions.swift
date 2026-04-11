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
1. Bootstrap PocketShaver with a compatible Mac OS install disc file.

2. Select <img/> and 'Create empty disk' (recommended minimum size is around 500 MB).

3. Select <img/>\(UIDevice.deviceType == .mac ? " or <img/>" : "") and import a Mac OS install disc file and toggle on Mount. This does not have to be the same disk image as in step 1. But in general, it must be a OS version equal or higher to what you used in the bootstrapping process. The maximum Mac OS version PocketShaver supports is <b>9.0.4</b>.

4. Boot, let Mac OS format your empty virtual harddrive and launch <mark>Mac OS Installer</mark> app from the disc.

5. <b><img/> Important <img/></b> In the <mark>Mac OS Installer</mark> app, at 'Install software' step (not 'Select destination' step), Click button 'Options...' and uncheck <b>Update Apple Hard Disk Drivers</b> and install Mac OS.

6. After installation, restart PocketShaver, un-toggle mount for Mac OS installation CD and boot.

7. Quit <mark>Mac OS Setup Assistant</mark> app. The assistant cannot be completed without getting stuck.

8. <b><img/> Important <img/></b> To get audio working, you have to explicitly select <b>Built-in</b> as Sound out option in the <mark>Sound</mark> control panel (not <mark>Sound and monitors</mark>), which, depending on Mac OS version, is either located in <mark>(Mac HD)</mark> <b>→</b> <mark>System Folder</mark> <b>→</b> <mark>Control Panels</mark> or <mark>(Mac HD)</mark> <b>→</b> <mark>Apple Extras</mark> <b>→</b> <mark>Sound Control Panel</mark>. This only has to be done once.
""".withTagsReplaced(
	by: .init(
		highlightedAppearance: .init(
			font: Fonts.geneva.ofSize(14)!,
			color: Colors.primaryText
		),
		images: [
			Assets.plus,
			Assets.plus,
			UIDevice.deviceType == .mac ? Assets.folder : nil,
			warningTriangle,
			warningTriangle,
			warningTriangle,
			warningTriangle
		].compactMap({$0})
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
	private lazy var doneButton: DoneButton = {
		DoneButton(target: self, selector: #selector(doneButtonPressed))
	}()

	private var hasReadTimer: Timer?

	override func viewDidLoad() {
		super.viewDidLoad()

		navigationItem.rightBarButtonItem = doneButton

		hasReadTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
			Task { @MainActor in
				InformationConsumption.current.reportHasReadSetupInstructions()
			}
		}
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
