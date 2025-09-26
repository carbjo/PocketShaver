//
//  PreferencesResolutionsViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit
import Combine

class PreferencesResolutionsViewController: UITableViewController {
	@MainActor
	enum SectionType: Int, CaseIterable {
		case information
		case standardResolutions
		case pixelAlignedResolutions
		case standardWidthOrHeightResolutions
	}

	private let changeSubject: PassthroughSubject<PreferencesChange, Never>

	init(changeSubject: PassthroughSubject<PreferencesChange, Never>) {
		self.changeSubject = changeSubject

		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		view.translatesAutoresizingMaskIntoConstraints = false
		view.backgroundColor = .white
		tableView.showsVerticalScrollIndicator = false
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		tableView.reloadData()
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)

		self.tableView.reloadData()
	}

	private func updateInformationCellResolutionCount() {
		let currentMonitorResolutionCount = MonitorResolutionManager.shared.enabledResolutionsCount
		let countIsFull = MonitorResolutionManager.shared.isEnabledResolutionsFull

		for section in 0..<tableView.numberOfSections {
			for row in 0..<tableView.numberOfRows(inSection: section) {
				let indexPath = IndexPath(row: row, section: section)

				if let cell = tableView.cellForRow(at: indexPath) as? PreferencesResolutionsInformationCell {
					cell.configure(
						isPortraitMode: UIScreen.isPortraitMode,
						currentMonitorResolutionCount: currentMonitorResolutionCount
					)
				} else if let cell = tableView.cellForRow(at: indexPath) as? PreferencesResolutionsMonitorResolutionCell {
					cell.configure(countIsFull: countIsFull)
				}
			}
		}
	}
}

extension PreferencesResolutionsViewController { // UITableViewDataSource

	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		let sectionType = SectionType(sectionIndex: section)

		switch sectionType {
		case .information:
			return nil
		case .standardResolutions:
			return "Common Classic Mac OS resolutions"
		case .pixelAlignedResolutions:
			return "Pixel aligned resolutions"
		case .standardWidthOrHeightResolutions:
			if UIScreen.isPortraitMode {
				return "Standard width fullscreen resolutions"
			} else {
				return "Standard height fullscreen resolutions"
			}
		}
	}

	override func numberOfSections(in tableView: UITableView) -> Int {
		SectionType.count
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		let sectionType = SectionType(sectionIndex: section)

		switch sectionType {
		case .information:
			return 1
		default:
			let manager = MonitorResolutionManager.shared
			guard let category = sectionType.monitorResolutionCategory,
			let count = manager.availableResolutions[category]?.count else {
				return 0
			}

			return count + 1
		}
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let sectionType = SectionType(sectionIndex: indexPath.section)

		switch sectionType {
		case .information:
			let initialMonitorResolutionCount = MonitorResolutionManager.shared.enabledResolutionsCount
			return PreferencesResolutionsInformationCell(
				isPortraitMode: UIScreen.isPortraitMode,
				initialMonitorResolutionCount: initialMonitorResolutionCount
			)
		default:
			let manager = MonitorResolutionManager.shared
			guard let category = sectionType.monitorResolutionCategory,
				  let availableResolutions = manager.availableResolutions[category] else {
				return UITableViewCell()
			}

			if indexPath.row == availableResolutions.count {
				return PreferencesResolutionsFooterCell(
					title: category.explanation
				)
			}

			let option = availableResolutions[indexPath.row]

			let isOn = manager.isResolutionEnabled(option)
			let isAlwaysOn = manager.isResolutionAlwaysEnabled(option)
			let countIsFull = manager.isEnabledResolutionsFull

			return PreferencesResolutionsMonitorResolutionCell(
				option: option,
				isOn: isOn,
				isAlwaysOn: isAlwaysOn,
				countIsFull: countIsFull,
				didTapHiddenCountIsFullInfoButton: { [weak self] in
					guard let self else { return }

					let maxNumberOfSimultaniousResolutions = MonitorResolutionManager.maxNumberOfSimultaniousResolutions
					let alertVC = UIAlertController.withMessage("The maximum number of simultanious available resolutions (\(maxNumberOfSimultaniousResolutions)) has been reached. Disable a resolution in order to make it possible to enable a resolution.")

					present(alertVC, animated: true)
				}
			) { [weak self] newOption, setIsOn in
				guard let self else { return }

				MonitorResolutionManager.shared.setIsResolutionEnabled(
					newOption,
					isEnabled: setIsOn
				)
				updateInformationCellResolutionCount()
				changeSubject.send(.changeRequiringRestartAfterBootMade)
			}
		}
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}
}

extension PreferencesResolutionsViewController.SectionType {
	@MainActor
	init(sectionIndex: Int) {
		let sections = Self.availableSections
		self = sections[sectionIndex]
	}

	static var count: Int {
		let sections = Self.availableSections
		return sections.count
	}

	func sectionIndex() -> Int {
		let sections = Self.availableSections
		return sections.firstIndex(of: self)!
	}

	var monitorResolutionCategory: MonitorResolutionCategory? {
		switch self {
		case .information:
			nil
		case .pixelAlignedResolutions:
			if UIScreen.isPortraitMode {
				.pixelAlignedPortrait
			} else {
				.pixelAlignedLandscape
			}
		case .standardResolutions:
				.standardResolution
		case .standardWidthOrHeightResolutions:
			if UIScreen.isPortraitMode {
				.standardWidthPortrait
			} else {
				.standardHeightLandscape
			}
		}
	}

	private static var availableSections: [Self] {
		var sections = allCases

		if MonitorResolutionManager.shared.is4to3ratioDevice {
			// All .standardWidthOrHeightResolutions cases will be found
			// inside .standardResolutions, since this device has the
			// same ratio that the monitors running 640x480 and 800x600
			// had. Ie. 4:3.
			let standardWidthOrHeightResolutionsIndex = sections.firstIndex(of: .standardWidthOrHeightResolutions)!
			sections.remove(at: standardWidthOrHeightResolutionsIndex)
		}

		return sections
	}
}
