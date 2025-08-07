//
//  InformationView.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-09.
//

import UIKit

class InformationView: UIVisualEffectView {
	private lazy var label: UILabel = {
		let label = UILabel.withoutConstraints()
		label.textColor = .white
		label.textAlignment = .center
		label.font = label.font.withSize(40)
		return label
	}()

	init() {
		let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
		super.init(effect: blurEffect)

		backgroundColor = .clear
		clipsToBounds = true
		layer.cornerRadius = 8

		contentView.addSubview(label)

		label.setContentCompressionResistancePriority(.required, for: .horizontal)
		label.setContentCompressionResistancePriority(.required, for: .vertical)

		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func set(text: String?) {
		label.text = text
	}
}
