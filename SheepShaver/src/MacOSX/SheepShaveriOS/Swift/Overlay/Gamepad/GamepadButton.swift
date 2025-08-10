//
//  Gamepad.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

@objc public enum SpecialButton: Int, Codable {
	case hover
	case hoverAbove
	case hoverBelow

	var label: String {
		switch self {
		case .hover: return "Hover"
		case .hoverAbove: return "Hover above"
		case .hoverBelow: return "Hover below"
		}
	}
}

class GamepadButton: UIButton {
	private let didPush: (() -> Void)
	private let didRelease: (() -> Void)
	private let didRequestAssignment: (() -> Void)

	private var isEditing: Bool = false

	init(
		text: String,
		isEditing: Bool,
		pushKey: @escaping (() -> Void),
		releaseKey: @escaping (() -> Void),
		didRequestAssignment: @escaping (() -> Void)
	) {
		self.didPush = pushKey
		self.didRelease = releaseKey
		self.didRequestAssignment = didRequestAssignment

		super.init(frame: .zero)

		configuration = .defaultConfig

		setTitle(text, for: .normal)
		titleLabel?.textAlignment = .center

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

		didPush()
	}

	@objc private func keyUp() {
		guard !isEditing else { return }
		
		didRelease()
	}

	@objc private func didTap() {
		if isEditing {
			didRequestAssignment()
		}
	}
}
