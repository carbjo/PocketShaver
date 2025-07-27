//
//  UnassignedButton.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-27.
//

import UIKit

class UnassignedButton: UIView {
	init() {
		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false

		let length: CGFloat = UIDevice.hasNotch ? 80 : 64

		NSLayoutConstraint.activate([
			widthAnchor.constraint(equalToConstant: length),
			heightAnchor.constraint(equalToConstant: length)
		])
	}
	
	required init?(coder: NSCoder) { fatalError() }
}
