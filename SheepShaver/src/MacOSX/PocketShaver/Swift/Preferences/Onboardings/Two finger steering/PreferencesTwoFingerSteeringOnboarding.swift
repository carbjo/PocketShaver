//
//  PreferencesTwoFingerSteeringOnboarding.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-25.
//


import UIKit

class PreferencesTwoFingerSteeringOnboardingCell: UITableViewCell {
	private lazy var contentLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = Colors.secondaryText
		let handSymbol = ImageResource.handRaised.asSymbolImage()
		let justAboveSymbol = ImageResource.chevronCompactUp.asSymbolImage()
		let farAboveSymbol = ImageResource.arrowUp.asSymbolImage()
		let sidewaysSymbol = ImageResource.arrowLeftArrowRight.asSymbolImage()
		let diagonallyAboveSymbol = ImageResource.crossArrow.asSymbolImage()
		label.attributedText =
"""
<mark>How do I enable Two finger steering?</mark>

Make sure that one of the four hover modes is enabled (only one can be enabled at a time). This can be done by either toggling one of them on via a Gamepad button, or if 'Boot in hover mode' is selected in Preferences General tab.

The four hover modes and their Gamepad icons are
• Hover just above <img/><img/>
• Hover far above <img/><img/>
• Hover sideways <img/><img/>
• Hover diagonally above <img/><img/>

<mark>How do I use Two finger steering?</mark>

First, use one finger (which will be referred to it as the 'first finger') to move the position of the mouse. 
Then, for clicking down or releasing the mouse button, a second finger is used. The second finger is only for pressing and releasing. Do not move the second finger to move the mouse, only the first finger.
It is strongly recommended to use your thumbs, on opposite sides of the screen, as first and second finger. Two finger steering is designed with that setup in mind.

<mark>How do I reach all the areas of the screen with my cursor?</mark>

In addition to clicking, the second finger can also be quickly swiped, if Second finger swipe is enabled. This will change the cursors offset from the first finger.
Since the 'sideways' and 'diagonally above' offset is in terms of which horizontal half of the screen the first finger is placed upon, this makes it possible to quickly swap between six different possible offset positions:
• Just above finger on left side (just above)
• Near the top on left side (far above)
• Near vertical middle and above horizontal middle of the screen (diagonally above)
• Near vertical middle and above the bottom of the screen (sideways)
• Just above finger on right side (just above)
• Near the top on right side (far above)

With these six possible offset positions, it should be quite easy to find one of them that can reach the cursor to the position you want, without obscuring the cursor itself with any of the two fingers. Going from one offset position to another never requires more than one second finger swipe, or switch between first finger (preferably thumb on left side, thumb on right side).

<mark>Can I drag something on the screen for a long distance / mark a large area?</mark>

Yes.

1. Place first finger where you want to start drag.
2. Press down with second finger.
3. Drag first finger until you can't reach further.
4. Release first finger (but keep second finger down), reposition and drag first finger again as many times as necessary.
5. When done, release second finger.

<mark>When using just above offset, the cursor is not 'just above' my finger. It is too far away or too near.</mark>

The vertical offset of just above can be adjusted in Preferences under Advanced tab.

<mark>I noticed the horizontal offset for Hover sideways and diagonally above are slightly lower than for just above and far above. Why is this?</mark>

This is intentional.
• Diagonally above is slightly lower than far above to get the cursor near the middle of the screen, where often a lot of the interaction happens.
• Sideways is quite a bit lower than just above to easily reach everything at the lower part of the screen, including reaching to the horizontal opposite side of the screen, since just above is not possible to use in order to reach the very bottom.
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
		images: [
			handSymbol, justAboveSymbol,
			handSymbol, farAboveSymbol,
			handSymbol, sidewaysSymbol,
			handSymbol, diagonallyAboveSymbol
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

class PreferencesTwoFingerSteeringOnboardingViewController: UITableViewController {
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
		PreferencesTwoFingerSteeringOnboardingCell()
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	@objc
	private func doneButtonPressed() {
		dismiss(animated: true)
	}
}
