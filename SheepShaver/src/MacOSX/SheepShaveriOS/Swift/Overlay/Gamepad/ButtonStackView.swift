//
//  ButtonStackView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class ButtonStackView: UIStackView {
	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)
	
	init(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		self.pushKey = pushKey
		self.releaseKey = releaseKey

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		axis = .horizontal
		spacing = 4
	}
	
	required init(coder: NSCoder) { fatalError() }

	func add(_ key: SDLKey) {
		addArrangedSubview(
			Button(
				key: key,
				pushKey: pushKey,
				releaseKey: releaseKey
			)
		)
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		// Only consider touches to the buttons or spacing cells as
		// touches that belongs to this stack view.
		// Ie. not when touching the spaces between the buttons or spacing cells.

		for view in arrangedSubviews {
			guard let button = view as? Button else {
				continue
			}
			let pointInSubviewCoordinateSpace = button.convert(point, from: self)
			if button.point(inside: pointInSubviewCoordinateSpace, with: event) {
				return true
			}
		}

		return false
	}
}
