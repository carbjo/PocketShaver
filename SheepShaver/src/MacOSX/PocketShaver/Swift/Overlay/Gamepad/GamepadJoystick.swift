//
//  GamepadJoystick.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-17.
//

import UIKit

enum JoystickType: Codable, Equatable {
	case mouse
	case wasd
}

class GamepadJoystick: UIControl {
	enum Mode {
		case mouse((CGPoint) -> Void)
		case wasd((SDLKey, Bool) -> Void)
	}

	private lazy var backgroundCircleView: UIView = {
		let view = UIView.withoutConstraints()
		view.backgroundColor = .lightGray.withAlphaComponent(0.5)
		view.layer.cornerRadius = GamepadButton.length
		return view
	}()

	private lazy var stickCircleView: UIView = {
		let view = UIView.withoutConstraints()
		view.backgroundColor = .lightGray.withAlphaComponent(0.5)
		view.layer.cornerRadius = GamepadButton.length / 2
		return view
	}()

	private lazy var labelContainer: UIView = {
		let view = UIView.withoutConstraints()
		view.backgroundColor = .clear
		return view
	}()

	private lazy var relativeMouseOffWarningLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = label.font.withSize(16)
		label.text = "Relative mouse mode is off"
		label.textColor = .white
		label.textAlignment = .center
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private var isRelativeMouseModeOn: Bool
	private var isEditing: Bool
	private let mode: Mode
	private let didRequestAssignment: (() -> Void)

	private var augmentedBounds: CGRect {
		bounds.inset(
			by: .init(
				top: -4,
				left: -2,
				bottom: -4 - GamepadButton.length,
				right: -2 - GamepadButton.length
			)
		)
	}

	private var currentPoint: CGPoint?

	// Mouse mode variables
	private var fireTimer: Timer?
	private var fireTimerInterval: CGFloat = 1.0 / CGFloat(MiscellaneousSettings.current.frameRateSetting.frameRate)

	// WASD mode variables
	private var keysDown = Set<SDLKey>()

	private var isActive: Bool {
		if isEditing {
			return false
		}
		if case Mode.mouse = mode,
		   !isRelativeMouseModeOn {
			return false
		}
		return true
	}

	init(
		isRelativeMouseModeOn: Bool,
		isEditing: Bool,
		mode: Mode,
		didRequestAssignment: @escaping (() -> Void)
	) {
		self.isRelativeMouseModeOn = isRelativeMouseModeOn
		self.isEditing = isEditing
		self.mode = mode
		self.didRequestAssignment = didRequestAssignment

		super.init(frame: .zero)

		addSubview(backgroundCircleView)
		addSubview(stickCircleView)
		addSubview(labelContainer)
		labelContainer.addSubview(relativeMouseOffWarningLabel)

		let stackViewSlotLength = GamepadButton.length
		let joystickDiameter = GamepadButton.length * 2
		let stickDiameter = GamepadButton.length

		let labelContainerSideLength = floor(sqrt(2) * GamepadButton.length)

		NSLayoutConstraint.activate([
			backgroundCircleView.leadingAnchor.constraint(equalTo: leadingAnchor),
			backgroundCircleView.topAnchor.constraint(equalTo: topAnchor),
			backgroundCircleView.widthAnchor.constraint(equalToConstant: joystickDiameter),
			backgroundCircleView.heightAnchor.constraint(equalToConstant: joystickDiameter),
			stickCircleView.widthAnchor.constraint(equalToConstant: stickDiameter),
			stickCircleView.heightAnchor.constraint(equalToConstant: stickDiameter),
			labelContainer.centerXAnchor.constraint(equalTo: backgroundCircleView.centerXAnchor),
			labelContainer.centerYAnchor.constraint(equalTo: backgroundCircleView.centerYAnchor),
			labelContainer.widthAnchor.constraint(equalToConstant: labelContainerSideLength),
			labelContainer.heightAnchor.constraint(equalToConstant: labelContainerSideLength),
			relativeMouseOffWarningLabel.centerYAnchor.constraint(equalTo: labelContainer.centerYAnchor),
			relativeMouseOffWarningLabel.leadingAnchor.constraint(equalTo: labelContainer.leadingAnchor),
			relativeMouseOffWarningLabel.trailingAnchor.constraint(equalTo: labelContainer.trailingAnchor),

			widthAnchor.constraint(equalToConstant: stackViewSlotLength),
			heightAnchor.constraint(equalToConstant: stackViewSlotLength)
		])

		set(isRelativeMouseModeOn: isRelativeMouseModeOn)
		set(isEditing: isEditing)
	}

	required init?(coder: NSCoder) { fatalError() }


	override func layoutSubviews() {
		super.layoutSubviews()

		updateStickView()
	}

	func set(isRelativeMouseModeOn: Bool) {
		self.isRelativeMouseModeOn = isRelativeMouseModeOn
		updateColor()
		updateRelativeMouseOffWarningLabelVisiblity()
	}

