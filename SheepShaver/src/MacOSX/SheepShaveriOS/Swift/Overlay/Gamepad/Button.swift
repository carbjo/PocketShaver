//
//  Button.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class Button: UIButton {
	private lazy var buttonConfig: UIButton.Configuration = {
		var configuration = UIButton.Configuration.filled()
	 configuration.baseForegroundColor = .white
	 configuration.baseBackgroundColor = .lightGray.withAlphaComponent(0.5)
	 configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
	 configuration.background.cornerRadius = 8
	 return configuration
 }()

	private let key: SDLKey
	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)

	init(
		key: SDLKey,
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void)
	) {
		self.key = key
		self.pushKey = pushKey
		self.releaseKey = releaseKey

		super.init(frame: .zero)

		configuration = buttonConfig
		setTitle(key.label, for: .normal)

		let length: CGFloat = UIDevice.hasNotch ? 80 : 64

		NSLayoutConstraint.activate([
			widthAnchor.constraint(equalToConstant: length),
			heightAnchor.constraint(equalToConstant: length)
		])

		addTarget(self, action: #selector(keyDown), for: .touchDown)
		addTarget(self, action: #selector(keyUp), for: .touchUpInside)
		addTarget(self, action: #selector(keyUp), for: .touchUpOutside)
	}
	
	required init?(coder: NSCoder) { fatalError() }

	@objc private func keyDown() {
		// TODO: Which value is dependent on keyboard layout is chosen in simlated OS.
		// Should not assume EN layout, specifically
		pushKey(key.enValue)
	}

	@objc private func keyUp() {
		releaseKey(key.enValue)
	}
}


