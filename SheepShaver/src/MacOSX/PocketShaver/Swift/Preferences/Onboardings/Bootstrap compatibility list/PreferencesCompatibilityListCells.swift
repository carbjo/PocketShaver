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
		label.textColor = Colors.secondaryText
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
	private class CompatibilityInfoView: UIView {
		private lazy var label: UILabel = {
			let label = UILabel.withoutConstraints()
			label.numberOfLines = 0
			label.lineBreakMode = .byWordWrapping
			label.font = .systemFont(ofSize: 14)
			return label
		}()

		private lazy var iconImageView: UIImageView = {
			UIImageView.withoutConstraints()
		}()

		init(
			title: String,
			color: UIColor,
			iconImage: UIImage
		) {
			super.init(frame: .zero)

			translatesAutoresizingMaskIntoConstraints = false

			addSubview(iconImageView)
			addSubview(label)

			NSLayoutConstraint.activate([
				iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
				iconImageView.topAnchor.constraint(equalTo: topAnchor),
				iconImageView.bottomAnchor.constraint(equalTo: bottomAnchor).withPriority(.required - 1),

				label.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
				label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
				label.centerYAnchor.constraint(equalTo: iconImageView.centerYAnchor)
			])

			label.text = title
			label.textColor = color
			iconImageView.image = iconImage
			iconImageView.tintColor = color
		}

		required init?(coder: NSCoder) { fatalError() }
	}

	private lazy var compatibilityInfoStackView: UIStackView = {
		let stackView = UIStackView.withoutConstraints()
		stackView.axis = .vertical
		stackView.distribution = .fill
		stackView.alignment = .leading
		return stackView
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 16)
		label.textColor = Colors.secondaryText
		return label
	}()

	init(
		title: String,
		isBootstrapCompatible: Bool,
		isInstallCompatible: Bool
	) {
		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(titleLabel)
		contentView.addSubview(compatibilityInfoStackView)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

			compatibilityInfoStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
			compatibilityInfoStackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
			compatibilityInfoStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			compatibilityInfoStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.required - 1),
		])

		titleLabel.text = title

		if isBootstrapCompatible {
			let view = CompatibilityInfoView(
				title: "Compatible",
				color: Colors.okColor,
				iconImage: .init(resource: .checkmarkCircleFill)
			)
			compatibilityInfoStackView.addArrangedSubview(view)
		} else if isInstallCompatible {
			let bootstrapView = CompatibilityInfoView(
				title: "Not bootstrap compatible",
				color: Colors.notOkMildColor,
				iconImage: Assets.xmarkDiamondFill
			)
			compatibilityInfoStackView.addArrangedSubview(bootstrapView)

			let installView = CompatibilityInfoView(
				title: "Install compatible",
				color: Colors.okColor,
				iconImage: Assets.plusDiamondFill
			)
			compatibilityInfoStackView.addArrangedSubview(installView)
		} else {
			let view = CompatibilityInfoView(
				title: "Not compatible",
				color: Colors.notOkColor,
				iconImage: .init(resource: .xmarkCircleFill)
			)
			compatibilityInfoStackView.addArrangedSubview(view)
		}
	}

	required init?(coder: NSCoder) { fatalError() }
}
