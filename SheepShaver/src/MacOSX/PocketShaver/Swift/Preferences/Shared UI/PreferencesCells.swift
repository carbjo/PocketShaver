//
//  PreferencesCells.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-30.
//

import UIKit

class PreferencesEnabledSettingCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private lazy var enabledSwitch: UISwitch = {
		let uiSwitch = UISwitch.withoutConstraints()
		uiSwitch.addTarget(self, action: #selector(enabledValueChanged), for: .touchUpInside)
		return uiSwitch
	}()

	private let didSetIsEnabled: ((Bool) -> Void)

	init(
		title: String,
		isOn: Bool,
		didSetIsEnabled: @escaping ((Bool) -> Void)
	) {
		self.didSetIsEnabled = didSetIsEnabled

		super.init(style: .default, reuseIdentifier: nil)

		titleLabel.text = title
		enabledSwitch.isOn = isOn

		titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		enabledSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)

		contentView.addSubview(titleLabel)
		contentView.addSubview(enabledSwitch)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

			enabledSwitch.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
			enabledSwitch.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			enabledSwitch.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			enabledSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8)
		])
	}

	required init?(coder: NSCoder) { fatalError() }


	@objc private func enabledValueChanged() {
		didSetIsEnabled(enabledSwitch.isOn)
	}
}

class PreferencesInformationCell: UITableViewCell {
	enum Margin {
		case medium
		case short
		case tiny
		case none
	}

	private let informationLabel: LinkLabel

	init(
		text: String,
		upperMargin: Margin = .short,
		lowerMargin: Margin = .medium,
		tagConfig: StringTagConfig? = .init(),
		separatorHidden: Bool = true,
		linkCallback: (() -> Void)? = nil
	) {

		let config = tagConfig ?? .init(
			boldAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.primaryText),
			highlightedAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.highlightedText)
		)

		informationLabel = .init(
			text: text,
			config: config,
			font: .systemFont(ofSize: 14),
			callback: linkCallback
		)

		super.init(style: .default, reuseIdentifier: nil)

		if separatorHidden {
			hideSeparator()
		}

		contentView.addSubview(informationLabel)

		NSLayoutConstraint.activate([
			informationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			informationLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: upperMargin.value),
			informationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			informationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -lowerMargin.value).withPriority(.required - 1)
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(text: String) {
		informationLabel.label.text = text
	}
}

class PreferencesEmptyStateCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .boldSystemFont(ofSize: 18)
		label.text = "No files found"
		label.textAlignment = .center
		return label
	}()

	init(
		title: String,
		separatorHidden: Bool = false
	) {
		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
		])

		titleLabel.text = title

		if separatorHidden {
			hideSeparator()
		}
	}

	required init?(coder: NSCoder) { fatalError() }
}

extension PreferencesInformationCell.Margin {
	var value: CGFloat {
		switch self {
		case .medium:
			return 16
		case .short:
			return 8
		case .tiny:
			return 2
		case .none:
			return 0
		}
	}
}
