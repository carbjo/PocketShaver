//
//  GamepadAssignButtonCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-14.
//

import UIKit

class GamepadAssignButtonEntryCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private lazy var infoButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setImage(UIImage(resource: .infoCircleFill), for: .normal)
		button.addTarget(self, action: #selector(infoButtonPushed), for: .touchUpInside)
		return button
	}()

	private lazy var topConstraint: NSLayoutConstraint = {
		titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16)
	}()

	private lazy var bottomConstraint: NSLayoutConstraint = {
		titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1)
	}()

	override func prepareForReuse() {
		super.prepareForReuse()

		backgroundColor = .clear
	}

	override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
		super.init(style: .default, reuseIdentifier: Self.reuseIdentifier)

		backgroundColor = .clear

		titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		infoButton.setContentHuggingPriority(.required, for: .horizontal)

		contentView.addSubview(titleLabel)
		contentView.addSubview(infoButton)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			topConstraint,
			bottomConstraint,

			infoButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
			infoButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
			infoButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	private var didTapInfoButton: (() -> Void)?

	func config(
		identifier: String,
		isPrimarySelection: Bool,
		sizeMode: GamepadAssignButtonViewController.SizeMode,
		didTapInfoButton: @escaping (() -> Void)
	) {
		self.didTapInfoButton = didTapInfoButton

		titleLabel.text = identifier

		backgroundColor = isPrimarySelection ? .darkGray.withAlphaComponent(0.4) : .clear

		topConstraint.constant = sizeMode.convert(16)
		bottomConstraint.constant = sizeMode.convert(-16)
	}

	@objc
	private func infoButtonPushed() {
		didTapInfoButton?()
	}
}
