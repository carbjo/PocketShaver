//
//  PreferencesGraphicsCells.swift
//  (C) 2026 Sierra Burkhart (sierra760)
//

import UIKit

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

private extension RenderingFilterMode {
	var label: String {
		switch self {
		case .nearestNeighbor: return "Nearest neighbor"
		case .bilinear: return "Bilinear"
		}
	}
}
