//
//  PreferencesCompatibilityListCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-12.
//

import UIKit

class PreferencesCompatibilityListPrefaceCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = .darkGray
		return label
	}()

	init() {
		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24).withPriority(.required - 1)
		])

		titleLabel.text = "When in doubt if your file is compatible, attempt bootstrapping. PocketShaver will perform tests on your Mac OS install disc file to determine compatibility.\n\nLater on, when installing Mac OS onto your virtual hard drive, the used Mac OS install disc does not nessecarily have to be the same as the one used to boostrap."
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesCompatibilityListCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 16)
		label.textColor = .darkGray
		return label
	}()

	private lazy var compatibilityLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = .darkGray
		return label
	}()

	private lazy var compatibilityIconImageView: UIImageView = {
		let imageView = UIImageView.withoutConstraints()
		return imageView
	}()

	init(
		title: String,
		isCompatible: Bool
	) {
		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(titleLabel)
		contentView.addSubview(compatibilityIconImageView)
		contentView.addSubview(compatibilityLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

			compatibilityIconImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
			compatibilityIconImageView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
			compatibilityIconImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),

			compatibilityLabel.leadingAnchor.constraint(equalTo: compatibilityIconImageView.trailingAnchor, constant: 8),
			compatibilityLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			compatibilityLabel.centerYAnchor.constraint(equalTo: compatibilityIconImageView.centerYAnchor)
		])

		titleLabel.text = title

		if isCompatible {
			compatibilityIconImageView.image = .init(resource: .checkmarkCircleFill)
			compatibilityIconImageView.tintColor = CustomColors.okColor
			compatibilityLabel.text = "Compatible"
			compatibilityLabel.textColor = CustomColors.okColor
		} else {
			compatibilityIconImageView.image = .init(resource: .xmarkCircleFill)
			compatibilityIconImageView.tintColor = CustomColors.notOkColor
			compatibilityLabel.text = "Not compatible"
			compatibilityLabel.textColor = CustomColors.notOkColor
		}
	}

	required init?(coder: NSCoder) { fatalError() }
}
