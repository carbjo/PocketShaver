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
		case gammaRampSetting
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
		case .gammaRampSetting:
			return "Gamma ramp"
		case .bootstrap:
			return "Bootstrap"
		case .resources:
			return "Resources"
		}
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
		case .ramSetting:
			return 1
		case .frameRateSetting:
			return 2
		case .uiOptions:
			return model.shouldDisplayAlwaysLandscapeModeOption ? 4 : 3
		case .relateiveMouseMode:
			return 4
		case .gammaRampSetting:
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
				return PreferencesInformationCell(
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
				return PreferencesInformationCell(
					text: "PocketShaver only renders frames when there are visual changes. Therefore, low FPS count does not always mean low performace.",
					separatorHidden: false
				)
			case 2:
				return PreferencesAdvancedJustAboveOffsetSettingCell(
					initialOffsetSetting: model.hoverJustAboveOffsetModifier
				) { [weak self] value in
					self?.model.hoverJustAboveOffsetModifier = value
				}
			case 3:
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
				let tagConfig = StringTagConfig(
					boldAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.primaryText),
					highlightedAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.highlightedText),
					images: [ImageResource.computermouse.asSymbolImage()]
				)

				return PreferencesInformationCell(
					text: "Some games and apps require relative mouse mode to function. If set to Manual or Automatic, Relative mouse mode can be toggled on and off by tapping the <img/> button above the keyboard. <link>Read more</link>.",
					tagConfig: tagConfig,
					separatorHidden: false
				) { [weak self] in
					guard let self else { return }
					let vc = PreferencesRelativeMouseModeOnboardingViewController()
					let navVC = UINavigationController()
					navVC.viewControllers = [vc]

					present(navVC, animated: true)
				}
			case 2:
				return PreferencesEnabledSettingCell(
					title: "Tap to click",
					isOn: model.relativeMouseTapToClick
				) { [weak self] isOn in
					self?.model.relativeMouseTapToClick = isOn
				}
			case 3:
				return PreferencesInformationCell(
					text: "Setting only affects relative mouse mode."
				)
			default: fatalError()
			}
		case .gammaRampSetting:
			switch indexPath.row {
			case 0:
				return PreferencesAdvancedGammaRampSettingCell(initialGammaRampSetting: model.gammaRampSetting) { [weak self] newGammaRampSetting in
					self?.model.gammaRampSetting = newGammaRampSetting
				}
			case 1:
				return PreferencesInformationCell(
					text: "Linear gamma ramp generally produces a darker, but less color distorted image. A higher set screen brightness can compansate the darkness and, in some instances, produce a higher color dynamic. Has effect on next resolution change or restart of PocketShaver."
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
