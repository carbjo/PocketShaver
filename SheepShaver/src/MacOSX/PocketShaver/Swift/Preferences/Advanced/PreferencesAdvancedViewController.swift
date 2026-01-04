//
//  PreferencesAdvancedViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit
import Combine

class PreferencesAdvancedViewController: UITableViewController {
	enum SectionType: CaseIterable {
		case ramSetting
		case frameRateSetting
		case uiOptions
		case relateiveMouseMode
		case secondFinger
		case bootstrap
		case resources
	}

	private let model: PreferencesAdvancedModel

	init(changeSubject: PassthroughSubject<PreferencesChange, Never>) {
		model = .init(changeSubject: changeSubject)

		super.init(nibName: nil, bundle: nil)

		view.backgroundColor = Colors.primaryBackground
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		tableView.showsVerticalScrollIndicator = false

		view.translatesAutoresizingMaskIntoConstraints = false
	}

	private func displayRomPicker() {
		let pickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
		pickerVC.delegate = self

		present(pickerVC, animated: true)
	}

	private func displaySuccesfulBoostrapDialogue() {
		let alertVC = UIAlertController(
			title: "Success",
			message: "PocketShaver is bootstrapped again with your new file.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default))

		present(alertVC, animated: true)
	}

	private func displayNoRomFoundDialogue() {
		let alertVC = UIAlertController(
			title: "Mac OS install disc image not compatible",
			message: "The provided file is not a compatible Mac OS install disc image for bootstrapping PocketShaver. Check 'Compatibility list' for guidence.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default))

		present(alertVC, animated: true)
	}

	private func displayIncompatibleRomFoundDialogue(_ romType: NewWorldRomVersion) {
		let alertVC = UIAlertController(
			title: "Mac OS install disc image not compatible",
			message: "The provided file is a Mac OS disk install image, but is not compatible for bootstrapping PocketShaver. The file is identified as category '\(romType.description)'. Check 'Compatibility list' for guidence.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default))

		present(alertVC, animated: true)
	}

	private func updateBootstrapCell() {
		guard model.hasRomFile else {
			return
		}

		let sectionIndex = SectionType.bootstrap.sectionIndex(model: model)
		let indexPath = IndexPath(row: 0, section: sectionIndex)

		guard let cell = tableView.cellForRow(at: indexPath) as? PreferencesAdvancedBootstrapCell else {
			return
		}

		cell.configure(with: model.currentRomFileDescription!)

		tableView.beginUpdates()
		tableView.endUpdates()
	}
}

extension PreferencesAdvancedViewController { // UITableViewDataSource, UITableViewDelegate

	override func numberOfSections(in tableView: UITableView) -> Int {
		SectionType.count(model: model)
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {

		case .ramSetting:
			return 1
		case .frameRateSetting:
			return 2
		case .uiOptions:
			return model.shouldDisplayAlwaysLandscapeModeOption ? 3 : 2
		case .relateiveMouseMode:
			return 4
		case .secondFinger:
			if model.secondFingerSwipe {
				return 6
			} else if model.secondFingerClick {
				return 4
			}
			return 2
		case .bootstrap:
			return 1
		case .resources:
			return 3
		}
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		switch sectionType {
		case .ramSetting:
			return PreferencesAdvancedRamStepperCell(
				initialRamSettting: model.ramSetting
			) { [weak self] newValue in
				self?.model.ramSetting = newValue
			}
		case .frameRateSetting:
			switch indexPath.row {
			case 0:
				return PreferencesAdvancedFrameRateSettingCell(
					initialFrameRateSetting: model.frameRateSetting
				) { [weak self] newFrameRateSetting in
					self?.model.frameRateSetting = newFrameRateSetting
				}
			case 1:
				return PreferencesFooterCell(
					text: "Most games and apps have a maximum frame rate of 60 hz, 75 hz or lower. Higher frame rate settings impact performance. Changes in frame rate setting requires PocketShaver to restart."
				)
			default: fatalError()
			}
		case .uiOptions:
			switch indexPath.row {
			case 0:
				return PreferencesEnabledSettingCell(
					title: "Show FPS counter",
					isOn: model.showFpsCounterEnabled
				) { [weak self] isOn in
					self?.model.showFpsCounterEnabled = isOn
				}
			case 1:
				return PreferencesFooterCell(
					text: "PocketShaver only renders frames when there are visual changes. Therefore, low FPS count does not always mean low performace.",
					separatorHidden: false
				)
			case 2:
				return PreferencesEnabledSettingCell(
					title: "Always boot in landscape mode",
					isOn: model.alwaysLandscapeMode
				) { [weak self] isOn in
					self?.model.alwaysLandscapeMode = isOn
				}
			default: fatalError()
			}
		case .relateiveMouseMode:
			switch indexPath.row {
			case 0:
				return PreferencesAdvancedRelativeMouseModeSettingCell(
					initialRelativeMouseModeSetting: model.relativeMouseModeSetting
				) { [weak self] newFrameRateSetting in
					self?.model.relativeMouseModeSetting = newFrameRateSetting
				}
			case 1:
				return PreferencesAdvancedRelativeMouseModeFooterCell()
			case 2:
				return PreferencesEnabledSettingCell(
					title: "Tap to click",
					isOn: model.relativeMouseTapToClick
				) { [weak self] isOn in
					self?.model.relativeMouseTapToClick = isOn
				}
			case 3:
				return PreferencesFooterCell(
					text: "Setting only affects relative mouse mode."
				)
			default: fatalError()
			}
		case .secondFinger:
			switch indexPath.row {
			case 0:
				return PreferencesEnabledSettingCell(
					title: "Second finger click",
					isOn: model.secondFingerClick
				) { [weak self] isOn in
					self?.set(secondFingerClick: isOn)
				}
			case 1:
				return PreferencesFooterCell(
					text: "A second finger can be used for mouse clicking (while the first finger moves the position). Only has effect when either relative mouse mode or any of the hover modes are enabled.",
					separatorHidden: !model.secondFingerClick
				)
			case 2:
				return PreferencesEnabledSettingCell(
					title: "Second finger swipe",
					isOn: model.secondFingerSwipe
				) { [weak self] isOn in
					self?.set(secondFingerSwipe: isOn)
				}
			case 3:
				return PreferencesFooterCell(
					text: "A second finger can be used for quickly swiping between mouse offset modes. Only has effect when any of the hover modes are enabled. Can be used to switch between no offset / offset above / offset to the side / offset diagnoally above.",
					separatorHidden: !model.secondFingerSwipe
				)
			case 4:
				return PreferencesEnabledSettingCell(
					title: "Boot in hover mode",
					isOn: model.bootInHoverMode
				) { [weak self] isOn in
					self?.set(bootInHoverMode: isOn)
				}
			case 5:
				return PreferencesFooterCell(
					text: "Hover mode (without offset) is on by default when booting, making second finger swipe available from the start."
				)
			default: fatalError()
			}
		case .bootstrap:
			return PreferencesAdvancedBootstrapCell(
				romDescription: model.currentRomFileDescription!,
				didTapSelectInstallDiskButton: { [weak self] in
					self?.displayRomPicker()
				}
			)
		case .resources:
			switch indexPath.row {
			case 0:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Setup instructions"
				)
			case 1:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Bootstrap compatibility list"
				)
			case 2:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Licenses"
				)
			default: fatalError()
			}
		}
	}

	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
		case .ramSetting:
			return "RAM setting"
		case .frameRateSetting:
			return "Frame rate setting"
		case .uiOptions:
			return "UI options"
		case .relateiveMouseMode:
			return "Relative mouse mode"
		case .secondFinger:
			return "Second finger"
		case .bootstrap:
			return "Bootstrap"
		case .resources:
			return "Resources"
		}
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		return sectionType == .resources
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		switch sectionType {
		case .resources:
			switch indexPath.row {
			case 0:
				let vc = PreferencesSetupInstructionsViewController()
				let navVC = UINavigationController()
				navVC.viewControllers = [vc]

				present(navVC, animated: true)
			case 1:
				let vc = PreferencesCompatibilityListViewController()
				let navVC = UINavigationController()
				navVC.viewControllers = [vc]

				present(navVC, animated: true)
			case 2:
				let vc = PreferencesLicensesViewController()
				let navVC = UINavigationController()
				navVC.viewControllers = [vc]

				present(navVC, animated: true)
			default: fatalError()
			}
		default: fatalError()
		}
	}

	private func set(
		secondFingerClick: Bool? = nil,
		secondFingerSwipe: Bool? = nil,
		bootInHoverMode: Bool? = nil
	) {
		let prevSecondFingerClick = model.secondFingerClick
		let prevSecondFingerSwipe = model.secondFingerSwipe

		let secondFingerClick = secondFingerClick ?? model.secondFingerClick
		var secondFingerSwipe = secondFingerSwipe ?? model.secondFingerSwipe
		var bootInHoverMode = bootInHoverMode ?? model.bootInHoverMode

		if !secondFingerClick {
			secondFingerSwipe = false
			bootInHoverMode = false
		} else if !secondFingerSwipe {
			bootInHoverMode = false
		}

		model.secondFingerClick = secondFingerClick
		model.secondFingerSwipe = secondFingerSwipe
		model.bootInHoverMode = bootInHoverMode

		let sectionIndex = PreferencesAdvancedViewController.SectionType.secondFinger.sectionIndex(model: model)

		tableView.performBatchUpdates {
			if !prevSecondFingerClick,
			   secondFingerClick {
				tableView.insertRows(at: [
					.init(row: 2, section: sectionIndex),
					.init(row: 3, section: sectionIndex)
				], with: .fade)
				tableView.reloadRows(at: [
					.init(row: 1, section: sectionIndex)
				], with: .fade)
			} else if prevSecondFingerClick,
					  !secondFingerClick {
				tableView.deleteRows(at: [
					.init(row: 2, section: sectionIndex),
					.init(row: 3, section: sectionIndex)
				], with: .fade)
				tableView.reloadRows(at: [
					.init(row: 1, section: sectionIndex)
				], with: .fade)
			}
			if !prevSecondFingerSwipe,
			   secondFingerSwipe {
				tableView.insertRows(at: [
					.init(row: 4, section: sectionIndex),
					.init(row: 5, section: sectionIndex)
				], with: .fade)
				if secondFingerClick {
					tableView.reloadRows(at: [
						.init(row: 3, section: sectionIndex)
					], with: .fade)
				}
			} else if prevSecondFingerSwipe,
					  !secondFingerSwipe {
				tableView.deleteRows(at: [
					.init(row: 4, section: sectionIndex),
					.init(row: 5, section: sectionIndex)
				], with: .fade)
				if secondFingerClick {
					tableView.reloadRows(at: [
						.init(row: 3, section: sectionIndex)
					], with: .fade)
				}
			}
		}
	}
}

