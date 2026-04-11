//
//  PreferencesGraphicsCells.swift
//  (C) 2026 Sierra Burkhart (sierra760)
//

import UIKit

class PreferencesGraphicsFrameRateSettingCell: UITableViewCell {
	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in FrameRateSetting.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((FrameRateSetting) -> Void)

	init(
		initialFrameRateSetting: FrameRateSetting,
		didChangeSelection: @escaping ((FrameRateSetting) -> Void)
	) {
		self.didChangeSelection = didChangeSelection

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(segmentedControl)

		NSLayoutConstraint.activate([
			segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),
			segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			segmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 350)
		])

		segmentedControl.selectedSegmentIndex = FrameRateSetting.allCases.enumerated().first(where: { initialFrameRateSetting == $1 })!.0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let index = segmentedControl.selectedSegmentIndex
		let setting = FrameRateSetting.allCases.enumerated().first(where: { index == $0.0 })!.1

		didChangeSelection(setting)
	}
}

class PreferencesGraphicsEnabledMonitorResolutionsCell: UITableViewCell {
	private lazy var editButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.setTitle("Edit", for: .normal)
		button.setTitleColor(Colors.primaryText, for: .normal)
		button.setTitleColor(Colors.highlightedText, for: .highlighted)
		button.titleLabel?.font = .boldSystemFont(ofSize: 17)
		button.addTarget(self, action: #selector(editButtonPushed), for: .touchUpInside)
		return button
	}()

	private var titleLabel: LinkLabel?

	private let didTapEditButton: (() -> Void)

	init(
		monitorResolutionsState: PreferencesGraphicsModel.MonitorResolutionsState,
		didTapEditButton: @escaping (() -> Void)
	) {
		self.didTapEditButton = didTapEditButton

		super.init(style: .default, reuseIdentifier: nil)

		contentView.addSubview(editButton)

		NSLayoutConstraint.activate([
			editButton.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
			editButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
			editButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
		])

		configure(
			monitorResolutionsState: monitorResolutionsState
		)
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(
		monitorResolutionsState: PreferencesGraphicsModel.MonitorResolutionsState
	) {
		let monitorResolutionCategoryIndex: (MonitorResolutionCategory) -> Int = { category in
			MonitorResolutionCategory.allCases.firstIndex(of: category)!
		}
		let sortedMonitorResolutions = monitorResolutionsState.enabledResolutions.sorted { opt1, opt2 in
			if monitorResolutionCategoryIndex(opt1.category) < monitorResolutionCategoryIndex(opt2.category) {
				return true
			}

			if opt1.resolution.width < opt2.resolution.width {
				return true
			}

			return opt1.resolution.height < opt2.resolution.height
		}

		var text = ""
		var images: [UIImage] = []
		for monitorResolution in sortedMonitorResolutions {
			let categoryTagView = PreferencesGeneralTagView()
				.configure(
					text: monitorResolution.category.description
				)
			let categoryTagViewImage = categoryTagView.asImage()

			text += "• \(monitorResolution.resolution.width) x \(monitorResolution.resolution.height)"
			if !UIScreen.isSESize {
				text += " <img yOffset=-2/>"
			}
			if monitorResolution != sortedMonitorResolutions.last {
				text += "\n"
			}
			images.append(categoryTagViewImage)
		}

		let titleLabel = LinkLabel(
			text: text,
			config: .init(
				images: images,
				highlightedImages: []
			),
			font: .systemFont(ofSize: 17),
			textColor: Colors.primaryText
		)

		titleLabel.label.setContentHuggingPriority(.required, for: .horizontal)
		titleLabel.label.setContentCompressionResistancePriority(.required, for: .vertical)

		contentView.addSubview(titleLabel)

		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			titleLabel.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
			titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -16),
			titleLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
			titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

			titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16).withPriority(.defaultHigh),
			titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16).withPriority(.defaultHigh),
			])

		self.titleLabel = titleLabel

		editButton.isHidden = monitorResolutionsState.willBootFromCD
	}

	@objc
	private func editButtonPushed() {
		didTapEditButton()
	}
}

class PreferencesGraphicsRenderingFilterCell: UITableViewCell {
	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in RenderingFilterMode.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((RenderingFilterMode) -> Void)

	init(
		initialFilterMode: RenderingFilterMode,
		didChangeSelection: @escaping ((RenderingFilterMode) -> Void)
	) {
		self.didChangeSelection = didChangeSelection

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(segmentedControl)

		NSLayoutConstraint.activate([
			segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),
			segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			segmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 350)
		])

		segmentedControl.selectedSegmentIndex = RenderingFilterMode.allCases.enumerated().first(where: { initialFilterMode == $1 })!.0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let index = segmentedControl.selectedSegmentIndex
		let setting = RenderingFilterMode.allCases.enumerated().first(where: { index == $0.0 })!.1

		didChangeSelection(setting)
	}
}

class PreferencesGraphicsGammaRampSettingCell: UITableViewCell {
	private lazy var segmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in GammaRampSetting.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private let didChangeSelection: ((GammaRampSetting) -> Void)

	init(
		initialGammaRampSetting: GammaRampSetting,
		didChangeSelection: @escaping ((GammaRampSetting) -> Void)
	) {
		self.didChangeSelection = didChangeSelection

		super.init(style: .default, reuseIdentifier: nil)

		hideSeparator()

		contentView.addSubview(segmentedControl)

		NSLayoutConstraint.activate([
			segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
			segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
			segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).withPriority(.defaultHigh),
			segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
			segmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 350)
		])

		segmentedControl.selectedSegmentIndex = GammaRampSetting.allCases.enumerated().first(where: { initialGammaRampSetting == $1 })!.0
	}

	required init?(coder: NSCoder) { fatalError() }

	@objc private func tabSegmentedControlChanged() {
		let index = segmentedControl.selectedSegmentIndex
		let setting = GammaRampSetting.allCases.enumerated().first(where: { index == $0.0 })!.1

		didChangeSelection(setting)
	}
}

private extension FrameRateSetting {
	var label: String {
		switch self {
		case .f60hz: return "60 hz"
		case .f75hz: return "75 hz"
		case .f120hz: return "120 hz"
		}
	}
}

private extension RenderingFilterMode {
	var label: String {
		switch self {
		case .nearestNeighbor: return "Nearest neighbor"
		case .bilinear: return "Bilinear"
		}
	}
}

private extension GammaRampSetting {
	var label: String {
		switch self {
		case .osDefined: return "OS defined"
		case .linear: return "Linear"
		}
	}
}
