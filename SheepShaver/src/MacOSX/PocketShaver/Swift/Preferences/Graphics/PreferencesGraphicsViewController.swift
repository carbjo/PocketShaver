//
//  PreferencesGraphicsViewController.swift
//  (C) 2026 Sierra Burkhart (sierra760)
//

import UIKit
import Combine

class PreferencesGraphicsViewController: UITableViewController {
	enum Section {
		case frameRateSetting
		case monitorResolutions
		case rendering
		case gammaRampSetting
		case graphicsAcceleration
	}

	enum Row: Hashable {
		// frameRateSetting
		case frameRateSettingToggle
		case frameRateSettingInfo(PreferencesGraphicsModel.FrameRateState)

		// monitorResolutions
		case monitorResolutions(PreferencesGraphicsModel.MonitorResolutionsState)
		case monitorResolutionsInformation(Bool)

		// graphicsAcceleration
		case graphicsAccelerationNqdToggle
		case graphicsAccelerationRaveToggle
		case graphicsAccelerationGlToggle
		case graphicsAccelerationDspToggle
		case graphicsAccelerationInfo

		// rendering
		case renderingFilterMode
		case renderingFilterModeInfo

		// gammaRampSetting
		case gammaRampSetting
		case gammaRampSettingInfo
	}

	private let model: PreferencesGraphicsModel
	private let preferencesResolutionsVC: PreferencesResolutionsViewController
	private let changeSubject: PassthroughSubject<PreferencesChange, Never>

	private var dataSource: TableViewDiffableDataSource<Section, Row>!

	private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

	private var anyCancellables = Set<AnyCancellable>()

	init(
		mode: PreferencesLaunchMode,
		changeSubject: PassthroughSubject<PreferencesChange, Never>
	) {
		self.changeSubject = changeSubject
		model = .init(mode: mode, changeSubject: changeSubject)
		preferencesResolutionsVC = PreferencesResolutionsViewController(changeSubject: changeSubject)

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
		changeSubject.sink { [weak self] change in
			guard let self else { return }
			switch change {
			case .frameRateSettingChanged:
				reloadData()
			case .selectedResolutionsChanged:
				reloadSection(.monitorResolutions)
			default:
				break
			}
		}.store(in: &anyCancellables)
	}

	private func reloadSection(_ section: Section) {
		var snapshot = dataSource.snapshot()
		snapshot.reloadSections([section])
		dataSource.apply(snapshot)
	}

