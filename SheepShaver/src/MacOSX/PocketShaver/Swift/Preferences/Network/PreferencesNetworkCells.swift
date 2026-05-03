//
//  PreferencesNetworkCells.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-15.
//

import UIKit

class PreferencesNetworkServiceTypeCell: UITableViewCell {
	private lazy var checkboxImageView: UIImageView = {
		let view = UIImageView.withoutConstraints()
		let length: CGFloat = UIScreen.isSESize ? 22 : 26
		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: length),
			view.heightAnchor.constraint(equalToConstant: length)
		])
		view.tintColor = Colors.secondaryText
		return view
	}()

	private lazy var serviceTypeImageView: UIImageView = {
		let view = UIImageView.withoutConstraints()
		let length: CGFloat = UIScreen.isSESize ? 40 : 50
		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: length),
			view.heightAnchor.constraint(equalToConstant: length)
		])
		return view
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .boldSystemFont(ofSize: 22)
		label.textColor = Colors.primaryText
		return label
	}()

	private lazy var subtitleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 15)
		label.textColor = Colors.secondaryText
		return label
	}()

	init(
		serviceType: NetworkServiceType,
		isSelected: Bool
	) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		setupViews()
		configure(serviceType: serviceType)
		configure(isSelected: isSelected)
	}

	required init?(coder: NSCoder) { fatalError() }

	private func setupViews() {
		contentView.addSubview(checkboxImageView)
		contentView.addSubview(serviceTypeImageView)
		contentView.addSubview(titleLabel)
		contentView.addSubview(subtitleLabel)

		let margin: CGFloat = UIScreen.isSESize ? 8 : 16

		NSLayoutConstraint.activate([
			checkboxImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
			checkboxImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

			serviceTypeImageView.leadingAnchor.constraint(equalTo: checkboxImageView.trailingAnchor, constant: margin),
			serviceTypeImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

			titleLabel.leadingAnchor.constraint(equalTo: serviceTypeImageView.trailingAnchor, constant: margin),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

			subtitleLabel.leadingAnchor.constraint(equalTo: serviceTypeImageView.trailingAnchor, constant: margin),
			subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
			subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
			subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
		])
	}

	private func configure(serviceType: NetworkServiceType) {
		switch serviceType {
		case .slirp:
			serviceTypeImageView.image = Assets.network.withRenderingMode(.alwaysTemplate)
			serviceTypeImageView.tintColor = Colors.bonjourGray
			titleLabel.text = "Internet"
			subtitleLabel.text = "Access to internet, using SLiRP. But without ability to host."
		case .bonjour:
			serviceTypeImageView.image = Assets.bonjour.withRenderingMode(.alwaysOriginal)
			titleLabel.text = "LAN"
			subtitleLabel.text = "Connect to other devices running PocketShaver on same Wi-Fi or hotspot, using Bonjour. But without access to internet."
			hideSeparator()
		}
	}

	func configure(isSelected: Bool) {
		checkboxImageView.image = UIImage(resource: isSelected ? .checkmarkCircleFill : .circle)
	}
}

class PreferencesNetworkBonjourRolePickerCell: UITableViewCell {
	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in BonjourManager.Role.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((BonjourManager.Role) -> Void)

	init(
		initialBonjourRole: BonjourManager.Role,
		didChangeSelection: @escaping ((BonjourManager.Role) -> Void)
	) {
		self.didChangeSelection = didChangeSelection

		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		hideSeparator()

		contentView.addSubview(segmentedControl)

		NSLayoutConstraint.activate([
			segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),
			segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			segmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 350)
		])

		segmentedControl.selectedSegmentIndex = BonjourManager.Role.allCases.enumerated().first(where: { initialBonjourRole == $1 })!.0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let index = segmentedControl.selectedSegmentIndex
		let setting = BonjourManager.Role.allCases.enumerated().first(where: { index == $0.0 })!.1

		didChangeSelection(setting)
	}
}

class PreferencesGeneralLanColumnsDescriptionCell: UITableViewCell {
	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.font = .boldSystemFont(ofSize: 14)
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	init(
		columnTitle: String
	) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
		])

		titleLabel.text = columnTitle
	}

	required init?(coder: NSCoder) { fatalError() }
}

class PreferencesNetworkRouterCell: UITableViewCell {
	private lazy var routerImageView: UIImageView = {
		let view = UIImageView.withoutConstraints()
		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: 30),
			view.heightAnchor.constraint(equalToConstant: 30)
		])
		view.image = Assets.bonjour.withRenderingMode(.alwaysTemplate)
		view.tintColor = Colors.primaryText
		return view
	}()

	private lazy var titleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .boldSystemFont(ofSize: 18)
		label.textColor = Colors.primaryText
		return label
	}()

	private lazy var subtitleLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 15)
		label.textColor = Colors.secondaryText
		label.text = "Tap to join"
		return label
	}()

	init(
		title: String,
		separatorHidden: Bool
	) {
		super.init(style: .default, reuseIdentifier: nil)

		backgroundColor = Colors.primaryBackground

		if separatorHidden {
			hideSeparator()
		}

		contentView.addSubview(routerImageView)
		contentView.addSubview(titleLabel)
		contentView.addSubview(subtitleLabel)

		NSLayoutConstraint.activate([
			routerImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			routerImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

			titleLabel.leadingAnchor.constraint(equalTo: routerImageView.trailingAnchor, constant: 16),
			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

			subtitleLabel.leadingAnchor.constraint(equalTo: routerImageView.trailingAnchor, constant: 16),
			subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
			subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
			subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
		])

		titleLabel.text = title
	}

	required init?(coder: NSCoder) { fatalError() }
}

private extension BonjourManager.Role {
	var label: String {
		switch self {
		case .host:
			"Host"
		case .client:
			"Join"
		}
	}
}
