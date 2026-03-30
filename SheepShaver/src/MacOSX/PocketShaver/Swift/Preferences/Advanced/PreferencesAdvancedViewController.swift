//
//  PreferencesAdvancedViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit
import Combine

class PreferencesAdvancedViewController: UITableViewController {
	enum Section {
		case ramSetting
		case performanceMetrics
		case uiOptions
		case emulation
		case relateiveMouseMode
		case bootstrap
		case resources
	}

	enum Row: Hashable {
		//ramSetting
		case ramSetting

		//performanceMetrics
		case performanceMetricsFpsCounterToggle
		case performanceMetricsFpsCounterInfo
		case performanceMetricsNetworkTransferRateToggle

		//uiOptions
		case uiOptionsHoverJustAbove
		case uiOptionsAlwaysBootInLandscapeMode
		case uiOptionsReportIpAddressAssignment

		//emulation
		case emulationIgnoreIllegalInstructions
		case emulationIgnoreIllegalInstructionsInfo

		//relateiveMouseMode
		case relateiveMouseModeSetting
		case relateiveMouseModeInfo
		case relateiveMouseTapToClickToggle
		case relateiveMouseTapToClickInfo

		//bootstrap
		case bootstrap

		//resources
		case resourcesSetupInstuctions
		case resourcesBootstrapCompatiblityList
		case resourcesTwoFingerSteeringOnboarding
		case resourcesRelativeMouseModeOnboarding
		case resourcesLicenses
	}

	private let model: PreferencesAdvancedModel

	private var dataSource: TableViewDiffableDataSource<Section, Row>!

	private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
	private let hoverJustAboveOffsetFeedbackGenerator = UISelectionFeedbackGenerator()

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

