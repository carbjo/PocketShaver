//
//  GradientView.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-04-25.
//

import UIKit

class GradientView: UIView {
	private var gradientLayer: CAGradientLayer = {
		createGradientLayer()
	}()

	override init(frame: CGRect) {
		super.init(frame: frame)

		layer.addSublayer(gradientLayer)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		gradientLayer.frame = bounds
	}

	func updateColors() {
		gradientLayer.removeFromSuperlayer()
		gradientLayer = Self.createGradientLayer()
		layer.addSublayer(gradientLayer)
	}

	private static func createGradientLayer() -> CAGradientLayer {
		let layer = CAGradientLayer()
		layer.startPoint = CGPoint(x: 0.65, y: 0.5)
		layer.endPoint = CGPoint(x: 1.0, y: 0.5)
		layer.locations = [0, 0.6, 1.0]
		let color = Colors.primaryBackground
		layer.colors = [
			color.withAlphaComponent(0).cgColor,
			color.withAlphaComponent(0.9).cgColor,
			color.cgColor
		]
		return layer
	}
}
