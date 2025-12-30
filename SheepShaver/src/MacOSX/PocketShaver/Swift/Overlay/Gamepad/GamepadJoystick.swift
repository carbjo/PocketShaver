//
//  GamepadJoystick.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-17.
//

import UIKit

enum JoystickType: Codable, Equatable {
	case mouse
	case wasd4way
	case wasd8way
}

class GamepadJoystick: UIControl {
	enum Mode {
		case mouse((CGPoint) -> Void)
		case wasd(WasdJoystickType, (SDLKey, Bool) -> Void)
	}

	enum WasdJoystickType {
		case fourWay
		case eightWay
	}

	private lazy var backgroundCircleView: UIView = {
		BackgroundCircleView(
			mode: mode,
			radius: GamepadButton.length
		)
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

		case .wasd(let wasdType, let keyDownCallback):
			let angle = atan2(dy, dx)
			let newKeysDown = keysForAngle(angle, type: wasdType)

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
			let normalizedVector = limitNormalizedVector(
				limit: 46,
				vector: .init(dx: x, dy: y)
			)
			currentPoint = .init(
				x: backgroundCircleView.center.x + normalizedVector.dx,
				y: backgroundCircleView.center.x + normalizedVector.dy
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
		guard case Mode.wasd(_, let keyDown) = mode else {
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
	func keysForAngle(_ angle: CGFloat, type: WasdJoystickType) -> [SDLKey] {
		let twoPi = CGFloat.pi * 2

		var array = [SDLKey]()

		switch type {
		case .fourWay:
			if angle > twoPi * (-2/16),
			   angle < twoPi * (2/16){
				array.append(.d)
			}
			if angle > twoPi * (2/16),
				angle < twoPi * (6/16) {
				array.append(.s)
			}
			if angle > twoPi * (6/16) ||
				angle < twoPi * (-6/16) {
				array.append(.a)
			}
			if angle > twoPi * (-6/16) &&
				angle < twoPi * (-2/16) {
				array.append(.w)
			}
		case .eightWay:
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
		}

		return array
	}
}

private class BackgroundCircleView: UIView {

	private let radius: CGFloat
	private let linesLayer = CALayer()

	init(
		mode: GamepadJoystick.Mode,
		radius: CGFloat
	) {

		self.radius = radius

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		backgroundColor = .lightGray.withAlphaComponent(0.5)
		layer.cornerRadius = radius

		layer.addSublayer(linesLayer)

		if case GamepadJoystick.Mode.wasd(let wasdType, _) = mode {
			drawSegmentLines(type: wasdType)
			addMaskAndInnerCircle()
			addWasdLabels()
		}
	}

	required init?(coder: NSCoder) { fatalError() }

	private func drawSegmentLines(type: GamepadJoystick.WasdJoystickType) {
		let twoPi = CGFloat.pi * 2

		let layers: [CALayer]
		switch type {
		case .fourWay:
			layers = [
			   lineLayer(startAngle: twoPi * (-2 / 16), endAngle: twoPi * (6 / 16)),
			   lineLayer(startAngle: twoPi * (2 / 16), endAngle: twoPi * (10 / 16)),
			   lineLayer(startAngle: twoPi * (6 / 16), endAngle: twoPi * (14 / 16)),
			   lineLayer(startAngle: twoPi * (-6 / 16), endAngle: twoPi * (2 / 16))
		   ]
		case .eightWay:
			layers = [
			   lineLayer(startAngle: twoPi * (-3 / 16), endAngle: twoPi * (5 / 16)),
			   lineLayer(startAngle: twoPi * (1 / 16), endAngle: twoPi * (9 / 16)),
			   lineLayer(startAngle: twoPi * (5 / 16), endAngle: twoPi * (13 / 16)),
			   lineLayer(startAngle: twoPi * (-7 / 16), endAngle: twoPi * (1 / 16)),
			   lineLayer(startAngle: twoPi * (3 / 16), endAngle: twoPi * (11 / 16)),
			   lineLayer(startAngle: twoPi * (7 / 16), endAngle: twoPi * (15 / 16)),
			   lineLayer(startAngle: twoPi * (-5 / 16), endAngle: twoPi * (3 / 16)),
			   lineLayer(startAngle: twoPi * (-1 / 16), endAngle: twoPi * (7 / 16))
		   ]
		}

		for layer in layers {
			linesLayer.addSublayer(layer)
		}
	}

	private func addMaskAndInnerCircle() {
		let twoThirdRadius = radius * (2/3)
		let offset = radius - twoThirdRadius
		let circleLayer = CAShapeLayer()

		let outerCirclePath = UIBezierPath(
			roundedRect: CGRect(
				x: 0, y: 0,
				width: 2.0 * radius, height: 2.0 * radius
			),
			cornerRadius: radius
		)
		let innerCirclePath = UIBezierPath(
			roundedRect: CGRect(
				x: offset, y: offset,
				width: 2.0 * twoThirdRadius, height: 2.0 * twoThirdRadius
			),
			cornerRadius: twoThirdRadius
		)
		outerCirclePath.append(innerCirclePath)

		circleLayer.path = outerCirclePath.cgPath
		circleLayer.fillColor = UIColor.black.cgColor
		circleLayer.fillRule = .evenOdd

		linesLayer.mask = circleLayer

		let innerCircleLayer = CAShapeLayer()
		innerCircleLayer.path = innerCirclePath.cgPath
		innerCircleLayer.fillColor = nil
		innerCircleLayer.opacity = 0.45
		innerCircleLayer.strokeColor = UIColor.lightGray.cgColor

		layer.addSublayer(innerCircleLayer)
	}

	private func addWasdLabels() {
		let wLabel = createLabel("W")
		let aLabel = createLabel("A")
		let sLabel = createLabel("S")
		let dLabel = createLabel("D")

		addSubview(wLabel)
		addSubview(aLabel)
		addSubview(sLabel)
		addSubview(dLabel)

		let margin: CGFloat = UIScreen.isSESize ? 2 : 4

		NSLayoutConstraint.activate([
			wLabel.topAnchor.constraint(equalTo: topAnchor, constant: margin),
			wLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

			aLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin * 2),
			aLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

			sLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
			sLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

			dLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin * 2),
			dLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}

	private func lineLayer(startAngle: CGFloat, endAngle: CGFloat) -> CALayer {
		let center = CGPoint(x: radius, y: radius)
		let startVector = limitNormalizedVector(limit: radius, angle: startAngle)
		let endVector = limitNormalizedVector(limit: radius, angle: endAngle)
		let start = CGPoint(x: center.x + startVector.dx, y: center.y + startVector.dy)
		let end = CGPoint(x: center.x + endVector.dx, y: center.y + endVector.dy)

		let line = CAShapeLayer()
		let linePath = UIBezierPath()
		linePath.move(to: start)
		linePath.addLine(to: end)
		line.path = linePath.cgPath
		line.fillColor = nil
		line.lineWidth = 0.5
		line.opacity = 0.45
		line.strokeColor = UIColor.lightGray.cgColor

		return line
	}

	private func createLabel(_ text: String) -> UILabel {
		let label = UILabel.withoutConstraints()
		label.text = text
		label.textColor = .white.withAlphaComponent(0.25)
		label.textAlignment = .center
		return label
	}
}

private func limitNormalizedVector(limit: CGFloat, angle: CGFloat) -> CGVector {
	let normalizedX = cos(angle) * limit
	let normalizedY = sin(angle) * limit

	return .init(dx: normalizedX, dy: normalizedY)
}

private func limitNormalizedVector(limit: CGFloat, vector: CGVector) -> CGVector {
	let angle = atan2(vector.dy, vector.dx)
	return limitNormalizedVector(limit: limit, angle: angle)
}

extension JoystickType { // Temporary, to avoid breaking change when migrating from build 8
	enum Key: String, CodingKey {
		case mouse
		case wasd4way
		case wasd8way
		case wasd
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		if container.contains(.mouse) {
			self = .mouse
		} else if container.contains(.wasd4way) {
			self = .wasd4way
		} else if container.contains(.wasd8way) {
			self = .wasd8way
		} else if container.contains(.wasd) {
			self = .wasd8way
		} else {
			throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: decoder.codingPath.debugDescription))
		}
	}
}
