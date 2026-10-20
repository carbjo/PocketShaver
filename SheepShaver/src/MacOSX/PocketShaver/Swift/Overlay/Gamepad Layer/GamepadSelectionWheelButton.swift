//
//  GamepadSelectionWheelButton.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-10-11.
//

import UIKit

class GamepadSelectionWheelButton: UIControl {
	enum InteractionState {
		case collapsed
		case expanded
	}

	private lazy var collapsedCircleView: CollapsedCircleView = {
		CollapsedCircleView(
			buttonName: config.buttonName
		)
	}()

	private lazy var expandedCircleView: ExpandedCircleView = {
		let view = ExpandedCircleView(
			assignments: config.assignments,
			didRequestHapticFeedback: { [weak self] in
				if MiscellaneousSettings.current.keyHapticFeedback {
					self?.feedbackGenerator.selectionChanged()
				}
			}
		)
		view.alpha = 0
		view.transform = .init(scaleX: 0.5, y: 0.5)
		return view
	}()

	private let feedbackGenerator = UISelectionFeedbackGenerator()

	private let radius = GamepadButtonSize.regular.length
	private let config: SelectionWheelButtonConfig
	private var isEditing: Bool
	private let didFire: ((SelectionWheelButtonAssignment) -> Void)
	private let didRequestAssignment: (() -> Void)
	private var interactionState: InteractionState = .collapsed

	private var selectedIndex: Int?

	private var augmentedBounds: CGRect {
		let offset: CGFloat = radius
		return bounds.inset(
			by: .init(
				top: -4 + offset/2,
				left: -2 + offset/2,
				bottom: -4 - offset/2,
				right: -2 - offset/2
			)
		)
	}

