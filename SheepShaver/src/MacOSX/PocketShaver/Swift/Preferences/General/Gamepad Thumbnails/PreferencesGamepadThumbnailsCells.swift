//
//  PreferencesGamepadThumbnailsCells.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-04-25.
//

import UIKit

class PreferencesGeneralGamepadThumbnailCell: UICollectionViewCell {
	static let reuseIdentifier = "PreferencesGeneralGamepadThumbnailCell"

	static let height: CGFloat = 56

	private lazy var imageView: UIImageView = {
		let imageView = UIImageView.withoutConstraints()
		imageView.contentMode = .scaleAspectFit
		return imageView
	}()

	private lazy var label: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .systemFont(ofSize: 14, weight: .medium)
		label.textColor = Colors.primaryText
		label.numberOfLines = 0
		label.adjustsFontSizeToFitWidth = true
		label.minimumScaleFactor = 0.25
		label.textAlignment = .center
		label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
		return label
	}()

	override init(frame: CGRect) {
		super.init(frame: frame)

		contentView.backgroundColor = Colors.informationCardBackground
		contentView.layer.cornerRadius = 8
		contentView.layer.masksToBounds = true

		contentView.addSubview(imageView)
		contentView.addSubview(label)

		let width = round(Self.height * UIScreen.landscapeModeSize.width / UIScreen.landscapeModeSize.height)
		let widthConstraint = contentView.widthAnchor.constraint(equalToConstant: width)
		widthConstraint.priority = .defaultHigh + 1

		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
			label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
			label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
			label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

			imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
			imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor).withPriority(.required - 1),
			imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor).withPriority(.required - 1),

			widthConstraint,
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(
		name: String,
		layoutImage: UIImage
	) {
		label.text = name
		imageView.image = layoutImage
	}
}

class PreferencesGeneralGamepadThumbnailSpacingCell: UICollectionViewCell {
	static let reuseIdentifier = "PreferencesGeneralGamepadOverlaySpacingCell"

	private lazy var imageView: UIImageView = {
		let imageView = UIImageView.withoutConstraints()
		imageView.image = Assets.arrowRightArrowLeft
		imageView.tintColor = Colors.secondaryText
		imageView.contentMode = .scaleAspectFit

		NSLayoutConstraint.activate([
			imageView.widthAnchor.constraint(equalToConstant: 16),
			imageView.heightAnchor.constraint(equalToConstant: 16)
		])

		return imageView
	}()

	override init(frame: CGRect) {
		super.init(frame: frame)

		contentView.backgroundColor = .clear

		contentView.addSubview(imageView)

		NSLayoutConstraint.activate([
			imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8).withPriority(.required - 1),
			imageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesGeneralGamepadThumbnailCollectionViewLayout: UICollectionViewCompositionalLayout {
	init() {
		let layoutConfig = UICollectionViewCompositionalLayoutConfiguration()
		layoutConfig.scrollDirection = .horizontal

		super.init(
			sectionProvider: { _, _ in
				let itemSize = NSCollectionLayoutSize(
					widthDimension: .estimated(120),
					heightDimension: .fractionalHeight(1.0)
				)
				let item = NSCollectionLayoutItem(
					layoutSize: itemSize
				)

				let groupSize = NSCollectionLayoutSize(
					widthDimension: .estimated(120),
					heightDimension: .estimated(PreferencesGeneralGamepadThumbnailCell.height)
				)
				let group = NSCollectionLayoutGroup.horizontal(
					layoutSize: groupSize,
					subitems: [item]
				)
				group.interItemSpacing = .fixed(8)

				return NSCollectionLayoutSection(group: group)
			},
			configuration: layoutConfig
		)
	}

	required init?(coder: NSCoder) { fatalError() }
}
