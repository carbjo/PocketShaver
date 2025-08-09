//
//  KeyButton.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class KeyButton: UIButton {
	private let key: SDLKey
	private let index: Int
	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)
	private let didRequestAssignmentAtIndex: ((Int) -> Void)

	private var isEditing: Bool = false

	init(
		key: SDLKey,
		index: Int,
		isEditing: Bool,
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void),
		didRequestAssignmentAtIndex: @escaping ((Int) -> Void)
	) {
		self.key = key
		self.index = index
		self.pushKey = pushKey
		self.releaseKey = releaseKey
		self.didRequestAssignmentAtIndex = didRequestAssignmentAtIndex

		super.init(frame: .zero)

		configuration = .defaultConfig

		setTitle(key.label, for: .normal)

		let length: CGFloat = UIDevice.hasNotch ? 80 : 64

		NSLayoutConstraint.activate([
			widthAnchor.constraint(equalToConstant: length),
			heightAnchor.constraint(equalToConstant: length)
		])

		addTarget(self, action: #selector(keyDown), for: .touchDown)
		addTarget(self, action: #selector(keyUp), for: .touchUpInside)
		addTarget(self, action: #selector(keyUp), for: .touchUpOutside)

		addTarget(self, action: #selector(didTap), for: .touchUpInside)

		set(isEditing: isEditing)
	}
	
	required init?(coder: NSCoder) { fatalError() }

	func set(isEditing: Bool) {
		self.isEditing = isEditing
		configuration?.baseBackgroundColor = isEditing ? .lightGray.withAlphaComponent(0.85) : .lightGray.withAlphaComponent(0.5)
	}

	@objc private func keyDown() {
		guard !isEditing else { return }

		// TODO: Which value is dependent on keyboard layout is chosen in simlated OS.
		// Should not assume EN layout, specifically
		pushKey(key.enValue)
	}

	@objc private func keyUp() {
		guard !isEditing else { return }
		
		releaseKey(key.enValue)
	}

	@objc private func didTap() {
		if isEditing {
			didRequestAssignmentAtIndex(index)
		}
	}
}