		setupDataSource()
	}

	private func setupDataSource() {
		dataSource = .init(tableView: tableView) { [weak self] tableView, indexPath, itemIdentifier in
			guard let self else { return UITableViewCell() }
			switch itemIdentifier {
			case .ramSetting:
				return PreferencesAdvancedRamStepperCell(
					initialRamSettting: model.ramSetting
				) { [weak self] newValue in
					guard let self else { return }
					model.ramSetting = newValue
					feedbackGenerator.impactOccurred()
				}
			case .performanceMetricsFpsCounterToggle:
				return PreferencesEnabledSettingCell(
					title: "Show FPS counter",
					isOn: model.fpsReportingEnabled
				) { [weak self] isOn in
					self?.model.fpsReportingEnabled = isOn
				}
			case .performanceMetricsFpsCounterInfo:
				return PreferencesInformationCell(
					text: "PocketShaver only renders frames when there are visual changes. Therefore, low FPS count does not always mean low performace.",
					separatorHidden: false
				)
			case .performanceMetricsNetworkTransferRateToggle:
				return PreferencesEnabledSettingCell(
					title: "Show network transfer rate",
					isOn: model.networkTransferRateReportingEnabled
				) { [weak self] isOn in
					self?.model.networkTransferRateReportingEnabled = isOn
				}
			case .uiOptionsHoverJustAbove:
				return PreferencesAdvancedJustAboveOffsetSettingCell(
					initialOffsetSetting: model.hoverJustAboveOffsetModifier,
					isChangingValue: { [weak self] in
						self?.hoverJustAboveOffsetFeedbackGenerator.selectionChanged()
					}
				) { [weak self] value in
					self?.model.hoverJustAboveOffsetModifier = value
				}
			case .uiOptionsAlwaysBootInLandscapeMode:
				return PreferencesEnabledSettingCell(
					title: "Always boot in landscape mode",
					isOn: model.alwaysLandscapeMode
				) { [weak self] isOn in
					self?.model.alwaysLandscapeMode = isOn
				}
			case .uiOptionsReportIpAddressAssignment:
				return PreferencesEnabledSettingCell(
					title: "Report IP address assignment",
					isOn: model.networkTransferRateReportingEnabled
				) { [weak self] isOn in
					self?.model.networkTransferRateReportingEnabled = isOn
				}
			case .emulationIgnoreIllegalInstructions:
				return PreferencesEnabledSettingCell(
					title: "Ignore illegal instructions",
					isOn: model.ignoreIllegalInstructions
				) { [weak self] isOn in
					self?.model.ignoreIllegalInstructions = isOn
				}
			case .emulationIgnoreIllegalInstructionsInfo:
				return PreferencesInformationCell(
					text: "When enabled, unrecognized PowerPC instructions are skipped instead of crashing the emulator. May improve compatibility with some apps.",
					separatorHidden: false
				)
			case .relateiveMouseModeSetting:
				return PreferencesAdvancedRelativeMouseModeSettingCell(
					initialRelativeMouseModeSetting: model.relativeMouseModeSetting
				) { [weak self] newFrameRateSetting in
					guard let self else { return }
					model.relativeMouseModeSetting = newFrameRateSetting
					feedbackGenerator.impactOccurred()
				}
			case .relateiveMouseModeInfo:
				return PreferencesInformationCell(
					text: "Some games and apps require relative mouse mode to function. If set to Manual or Automatic, Relative mouse mode can be toggled on and off by tapping the <img/> button above the keyboard. <link>Read more</link>.",
					tagConfig: .init(
						images: [ImageResource.computermouse.asSymbolImage()]
					),
					separatorHidden: false
				) { [weak self] in
					guard let self else { return }
					let vc = PreferencesRelativeMouseModeOnboardingViewController()
					let navVC = UINavigationController()
					navVC.viewControllers = [vc]

					present(navVC, animated: true)
				}
			case .relateiveMouseTapToClickToggle:
				return PreferencesEnabledSettingCell(
					title: "Tap to click",
					isOn: model.relativeMouseTapToClick
				) { [weak self] isOn in
					self?.model.relativeMouseTapToClick = isOn
				}
			case .relateiveMouseTapToClickInfo:
				return PreferencesInformationCell(
					text: "Setting only affects relative mouse mode."
				)
			case .bootstrap:
				return PreferencesAdvancedBootstrapCell(
					romDescription: model.currentRomFileDescription!,
					didTapSelectInstallDiskButton: { [weak self] in
						self?.displayRomPicker()
					}
				)
			case .resourcesSetupInstuctions:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Setup instructions"
				)
			case .resourcesBootstrapCompatiblityList:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Bootstrap compatibility list"
				)
			case .resourcesTwoFingerSteeringOnboarding:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Two finger steering onboarding"
				)
			case .resourcesRelativeMouseModeOnboarding:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Relative mouse mode onboarding"
				)
			case .resourcesLicenses:
				return PreferencesAdvancedMiscellaneousCell(
					title: "Licenses"
				)
			}
		}

		dataSource.sectionTitleProvider = { section in
			switch section {
			case .ramSetting:
				return "RAM setting"
			case .performanceMetrics:
				return "Performance metrics"
			case .uiOptions:
				return "UI options"
			case .emulation:
				return "Emulation"
			case .relateiveMouseMode:
				return "Relative mouse mode"
			case .bootstrap:
				return "Bootstrap"
			case .resources:
				return "Resources"
			}
		}

		dataSource.defaultRowAnimation = .fade
		tableView.dataSource = dataSource

		reloadData()
	}

	private func reloadData() {
		var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()

		snapshot.appendSections([.ramSetting])
		snapshot.appendItems([.ramSetting])

		snapshot.appendSections([.performanceMetrics])
		snapshot.appendItems([
			.performanceMetricsFpsCounterToggle,
			.performanceMetricsFpsCounterInfo,
			.performanceMetricsNetworkTransferRateToggle
		])

		snapshot.appendSections([.uiOptions])
		snapshot.appendItems([.uiOptionsHoverJustAbove])
		if model.shouldDisplayAlwaysLandscapeModeOption {
			snapshot.appendItems([.uiOptionsAlwaysBootInLandscapeMode])
		}
		snapshot.appendItems([.uiOptionsReportIpAddressAssignment])

		snapshot.appendSections([.emulation])
		snapshot.appendItems([
			.emulationIgnoreIllegalInstructions,
			.emulationIgnoreIllegalInstructionsInfo
		])

		snapshot.appendSections([.relateiveMouseMode])
		snapshot.appendItems([
			.relateiveMouseModeSetting,
			.relateiveMouseModeInfo,
			.relateiveMouseTapToClickToggle,
			.relateiveMouseTapToClickInfo
		])

		if model.hasRomFile {
			snapshot.appendSections([.bootstrap])
			snapshot.appendItems([
				.bootstrap
			])
		}

		snapshot.appendSections([.resources])
		snapshot.appendItems([
			.resourcesSetupInstuctions,
			.resourcesBootstrapCompatiblityList,
			.resourcesTwoFingerSteeringOnboarding,
			.resourcesRelativeMouseModeOnboarding,
			.resourcesLicenses
		])

		dataSource.apply(snapshot)
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
		guard model.hasRomFile,
			  let indexPath = dataSource.indexPath(for: .bootstrap),
			  let cell = tableView.cellForRow(at: indexPath) as? PreferencesAdvancedBootstrapCell else {
			return
		}

		cell.configure(with: model.currentRomFileDescription!)

		tableView.beginUpdates()
		tableView.endUpdates()
	}
}

extension PreferencesAdvancedViewController { // UITableViewDataSource, UITableViewDelegate

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		let sectionType = dataSource.sectionIdentifier(for: indexPath.section)
		return sectionType == .resources
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let itemIdentifier = dataSource.itemIdentifier(for: indexPath)
		switch itemIdentifier {
		case .resourcesSetupInstuctions:
			let vc = PreferencesSetupInstructionsViewController()
			let navVC = UINavigationController()
			navVC.viewControllers = [vc]

			present(navVC, animated: true)
		case .resourcesBootstrapCompatiblityList:
			let vc = PreferencesCompatibilityListViewController()
			let navVC = UINavigationController()
			navVC.viewControllers = [vc]

			present(navVC, animated: true)
		case .resourcesTwoFingerSteeringOnboarding:
			let vc = PreferencesTwoFingerSteeringOnboardingViewController()
			let navVC = UINavigationController()
			navVC.viewControllers = [vc]

			present(navVC, animated: true)
		case .resourcesRelativeMouseModeOnboarding:
			let vc = PreferencesRelativeMouseModeOnboardingViewController()
			let navVC = UINavigationController()
			navVC.viewControllers = [vc]

			present(navVC, animated: true)
		case .resourcesLicenses:
			let vc = PreferencesLicensesViewController()
			let navVC = UINavigationController()
			navVC.viewControllers = [vc]

			present(navVC, animated: true)
		default:
			fatalError()
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
