//
//  StikDebugSetupInstructions.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-10-25.
//


import UIKit

class StikDebugSetupInstructionsCell: UITableViewCell {
	private lazy var contentLabel: LinkLabel = {
		let text: String
		if #available(iOS 26.0, *) {
text = """
How to enable JIT:

1. Install StikDebug according to the instructions described in section "How to enable JIT" at their <link>GitHub page</link>.

(This step involves installing StikDebug, LocalDevVPN and using iloader to perform initial setup for StikDebug.)

2. (iOS 26+) In StikDebug, long press PocketShaver and select Assign script and select universal.js (only has to be done once).

3. Turn on VPN in LocalDevVPN and launch PocketShaver from StikDebug (instead of from iOS home screen).

Once PocketShaver is launched with JIT enabled, you can switch back and forth to PocketShaver without having to use the StikDebug app.
"""
		} else {
			text = """
How to enable JIT:

1. Install StikDebug according to the instructions described in section "How to enable JIT" at their <link>GitHub page</link>.

(This step involves installing StikDebug, LocalDevVPN and using iloader to perform initial setup for StikDebug.)

2. Turn on VPN in LocalDevVPN and launch PocketShaver from StikDebug (instead of from iOS home screen).

Once PocketShaver is launched with JIT enabled, you can switch back and forth to PocketShaver without having to use the StikDebug app.
"""
		}
		let label = LinkLabel(
			text: text,
			config: .init()
		) {
			let url = URL(string: "https://github.com/StikDebug/StikDebug#how-to-enable-jit")!
			UIApplication.shared.open(url)
		}
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

class StikDebugSetupInstructionsViewController: UITableViewController {
	private lazy var doneButton: DoneButton = {
		DoneButton(target: self, selector: #selector(doneButtonPressed))
	}()

	private var hasReadTimer: Timer?

	override func viewDidLoad() {
		super.viewDidLoad()

		navigationItem.rightBarButtonItem = doneButton
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		1
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		StikDebugSetupInstructionsCell()
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	@objc
	private func doneButtonPressed() {
		dismiss(animated: true)
	}
}
