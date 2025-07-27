//
//  ButtonStackViewCollectionStackView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class ButtonStackViewCollectionStackView: UIStackView {

	init(
		alignment: UIStackView.Alignment,
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		axis = .vertical
		self.alignment = alignment
		spacing = 8

		setupStackViews(pushKey: pushKey, releaseKey: releaseKey)
	}
	
	required init(coder: NSCoder) { fatalError() }

	private func setupStackViews(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		let screenHeight = UIScreen.main.nativeBounds.height
		let length: CGFloat = UIDevice.hasNotch ? 80 : 64
		let stackViewHeight: CGFloat = length + 16

		let numberOfStackViews = Int(floor(screenHeight / stackViewHeight))

		for _ in 0..<numberOfStackViews {
			addArrangedSubview(
				ButtonStackView(
					pushKey: pushKey,
					releaseKey: releaseKey
				)
			)
		}
	}

	func add(_ key: SDLKey, row: Int) {
		let index = arrangedSubviews.count - 1 - row
		guard index >= 0,
			  let stackView = arrangedSubviews[index] as? ButtonStackView else {
			print("-- unexpected")
			return
		}

		stackView.add(key)
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		for view in arrangedSubviews {
			let pointInSubviewCoordinateSpace = view.convert(point, from: self)
			if view.point(inside: pointInSubviewCoordinateSpace, with: event) {
				return true
			}
		}

		return false
	}
}