	init(
		config: SelectionWheelButtonConfig,
		didFire: @escaping ((SelectionWheelButtonAssignment) -> Void),
		isEditing: Bool,
		didRequestAssignment: @escaping (() -> Void)
	) {
		self.config = config
		self.isEditing = isEditing
		self.didFire = didFire
		self.didRequestAssignment = didRequestAssignment

		super.init(frame: .zero)

		addSubview(collapsedCircleView)
		addSubview(expandedCircleView)

		let stackViewSlotLength = GamepadButtonSize.regular.length
		let collapsedButtonDiameter = radius
		let expandedButtonDiameter = radius * 2

		NSLayoutConstraint.activate([
			collapsedCircleView.centerXAnchor.constraint(equalTo: centerXAnchor),
			collapsedCircleView.centerYAnchor.constraint(equalTo: centerYAnchor),
			collapsedCircleView.widthAnchor.constraint(equalToConstant: collapsedButtonDiameter),
			collapsedCircleView.heightAnchor.constraint(equalToConstant: collapsedButtonDiameter),

			expandedCircleView.centerXAnchor.constraint(equalTo: centerXAnchor),
			expandedCircleView.centerYAnchor.constraint(equalTo: centerYAnchor),
			expandedCircleView.widthAnchor.constraint(equalToConstant: expandedButtonDiameter),
			expandedCircleView.heightAnchor.constraint(equalToConstant: expandedButtonDiameter),

			widthAnchor.constraint(equalToConstant: stackViewSlotLength),
			heightAnchor.constraint(equalToConstant: stackViewSlotLength)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func set(isEditing: Bool) {
		self.isEditing = isEditing
	}

	private func updateInteractionState(_ interactionState: InteractionState) {
		guard self.interactionState != interactionState else {
			return
		}

		self.interactionState = interactionState

		switch interactionState {
		case .collapsed:
			UIView.animate(withDuration: 0.1) {
				self.collapsedCircleView.alpha = 1
				self.collapsedCircleView.transform = .identity
				self.expandedCircleView.alpha = 0
				self.expandedCircleView.transform = .init(scaleX: 0.5, y: 0.5)
			}
		case .expanded:
			UIView.animate(withDuration: 0.1) {
				self.collapsedCircleView.alpha = 0
				self.collapsedCircleView.transform = .init(scaleX: 2, y: 2)
				self.expandedCircleView.alpha = 1
				self.expandedCircleView.transform = .identity
			}
		}
	}

	override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
		switch interactionState {
		case .collapsed:
			bounds.contains(point)
		case .expanded:
			augmentedBounds.contains(point)
		}
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesBegan(touches, with: event)

		if !isEditing {
			updateInteractionState(.expanded)
		}

		guard let touch = touchInside(touches) else {
			return
		}

		let selectedIndex = calculateSelectedIndex(with: touch)
		updateSelectedIndex(selectedIndex)
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesMoved(touches, with: event)

		guard let touch = touches.first else {
			return
		}

		let selectedIndex = calculateSelectedIndex(with: touch)
		updateSelectedIndex(selectedIndex)
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesEnded(touches, with: event)

		if isEditing {
			didRequestAssignment()
		} else if let selectedIndex {
			let firedAssignment = config.assignments[selectedIndex]
			didFire(firedAssignment)
		}

		updateInteractionState(.collapsed)
	}

	private func touchInside(_ touches: Set<UITouch>) -> UITouch? {
		for touch in touches {
			if augmentedBounds.contains(touch.location(in: self)) {
				return touch
			}
		}

		return nil
	}

	private func calculateSelectedIndex(with touch: UITouch) -> Int? {
		let point = touch.location(in: self)

		let vector = CGVector(
			dx: point.x - expandedCircleView.center.x,
			dy: point.y - expandedCircleView.center.y
		)

		let deadZone: CGFloat = 10

		if vector.abs < deadZone {
			return nil
		}

		let angle = atan2(vector.dy, vector.dx)

		let totalNumberOfAssignments = config.assignments.count
		let twoPi = CGFloat.pi * 2
		let originAngle: CGFloat = -1/4 * twoPi
		let step: CGFloat = twoPi / CGFloat(totalNumberOfAssignments)

		for index in 0..<totalNumberOfAssignments {
			let beginAngle = originAngle + step * CGFloat(index)
			let endAngle = originAngle + step * CGFloat(index+1)
			if beginAngle <= angle,
			   angle <= endAngle {
				return index
			}

			if endAngle > CGFloat.pi {
				// atan means angle is always between - pi to + pi
				let beginAngleAdjusted = beginAngle - twoPi
				let endAngleAdjusted = endAngle - twoPi
				if beginAngleAdjusted <= angle,
				   angle <= endAngleAdjusted {
					return index
				}
			}
		}

		return nil
	}

	private func updateSelectedIndex(_ selectedIndex: Int?) {
		guard selectedIndex != self.selectedIndex else {
			return
		}

		if let previousSelectedIndex = self.selectedIndex {
			// Unselected previous pie slice
			expandedCircleView.setSliceSelected(
				sliceIndex: previousSelectedIndex,
				selected: false
			)
		}

		self.selectedIndex = selectedIndex

		if let selectedIndex {
			expandedCircleView.setSliceSelected(
				sliceIndex: selectedIndex,
				selected: true
			)
		}
	}
}

private class CollapsedCircleView: UIView {
	private let radius = GamepadButtonSize.regular.length / 2

	init(
		buttonName: String
	) {
		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		backgroundColor = .lightGray.withAlphaComponent(0.5)
		layer.cornerRadius = radius

		addLabel(buttonName: buttonName)
	}

	required init?(coder: NSCoder) { fatalError() }

	private func addLabel(
		buttonName: String
	) {
		let label = createLabel(buttonName)

		addSubview(label)

		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: centerXAnchor),
			label.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
	}
}

private class ExpandedCircleView: UIView {
	private let radius = GamepadButtonSize.regular.length
	private let linesLayer = CALayer()
	private let didRequestHapticFeedback: (() -> Void)
	private var pieSliceViews = [ExpandedCirclePieSliceView]()

	init(
		assignments: [SelectionWheelButtonAssignment],
		didRequestHapticFeedback: @escaping (() -> Void)
	) {
		self.didRequestHapticFeedback = didRequestHapticFeedback

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		backgroundColor = .clear
		layer.cornerRadius = radius

		layer.addSublayer(linesLayer)

		drawSegmentLines(numberOfSegments: assignments.count)

		setupPieSliceViews(
			assignments: assignments
		)
	}

	required init?(coder: NSCoder) { fatalError() }

	private func setupPieSliceViews(
		assignments: [SelectionWheelButtonAssignment]
	) {
		for (index, assignment) in assignments.enumerated() {
			let pieSliceView = ExpandedCirclePieSliceView(
				assignment: assignment,
				index: index,
				totalNumberOfAssignments: assignments.count,
				didRequestHapticFeedback: didRequestHapticFeedback
			)

			addSubview(pieSliceView)

			NSLayoutConstraint.activate([
				pieSliceView.leadingAnchor.constraint(equalTo: leadingAnchor),
				pieSliceView.topAnchor.constraint(equalTo: topAnchor),
				pieSliceView.trailingAnchor.constraint(equalTo: trailingAnchor),
				pieSliceView.bottomAnchor.constraint(equalTo: bottomAnchor),
			])

			pieSliceViews.append(pieSliceView)
		}
	}