	private func setupDataSource() {
		dataSource = .init(tableView: tableView) { [weak self] tableView, indexPath, itemIdentifier in
			guard let self else { return UITableViewCell() }
			switch itemIdentifier {
			case .frameRateSettingToggle:
				return PreferencesGraphicsFrameRateSettingCell(
					initialFrameRateSetting: model.frameRateSetting
				) { [weak self] newFrameRateSetting in
					guard let self else { return }
					model.frameRateSetting = newFrameRateSetting
					feedbackGenerator.impactOccurred()
				}
			case .frameRateSettingInfo(let frameRateState):
				var text = ""
				if frameRateState.setting == .f120hz {
					text += "At 120 hz, software with uncapped framerate might behave erratic."
				}
				if model.mode == .duringEmulation,
				   frameRateState.hasChanged {
					if !text.isEmpty {
						text += " "
					}
					text += "Changes in frame rate setting requires PocketShaver to restart."
				}
				return PreferencesCardInformationCell(
					text: text
				)
			case .monitorResolutions:
				return PreferencesGraphicsEnabledMonitorResolutionsCell(
					monitorResolutionsState: model.monitorResolutionsState
				) { [weak self] in
					guard let self else { return }
					let vc = preferencesResolutionsVC
					let navVC = UINavigationController()
					navVC.viewControllers = [vc]

					present(navVC, animated: true)
				}
			case .monitorResolutionsInformation(let willBootFromCD):
				var text = "Resolutions made available to Mac OS. "
				if willBootFromCD {
					text += "List is restricted since emulaton will boot from an install CD."
				} else {
					text += "Can be edited."
				}
				return PreferencesInformationCell(
					text: text
				)
			case .renderingFilterMode:
				return PreferencesGraphicsRenderingFilterCell(
					initialFilterMode: model.renderingFilterMode
				) { [weak self] newMode in
					guard let self else { return }
					model.renderingFilterMode = newMode
					feedbackGenerator.impactOccurred()
				}
			case .renderingFilterModeInfo:
				return PreferencesInformationCell(
					text: "Bilinear produces a smooth image through interpolation. Nearest neighbor gives a sharp, \"retro\" pixelated look. Takes effect on next resolution change or restart."
				)
			case .gammaRampSetting:
				return PreferencesGraphicsGammaRampSettingCell(
					initialGammaRampSetting: model.gammaRampSetting
				) { [weak self] newGammaRampSetting in
					guard let self else { return }
					model.gammaRampSetting = newGammaRampSetting
					feedbackGenerator.impactOccurred()
				}
			case .gammaRampSettingInfo:
				return PreferencesInformationCell(
					text: "Linear gamma ramp generally produces a darker, but less color distorted image. A higher set screen brightness can compansate the darkness and, in some instances, produce a higher color dynamic. Takes effect on next resolution change or restart."
				)
			case .graphicsAccelerationNqdToggle:
				return PreferencesEnabledSettingCell(
					title: "NQD Acceleration",
					isOn: model.nqdAccelEnabled
				) { [weak self] isOn in
					self?.model.nqdAccelEnabled = isOn
				}
			case .graphicsAccelerationRaveToggle:
				return PreferencesEnabledSettingCell(
					title: "RAVE Acceleration",
					isOn: model.raveAccelEnabled
				) { [weak self] isOn in
					self?.model.raveAccelEnabled = isOn
				}
			case .graphicsAccelerationGlToggle:
				return PreferencesEnabledSettingCell(
					title: "OpenGL Acceleration",
					isOn: model.glAccelEnabled
				) { [weak self] isOn in
					self?.model.glAccelEnabled = isOn
				}
			case .graphicsAccelerationDspToggle:
				return PreferencesEnabledSettingCell(
					title: "DrawSprocket Acceleration",
					isOn: model.dspAccelEnabled
				) { [weak self] isOn in
					self?.model.dspAccelEnabled = isOn
				}
			case .graphicsAccelerationInfo:
				var takesEffectOnRestartSuffix = ""
				if model.mode == .duringEmulation {
					takesEffectOnRestartSuffix = " Changes take effect on restart."
				}
				return PreferencesInformationCell(
					text: "Experimental — Requires Metal GPU." + takesEffectOnRestartSuffix
				)
			}
		}

		dataSource.sectionTitleProvider = { section in
			switch section {
			case .frameRateSetting:
				return "Frame rate setting"
			case .monitorResolutions:
				return "Monitor resolutions"
			case .graphicsAcceleration:
				return "Graphics Acceleration"
			case .rendering:
				return "Rendering filter"
			case .gammaRampSetting:
				return "Gamma ramp"
			}
		}

		dataSource.defaultRowAnimation = .fade
		tableView.dataSource = dataSource

		reloadData()
	}

	private func reloadData() {
		var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()

		if UIScreen.supportsHighRefreshRate {
			snapshot.appendSections([.frameRateSetting])
			snapshot.appendItems([.frameRateSettingToggle])
			if model.frameRateState.setting == .f120hz ||
				(model.mode == .duringEmulation && model.frameRateState.hasChanged) {
				snapshot.appendItems([.frameRateSettingInfo(model.frameRateState)])
			}
		}

		snapshot.appendSections([.monitorResolutions])
		snapshot.appendItems([
			.monitorResolutions(model.monitorResolutionsState),
			.monitorResolutionsInformation(model.monitorResolutionsState.willBootFromCD)
		])

		snapshot.appendSections([.graphicsAcceleration])
		snapshot.appendItems([
			.graphicsAccelerationNqdToggle,
			.graphicsAccelerationRaveToggle,
			.graphicsAccelerationGlToggle,
			.graphicsAccelerationDspToggle,
			.graphicsAccelerationInfo
		])

		snapshot.appendSections([.rendering])
		snapshot.appendItems([
			.renderingFilterMode,
			.renderingFilterModeInfo
		])

		snapshot.appendSections([.gammaRampSetting])
		snapshot.appendItems([
			.gammaRampSetting,
			.gammaRampSettingInfo
		])

		dataSource.apply(snapshot)
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}
}
