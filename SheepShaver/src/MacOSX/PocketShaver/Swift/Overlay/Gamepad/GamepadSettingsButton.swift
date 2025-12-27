//
//  GamepadSettingsButton.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-26.
//

import UIKit

class GamepadSettingsButton: UIButton {

	static var length: CGFloat {
		UIScreen.isSmallSize ? 36 : 44
	}

	static let verticalScreenPositionRatio: CGFloat = 0.7

	init() {
		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		var configuration = UIButton.Configuration.defaultConfig
		configuration.contentInsets = .zero
		configuration.baseBackgroundColor = .lightGray.withAlphaComponent(0.9)
		self.configuration = configuration
		self.setImage(UIImage(resource: .gearshape), for: .normal)
		self.isHidden = true
	}

	required init?(coder: NSCoder) { fatalError() }
}
