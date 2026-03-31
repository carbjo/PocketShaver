//
//  Gamepad.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-26.
//

import UIKit
import Combine

class GamepadButton: UIButton {
	enum Label {
		case text(String)
		case icon(ImageResource)
		case thinIcon(ImageResource)
		case twoIcons(ImageResource, ImageResource)
	}

	private lazy var iconStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .horizontal
		stackView.isUserInteractionEnabled = false
		return stackView
	}()

	private let specialButtonConfig: SpecialButton?
	private let didPush: (() -> Void)
	private let didRelease: (() -> Void)
	private let didRequestAssignment: (() -> Void)

	private var isRelativeMouseModeEnabled: Bool
	private var isIPadMousePassthroughOn: Bool

	private var isEditing: Bool = false
	private var isToggledOn: Bool = false

	private var anyCancellables = Set<AnyCancellable>()

	init(
		label: Label,
		buttonSize: GamepadButtonSize,
		specialButtonConfig: SpecialButton? = nil,
		inputInteractionModel: InputInteractionModel,
		isEditing: Bool,
		pushKey: @escaping (() -> Void),
		releaseKey: @escaping (() -> Void),
		didRequestAssignment: @escaping (() -> Void)
	) {
		self.specialButtonConfig = specialButtonConfig
		self.didPush = pushKey
		self.didRelease = releaseKey
		self.didRequestAssignment = didRequestAssignment
		self.isRelativeMouseModeEnabled = inputInteractionModel.isRelativeMouseModeEnabled
		self.isIPadMousePassthroughOn = inputInteractionModel.iPadMousePassthrough

		super.init(frame: .zero)

		configuration = .defaultConfig

		if buttonSize == .small {
			configuration!.contentInsets = .init(top: 0, leading: 2, bottom: 0, trailing: 2)
			configuration!.titleTextAttributesTransformer =
			   UIConfigurationTextAttributesTransformer { incoming in
				 var outgoing = incoming
				 outgoing.font = .systemFont(ofSize: 13)
				 return outgoing
			 }
		}

		switch label {
		case .text(let text):
			setTitle(text, for: .normal)
		case .icon(let icon):
			setImage(.init(resource: icon), for: .normal)
		case .thinIcon(let icon):
			setImage(.init(resource: icon).withUltraLightConfiguration(), for: .normal)
		case .twoIcons(let icon1, let icon2):
			iconStackView.addArrangedSubview(createImageView(forIcon: icon1))
			iconStackView.addArrangedSubview(createImageView(forIcon: icon2))
			addSubview(iconStackView)

			NSLayoutConstraint.activate([
				iconStackView.centerXAnchor.constraint(equalTo: centerXAnchor),
				iconStackView.centerYAnchor.constraint(equalTo: centerYAnchor)
			])
		}

		titleLabel?.textAlignment = .center

		let length = buttonSize.length

		NSLayoutConstraint.activate([
			widthAnchor.constraint(equalToConstant: length),
			heightAnchor.constraint(equalToConstant: length)
		])

		addTarget(self, action: #selector(keyDown), for: .touchDown)
		addTarget(self, action: #selector(keyUp), for: .touchUpInside)
		addTarget(self, action: #selector(keyUp), for: .touchUpOutside)

		addTarget(self, action: #selector(didTap), for: .touchUpInside)

		set(isEditing: isEditing)

		listenToChanges(from: inputInteractionModel)

		configure(isRelativeMouseModeEnabled: inputInteractionModel.isRelativeMouseModeEnabled)
		configure(isIPadMousePassthroughOn: inputInteractionModel.iPadMousePassthrough)
		configure(hoverOffsetMode: inputInteractionModel.hoverOffsetMode)
		configure(
			audioEnabled: inputInteractionModel.isAudioEnabled,
			hostAudioVolume: inputInteractionModel.hostAudioVolume
		)
	}
	
	required init?(coder: NSCoder) { fatalError() }

	private func listenToChanges(from inputInteractionModel: InputInteractionModel) {
		inputInteractionModel.changeSubject.sink{ [weak self] change in
			guard let self else { return }
			switch change {
			case .hoverOffsetModeChanged(let hoverOffsetMode):
				configure(hoverOffsetMode: hoverOffsetMode)
			case .relativeMouseModeChanged(let isEnabled):
				configure(isRelativeMouseModeEnabled: isEnabled)
			case .iPadMousePassthroughChanged(let isEnabled):
				configure(isIPadMousePassthroughOn: isEnabled)
			case .audioConfigurationChanged(let isEnabled, let hostAudioVolume):
				configure(audioEnabled: isEnabled, hostAudioVolume: hostAudioVolume)
			default: break
			}
		}.store(in: &anyCancellables)
	}

	func set(isEditing: Bool) {
		self.isEditing = isEditing
		updateColor()
	}

	private func configure(isRelativeMouseModeEnabled: Bool) {
		self.isRelativeMouseModeEnabled = isRelativeMouseModeEnabled
		if specialButtonConfig == .relativeMouseModeEnabled {
			isToggledOn = isRelativeMouseModeEnabled
		}
		updateColor()
	}

	private func configure(isIPadMousePassthroughOn: Bool) {
		self.isIPadMousePassthroughOn = isIPadMousePassthroughOn
		updateColor()
	}

	private func configure(hoverOffsetMode: HoverOffsetMode) {
		isToggledOn = isSelectedWith(hoverOffsetMode)
		updateColor()
	}

	private func configure(audioEnabled: Bool, hostAudioVolume: InputInteractionModel.HostAudioVolume) {
		guard specialButtonConfig == .audioEnabled else {
			return
		}

		let imageResource: ImageResource
		if audioEnabled {
			switch hostAudioVolume {
			case .low:
				imageResource = .speakerWave1
			case .mid:
				imageResource = .speakerWave2
			case .high:
				imageResource = .speakerWave3
			}
		} else {
			imageResource = .speakerSlash
		}
		let symbolConfiguration = UIImage.SymbolConfiguration(weight: .ultraLight)
		setImage(.init(resource: imageResource).withUltraLightConfiguration(), for: .normal)
	}

	override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
		bounds.insetBy(dx: -2, dy: -4).contains(point)
	}

	private func updateColor() {
		if !isActive {
			configuration?.baseBackgroundColor = .lightGray.withAlphaComponent(0.85)
			return
		}
		if isToggledOn {
			configuration?.baseBackgroundColor = .gray.withAlphaComponent(0.5)
		} else {
			configuration?.baseBackgroundColor = .lightGray.withAlphaComponent(0.5)
		}
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

extension GamepadButton {
	private var isActive: Bool {
		if isEditing {
			return false
		}
		if let specialButtonConfig,
		   (specialButtonConfig.isDisabledIfRelativeMouseMode && isRelativeMouseModeEnabled) ||
			(specialButtonConfig.isDisabledIfIPadMousePassthrough && isIPadMousePassthroughOn) {
			return false
		}

		return true
	}

	private func isSelectedWith(_ offsetMode: HoverOffsetMode) -> Bool {
		switch (specialButtonConfig, offsetMode) {
		case (.hoverDiagonallyToggle, .diagonallyAbove),
			(.hoverSidewaysToggle, .sideways),
			(.hoverFarAboveToggle, .farAbove),
			(.hoverJustAboveToggle, .justAbove):
			return true
		default:
			return false
		}
	}
}

extension SpecialButton {
	var isDisabledIfRelativeMouseMode: Bool {
		switch self {
		case .hoverJustAboveToggle, .hoverFarAboveToggle, .hoverSidewaysToggle, .hoverDiagonallyToggle:
			return true
		default:
			return false
		}
	}

	var isDisabledIfIPadMousePassthrough: Bool {
		switch self {
		case .hoverJustAboveToggle, .hoverFarAboveToggle, .hoverSidewaysToggle, .hoverDiagonallyToggle:
			return true
		default:
			return false
		}
	}
}

extension SpecialButton {
	var gamepadLabel: GamepadButton.Label {
		switch self {
		case .mouseClick: return .icon(.leftclick)
		case .hoverJustAboveToggle: return .twoIcons(.handRaised, .chevronCompactUp)
		case .hoverFarAboveToggle: return .twoIcons(.handRaised, .arrowUp)
		case .hoverSidewaysToggle: return .twoIcons(.handRaised, .arrowLeftArrowRight)
		case .hoverDiagonallyToggle: return .twoIcons(.handRaised, .crossArrow)
		case .cmdW: return .text("⌘-W")
		case .rightClick: return .icon(.rightclick)
		case .audioEnabled: return .icon(.speakerSlash) // placeholder
		case .relativeMouseModeEnabled: return .thinIcon(.arrowUpAndDownAndArrowLeftAndRight)
		}
	}
}