	private func drawSegmentLines(
		numberOfSegments: Int
	) {
		let twoPi = CGFloat.pi * 2

		var layers = [CALayer]()

		let step: CGFloat = twoPi / CGFloat(numberOfSegments)
		let startAngle: CGFloat = -1/4 * twoPi

		for index in 0..<numberOfSegments {
			let offset = CGFloat(index) * step
			let angle = startAngle + offset

			layers.append(
				lineLayer(angle: angle)
			)
		}

		for layer in layers {
			linesLayer.addSublayer(layer)
		}
	}

	private func lineLayer(angle: CGFloat) -> CALayer {
		let center = CGPoint(x: radius, y: radius)
		let startVector = limitNormalizedVector(limit: radius, angle: angle)
		let start = CGPoint(x: center.x + startVector.dx, y: center.y + startVector.dy)
		let end = CGPoint(x: center.x, y: center.y)

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

	func setSliceSelected(sliceIndex: Int, selected: Bool) {
		let pieSliceView = pieSliceViews[sliceIndex]
		pieSliceView.setSelected(selected)
	}
}

private class ExpandedCirclePieSliceView: UIView {
	private let radius = GamepadButtonSize.regular.length
	private let didRequestHapticFeedback: (() -> Void)
	private var isSelected = false

	init(
		assignment: SelectionWheelButtonAssignment,
		index: Int,
		totalNumberOfAssignments: Int,
		didRequestHapticFeedback: @escaping (() -> Void)
	) {
		self.didRequestHapticFeedback = didRequestHapticFeedback

		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false
		backgroundColor = .lightGray.withAlphaComponent(0.5)
		layer.cornerRadius = radius

		addLabel(
			assignment: assignment,
			index: index,
			totalNumberOfAssignments: totalNumberOfAssignments
		)

		addMask(
			index: index,
			totalNumberOfAssignments: totalNumberOfAssignments
		)
	}

	required init?(coder: NSCoder) { fatalError() }

	private func addLabel(
		assignment: SelectionWheelButtonAssignment,
		index: Int,
		totalNumberOfAssignments: Int
	) {
		let twoPi = CGFloat.pi * 2

		let step: CGFloat = twoPi / CGFloat(totalNumberOfAssignments)
		let startAngle: CGFloat = (-1/4 * twoPi) + (1/2 * step)

		let offset = CGFloat(index) * step
		let angle = startAngle + offset

		let vector = limitNormalizedVector(
			limit: radius * 0.8,
			angle: angle
		)

		let label = createLabel(assignment.label)

		addSubview(label)

		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: centerXAnchor, constant: vector.dx),
			label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: vector.dy),
		])
	}

	private func addMask(
		index: Int,
		totalNumberOfAssignments: Int
	) {
		let twoPi = CGFloat.pi * 2

		let center = CGPoint(x: radius, y: radius)

		let step: CGFloat = twoPi / CGFloat(totalNumberOfAssignments)
		let originAngle: CGFloat = -1/4 * twoPi
		let beginSliceAngle = originAngle + step * CGFloat(index)
		let endSliceAngle = originAngle + step * CGFloat(index + 1)

		let beginSliceVector = limitNormalizedVector(limit: radius, angle: beginSliceAngle)
		let beginSlice = CGPoint(x: center.x + beginSliceVector.dx, y: center.y + beginSliceVector.dy)

		let mask = CAShapeLayer()
		let maskPath = UIBezierPath()
		maskPath.move(to: center)
		maskPath.addLine(to: beginSlice)
		maskPath.addArc(
			withCenter: center,
			radius: radius,
			startAngle: beginSliceAngle,
			endAngle: endSliceAngle,
			clockwise: true
		)
		maskPath.addLine(to: center)
		mask.path = maskPath.cgPath
		mask.fillColor = UIColor.black.cgColor

		layer.mask = mask
	}

	func setSelected(_ isSelected: Bool) {
		guard self.isSelected != isSelected else {
			return
		}

		self.isSelected = isSelected

		if isSelected,
		   MiscellaneousSettings.current.keyHapticFeedback {
			didRequestHapticFeedback()
		}

		UIView.animate(withDuration: 0.07) {
			if isSelected {
				self.backgroundColor = .lightGray.withAlphaComponent(1)

				self.transform = .init(scaleX: 1.1, y: 1.1)
			} else {
				self.backgroundColor = .lightGray.withAlphaComponent(0.5)
				self.transform = .identity
			}
		}
	}
}

private func createLabel(_ text: String) -> UILabel {
	let label = UILabel.withoutConstraints()
	label.text = text
	label.textColor = .white.withAlphaComponent(0.25)
	label.textAlignment = .center
	return label
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
