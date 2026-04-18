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
		case relateiveMouseMode
		case relateiveMouseModeClickGesture
		case hapticFeedback
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

		//relateiveMouseMode
		case relateiveMouseModeSetting
		case relateiveMouseModeInfo(RelativeMouseModeSetting)
		case relateiveMouseModeBoot
		case relateiveMouseModeBootInfo

		// relateiveMouseModeClickGesture
		case relativeMouseModeClickGestureSetting(RelativeMouseModeClickGestureSetting)
		case relativeMouseModeClickGestureSettingInfo

		// hapticFeedback
		case hapticFeedbackSwipeGesturesToggle
		case hapticFeedbackMouseClicksToggle
		case hapticFeedbackGamepadKeyStrokesToggle

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

	private var anyCancellables = Set<AnyCancellable>()

	private var dataSource: TableViewDiffableDataSource<Section, Row>!

	private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
	private let hoverJustAboveOffsetFeedbackGenerator = UISelectionFeedbackGenerator()

	init(
		mode: PreferencesLaunchMode,
		changeSubject: PassthroughSubject<PreferencesChange, Never>
	) {
		model = .init(
			mode: mode,
			changeSubject: changeSubject
		)

		super.init(nibName: nil, bundle: nil)

		view.backgroundColor = Colors.primaryBackground
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		tableView.showsVerticalScrollIndicator = false
		view.translatesAutoresizingMaskIntoConstraints = false

		setupDataSource()
		listenToChanges()
	}

	private func listenToChanges() {
		model.changeSubject.sink{ [weak self] change in
			guard let self else { return }
			switch change {
			case .iPadMouseEnabledChanged:
				reloadData()
			default:
				break
			}
		}.store(in: &anyCancellables)
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
					isOn: model.reportIpAddressAssignment
				) { [weak self] isOn in
					self?.model.reportIpAddressAssignment = isOn
				}
			case .relateiveMouseModeSetting:
				return PreferencesAdvancedRelativeMouseModeSettingCell(
					initialRelativeMouseModeSetting: model.relativeMouseModeSetting
				) { [weak self] newFrameRateSetting in
					guard let self else { return }
					model.relativeMouseModeSetting = newFrameRateSetting
					feedbackGenerator.impactOccurred()
					reloadData()
				}
			case .relateiveMouseModeInfo(let relativeMouseModeSetting):
				let duringEmulation = (model.mode == .startup) ? " during emulation" : ""
				var toggleExplanation = ""
				if relativeMouseModeSetting != .alwaysOn {
					switch UIDevice.deviceType {
					case .iPhone:
						toggleExplanation = " Relative mouse mode can be toggled on and off\(duringEmulation) by tapping the <img/> button above the keyboard or as a gamepad button."
					case .iPad:
						toggleExplanation = " Relative mouse mode can be toggled on and off\(duringEmulation) by tapping the <img/> button above the software keyboard or as a gamepad button. Alternatively by pressing option + F5, if using a hardware keyboard."
					case .mac:
						toggleExplanation = " Relative mouse mode can be toggled on and off\(duringEmulation) by pressing option + F5."
					}
				}
				return PreferencesInformationCell(
					text: "Some games and apps require relative mouse mode to function.\(toggleExplanation) <link>Read more</link>.",
					tagConfig: .init(
						images: [ImageResource.arrowUpAndDownAndArrowLeftAndRight.asSymbolImage()]
					)
				) { [weak self] in
					guard let self else { return }
					let vc = PreferencesRelativeMouseModeOnboardingViewController()
					let navVC = UINavigationController()
					navVC.viewControllers = [vc]

					present(navVC, animated: true)
				}
			case .relateiveMouseModeBoot:
				return PreferencesEnabledSettingCell(
					title: "Boot with relative mouse mode on",
					isOn: model.bootInRelativeMouseMode
				) { [weak self] isOn in
					self?.model.bootInRelativeMouseMode = isOn
				}
			case .relateiveMouseModeBootInfo:
				return PreferencesInformationCell(
					text: "Only has effect when input is set to Mouse."
				)
			case .relativeMouseModeClickGestureSetting(let setting):
				return PreferencesRadioButtonChoiceCell(
					title: setting.label,
					isSelected: setting == model.relativeMouseModeClickGestureSetting
				)
			case .relativeMouseModeClickGestureSettingInfo:
				let text: String
				switch model.relativeMouseModeClickGestureSetting {
				case .off:
					text = "Click can only be performed with Gamepad button."
				case .tap:
					text = "A quick tap induces mouse click."
				case .secondFingerClick:
					text = "A second finger control mouse down / up action while the first finger controls the position, as with two finger steering."
				}
				return PreferencesInformationCell(
					text: text
				)
			case .hapticFeedbackSwipeGesturesToggle:
				return PreferencesEnabledSettingCell(
					title: "Two / three finger swipe gestures",
					isOn: model.isGestureHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isGestureHapticFeedbackOn = isOn
				}
			case .hapticFeedbackMouseClicksToggle:
				return PreferencesEnabledSettingCell(
					title: "Mouse clicks",
					isOn: model.isMouseHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isMouseHapticFeedbackOn = isOn
				}
			case .hapticFeedbackGamepadKeyStrokesToggle:
				return PreferencesEnabledSettingCell(
					title: "Gamepad key strokes",
					isOn: model.isKeyHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isKeyHapticFeedbackOn = isOn
				}
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
			case .relateiveMouseMode:
				return "Relative mouse mode"
			case .relateiveMouseModeClickGesture:
				return "Relative mouse mode click gesture"
			case .hapticFeedback:
				return "Haptic feedback"
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
		if UIDevice.deviceType != .mac {
			snapshot.appendItems([.uiOptionsHoverJustAbove])
			if model.shouldDisplayAlwaysLandscapeModeOption {
				snapshot.appendItems([.uiOptionsAlwaysBootInLandscapeMode])
			}
		}
		snapshot.appendItems([.uiOptionsReportIpAddressAssignment])

		snapshot.appendSections([.relateiveMouseMode])
		snapshot.appendItems([
			.relateiveMouseModeSetting,
			.relateiveMouseModeInfo(model.relativeMouseModeSetting)
		])
		if model.relativeMouseModeSetting != .alwaysOn {
			switch UIDevice.deviceType {
			case .iPad:
				guard MiscellaneousSettings.current.iPadMousePassthrough else {
					break
				}
				snapshot.appendItems([
					.relateiveMouseModeBoot,
					.relateiveMouseModeBootInfo
				])
			case .mac:
				snapshot.appendItems([.relateiveMouseModeBoot])
			case .iPhone:
				break
			}
		}

		if !model.isIPadMouseEnabled {
			snapshot.appendSections([.relateiveMouseModeClickGesture])
			snapshot.appendItems(RelativeMouseModeClickGestureSetting.allCases.map({.relativeMouseModeClickGestureSetting($0)}))
			snapshot.appendItems([
				.relativeMouseModeClickGestureSettingInfo
			])
		}

		if model.supportsHaptics {
			snapshot.appendSections([.hapticFeedback])
			snapshot.appendItems([
				.hapticFeedbackSwipeGesturesToggle,
				.hapticFeedbackMouseClicksToggle,
				.hapticFeedbackGamepadKeyStrokesToggle
			])
		}

		if model.hasRomFile {
			snapshot.appendSections([.bootstrap])
			snapshot.appendItems([
				.bootstrap
			])
		}

		snapshot.appendSections([.resources])
		snapshot.appendItems([
			.resourcesSetupInstuctions,
			.resourcesBootstrapCompatiblityList
		])
		if UIDevice.deviceType != .mac {
			snapshot.appendItems([.resourcesTwoFingerSteeringOnboarding])
		}
		snapshot.appendItems([
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

	private func updateRelativeMouseModeClickGestureSettingCells() {
		for setting in RelativeMouseModeClickGestureSetting.allCases {
			guard let indexPath = dataSource.indexPath(for: .relativeMouseModeClickGestureSetting(setting)),
				  let cell = tableView.cellForRow(at: indexPath) as? PreferencesRadioButtonChoiceCell else {
				continue
			}

			cell.configure(isSelected: setting == model.relativeMouseModeClickGestureSetting)
		}

		dataSource.reloadItems([.relativeMouseModeClickGestureSettingInfo])
	}
}

extension PreferencesAdvancedViewController { // UITableViewDataSource, UITableViewDelegate

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		let sectionType = dataSource.sectionIdentifier(for: indexPath.section)
		let itemIdentifier = dataSource.itemIdentifier(for: indexPath)

		if sectionType == .resources {
			return true
		}

		if sectionType == .relateiveMouseModeClickGesture,
		   case .relativeMouseModeClickGestureSetting = itemIdentifier {
			return true
		}

		return false
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let sectionType = dataSource.sectionIdentifier(for: indexPath.section)
		let itemIdentifier = dataSource.itemIdentifier(for: indexPath)

		switch sectionType {
		case .resources:
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
		case .relateiveMouseModeClickGesture:
			switch itemIdentifier {
			case .relativeMouseModeClickGestureSetting(let setting):
				model.relativeMouseModeClickGestureSetting = setting
				updateRelativeMouseModeClickGestureSettingCells()
			default:
				fatalError()
			}
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

private extension RelativeMouseModeClickGestureSetting {
	var label: String {
		switch self {
		case .off: "Off"
		case .tap: "Tap"
		case .secondFingerClick: "Second finger click (recommended)"
		}
	}
}
