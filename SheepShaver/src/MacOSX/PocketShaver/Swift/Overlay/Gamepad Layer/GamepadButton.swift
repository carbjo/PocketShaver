//
//  Gamepad.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit

class GamepadButton: UIButton {
	enum Label {
		case text(String)
		case icon(ImageResource)
		case twoIcons(ImageResource, ImageResource)
	}

	static var length: CGFloat {
		if UIScreen.isSESize {
			return 65
		} else if UIScreen.isSmallSize {
			return 76
		}
		return UIScreen.isPortraitMode ? 78 : 80
	}

	private lazy var iconStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .horizontal
		stackView.isUserInteractionEnabled = false
		return stackView
	}()

	private let didPush: (() -> Void)
	private let didRelease: (() -> Void)
	private let didRequestAssignment: (() -> Void)

	private var isEditing: Bool = false

	init(
		label: Label,
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

		switch label {
		case .text(let text):
			setTitle(text, for: .normal)
		case .icon(let icon):
			setImage(.init(resource: icon), for: .normal)
		case .twoIcons(let icon1, let icon2):
			iconStackView.addArrangedSubview(createImageView(forIcon: icon1))
			iconStackView.addArrangedSubview(createImageView(forIcon: icon2))
			addSubview(iconStackView)

			NSLayoutConstraint.activate([
				iconStackView.centerXAnchor.constraint(equalTo: centerXAnchor),
				iconStackView.centerYAnchor.constraint(equalTo: centerYAnchor)
			])
			break
		}

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

	private func createImageView(forIcon icon: ImageResource) -> UIImageView {
		let imageView = UIImageView(image: .init(resource: icon))
		imageView.tintColor = .white
		return imageView
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

extension SpecialButton {
	var gamepadLabel: GamepadButton.Label {
		switch self {
		case .mouseClick: return .icon(.cursorarrowRays)
		case .hover: return .icon(.handRaised)
		case .hoverAbove: return.twoIcons(.handRaised, .arrowUp)
		case .hoverBelow: return.twoIcons(.handRaised, .arrowDown)
		case .cmdW: return .text("⌘-W")
		default:
			return .text(label)
		}
	}
}