	func set(isEditing: Bool) {
		self.isEditing = isEditing
		updateColor()
		updateRelativeMouseOffWarningLabelVisiblity()
	}

	override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
		augmentedBounds.contains(point)
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesBegan(touches, with: event)

		if !isActive {
			return
		}

		guard let touch = touchInside(touches) else {
			return
		}

		updateCurrentPoint(with: touch)

		resetFireTimer()

		fireTimer = .init(fire: .now, interval: fireTimerInterval, repeats: true, block: { [weak self] _ in
			DispatchQueue.main.async {
				self?.fireJoystick()
			}
		})

		RunLoop.current.add(fireTimer!, forMode: .default)
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesMoved(touches, with: event)

		if !isActive {
			return
		}

		guard let touch = touches.first else {
			return
		}

		updateCurrentPoint(with: touch)
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesEnded(touches, with: event)

		if isEditing,
		   touchInside(touches) != nil {
			didRequestAssignment()
		}

		resetCurrentPoint()

		resetFireTimer()
		resetKeysDown()
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesCancelled(touches, with: event)

		resetCurrentPoint()

		resetFireTimer()
		resetKeysDown()
	}

	private func touchInside(_ touches: Set<UITouch>) -> UITouch? {
		for touch in touches {
			if augmentedBounds.contains(touch.location(in: self)) {
				return touch
			}
		}

		return nil
	}

	@MainActor
	private func fireJoystick() {
		guard let currentPoint else {
			return
		}

		let dx = currentPoint.x - backgroundCircleView.center.x
		let dy = currentPoint.y - backgroundCircleView.center.y

		switch mode {
		case .mouse(let didFire):
			let scale: CGFloat = 0.1
			didFire(.init(x: dx * scale, y: dy * scale))

		case .wasd(let keyDownCallback):
			let angle = atan2(dy, dx)
			let newKeysDown = keysForAngle(angle)

			for key in newKeysDown {
				if !keysDown.contains(key) {
					keysDown.insert(key)
					keyDownCallback(key, true)
				}
			}
			for key in keysDown {
				if keysDown.contains(key),
				   !newKeysDown.contains(key) {
					keysDown.remove(key)
					keyDownCallback(key, false)
				}
			}
		}
	}

	private func updateCurrentPoint(with touch: UITouch) {
		let point = touch.location(in: self)

		let limit: CGFloat = 46

		let x = point.x - backgroundCircleView.center.x
		let y = point.y - backgroundCircleView.center.y

		let dist = sqrt(x * x + y * y)

		if dist < limit {
			currentPoint = point
		} else {
			let angle = atan2(y, x)
			let normalizedX = cos(angle) * limit
			let normalizedY = sin(angle) * limit
			currentPoint = .init(
				x: backgroundCircleView.center.x + normalizedX,
				y: backgroundCircleView.center.x + normalizedY
			)
		}

		updateStickView()
	}

	private func resetCurrentPoint() {
		currentPoint = nil
		updateStickView()
	}

	private func resetFireTimer() {
		if let fireTimer {
			fireTimer.invalidate()
			self.fireTimer = nil
		}
	}

	private func resetKeysDown() {
		guard case Mode.wasd(let keyDown) = mode else {
			return
		}

		for key in keysDown {
			keyDown(key, false)
		}

		keysDown.removeAll()
	}

	private func updateStickView() {
		if let currentPoint {
			stickCircleView.center = currentPoint
		} else {
			stickCircleView.center = backgroundCircleView.center
		}
	}

	private func updateColor() {
		let color: UIColor = isActive ? .lightGray.withAlphaComponent(0.5) : .lightGray.withAlphaComponent(0.85)
		backgroundCircleView.backgroundColor = color
		stickCircleView.backgroundColor = color
	}

	private func updateRelativeMouseOffWarningLabelVisiblity() {
		guard case Mode.mouse = mode else {
			relativeMouseOffWarningLabel.isHidden = true
			return
		}

		if isEditing {
			relativeMouseOffWarningLabel.isHidden = true
		} else {
			relativeMouseOffWarningLabel.isHidden = isRelativeMouseModeOn
		}
	}
}

private extension GamepadJoystick {
	func keysForAngle(_ angle: CGFloat) -> [SDLKey] {
		let twoPi = CGFloat.pi * 2

		var array = [SDLKey]()
		if angle > twoPi * (-3/16),
		   angle < twoPi * (3/16){
			array.append(.d)
		}
		if angle > twoPi * (1/16),
			angle < twoPi * (7/16) {
			array.append(.s)
		}
		if angle > twoPi * (5/16) ||
			angle < twoPi * (-5/16) {
			array.append(.a)
		}
		if angle > twoPi * (-7/16) &&
			angle < twoPi * (-1/16) {
			array.append(.w)
		}

		return array
	}
}