extension PreferencesAdvancedViewController: UIDocumentPickerDelegate {
	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		guard let url = urls.first else {
			return
		}

		Task { [weak self, model] in
			guard let self else { return }
			let validationResult = await model.didSelectMacOsInstallDiskCandidate(url: url)
			switch validationResult {
			case .success:
				displaySuccesfulBoostrapDialogue()
				updateBootstrapCell()
			case .incompatibleRom(let newWorldRomVersion):
				displayIncompatibleRomFoundDialogue(newWorldRomVersion)
			case .invalidFile:
				displayNoRomFoundDialogue()
			case .error(let error):
				let errorVC = UIAlertController.withError(error)
				present(errorVC, animated: true)
			}
		}
	}
}

extension PreferencesAdvancedViewController.SectionType {
	@MainActor
	init(sectionIndex: Int, model: PreferencesAdvancedModel) {
		let sections = Self.availableSections(with: model)
		self = sections[sectionIndex]
	}

	@MainActor
	static func count(model: PreferencesAdvancedModel) -> Int {
		let sections = Self.availableSections(with: model)
		return sections.count
	}

	@MainActor
	func sectionIndex(model: PreferencesAdvancedModel) -> Int {
		let sections = Self.availableSections(with: model)
		return sections.firstIndex(of: self)!
	}

	@MainActor
	private static func availableSections(with model: PreferencesAdvancedModel) -> [Self] {
		var sections = allCases
		if !model.hasRomFile,
		   let romSectionIndex = sections.firstIndex(of: .bootstrap) {
			sections.remove(at: romSectionIndex)
		}
		if !UIScreen.supportsHighRefreshRate,
		   let frameRateSettingIndex = sections.firstIndex(of: .frameRateSetting) {
			sections.remove(at: frameRateSettingIndex)
		}

		return sections
	}
}
