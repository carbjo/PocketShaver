//
//  PreferencesRelativeMouseModeOnboarding.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-25.
//

import UIKit

class PreferencesRelativeMouseModeOnboardingCell: UITableViewCell {
	private lazy var contentLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText
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

		setupContent()
	}

	required init?(coder: NSCoder) { fatalError() }

	private func setupContent() {
		let toggleOnText: String
		switch UIDevice.deviceType {
		case .iPhone:
			toggleOnText = "By the <img/> button, located on top of the software keyboard. The software keyboard is accessed by swiping up with three fingers.\nThis button can also be added to a gamepad and toggled from there."
		case .iPad:
			toggleOnText = "By the <img/> button, located on top of the software keyboard. The software keyboard is accessed by swiping up with three fingers.\nThis button can also be added to a gamepad and toggled from there.\nAlternatively, you can toggle it by pressing option + F5, if using a hardware keyboard."
		case .mac:
			toggleOnText = "By pressing option + F5 (during emulation)."
		}

		var steerSection = """

<mark>How do I steer with relative mouse mode on?</mark>

When using bluetooth mouse on iPad, just use the mouse normally.
When using touch input on iPhone or iPad, the mouse can be steered by either simply dragging with one finger or by mouse joystick in Gamepad mode.
"""

		var anySoftwareElaboration = " But it is not always the most convenient steering method. If the software does not require it, consider using Two finger finger steering, as an alternative."

		if UIDevice.deviceType == .mac {
			steerSection = ""
			anySoftwareElaboration = ""
		}

		contentLabel.attributedText =
"""
<mark>What is relative mouse mode?</mark>

When relative mouse mode is enabled, the input (touch or mouse) is no longer processed in terms of absolute position on the screen but rather only in relation to the previous mouse input value. 

This is necessary in some games and software where it must be possible to limitlessly steer with the mouse in a single direction, such as in 3D games.

You will notice when software you are running is requiring relative mouse mode when steering the mouse does nothing unless relative mouse mode is toggled on.

<mark>How do I toggle it on / off?</mark>

\(toggleOnText)
\(steerSection)

<mark>How does automatic mode work?</mark>

PocketShaver listens to certain mouse abilities registration when software is launching. If such abilities are found and the software launched has less than 32-bit color, it will toggle on relative mouse mode.
It will then toggle it off as soon as it is back in 32-bit color mode.
Some software can trigger relative mouse mode, even though the software itself does not require it. It is recommended that you use Manual setting, if this an issue.

<mark>Can any software be run with relative mouse mode on?</mark>

Yes.\(anySoftwareElaboration)
""".withTagsReplaced(
	by: .init(
		boldAppearance: .init(
			font: .boldSystemFont(ofSize: 14),
			color: Colors.primaryText
		),
		highlightedAppearance: .init(
			font: .boldSystemFont(ofSize: 18),
			color: Colors.primaryText
		),
		images: [ImageResource.arrowUpAndDownAndArrowLeftAndRight.asSymbolImage()]
	)
)
	}
}

class PreferencesRelativeMouseModeOnboardingViewController: UITableViewController {
	private lazy var doneButton: DoneButton = {
		DoneButton(target: self, selector: #selector(doneButtonPressed))
	}()

	override func viewDidLoad() {
		super.viewDidLoad()

		navigationItem.rightBarButtonItem = doneButton
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		1
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		PreferencesRelativeMouseModeOnboardingCell()
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	@objc
	private func doneButtonPressed() {
		dismiss(animated: true)
	}
}
