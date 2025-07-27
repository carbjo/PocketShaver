//
//  ButtonStackViewCollectionStackView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class ButtonStackViewCollectionStackView: UIStackView {

	init(
		isRightHandSide: Bool,
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		axis = .vertical
		alignment = isRightHandSide ? .trailing : .leading
		spacing = 8

		setupStackViews(
			isRightHandSide: isRightHandSide,
			pushKey: pushKey,
			releaseKey: releaseKey
		)
	}
	
	required init(coder: NSCoder) { fatalError() }

	private func setupStackViews(
		isRightHandSide: Bool,
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		let screenHeight = UIScreen.main.bounds.height
		let length: CGFloat = UIDevice.hasNotch ? 80 : 64
		let stackViewHeight: CGFloat = length + (spacing * 2)

		let numberOfStackViews = Int(floor(screenHeight / stackViewHeight))

		for _ in 0..<numberOfStackViews {
			addArrangedSubview(
				ButtonStackView(
					isRightHandSide: isRightHandSide,
					pushKey: pushKey,
					releaseKey: releaseKey
				)
			)
		}
	}

	func set(_ key: SDLKey, row: Int, index: Int) {
		let orientationCorrectedIndex = arrangedSubviews.count - 1 - row // Build from bottom to top
		guard orientationCorrectedIndex >= 0,
			  let stackView = arrangedSubviews[orientationCorrectedIndex] as? ButtonStackView else {
			print("-- unexpected")
			return
		}

		stackView.set(key, at: index)
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
