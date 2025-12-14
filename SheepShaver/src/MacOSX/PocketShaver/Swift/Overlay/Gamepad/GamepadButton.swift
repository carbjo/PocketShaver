//
//  Gamepad.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

@objc public enum SpecialButton: Int, Codable, CaseIterable {
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
	static var length: CGFloat {
		if UIScreen.isSmallSize {
			return 64
		}
		return UIScreen.isPortraitMode ? 78 : 80
	}

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

		let length = GamepadButton.length

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

	override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
		bounds.insetBy(dx: -2, dy: -4).contains(point)
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
