//
//  PreferencesGraphicsViewController.swift
//  (C) 2026 Sierra Burkhart (sierra760)
//

import UIKit
import Combine

class PreferencesGraphicsViewController: UITableViewController {
	enum Section {
		case monitorResolutions
		case rendering
		case frameRateSetting
		case gammaRampSetting
		case graphicsAcceleration
	}

	enum Row: Hashable {
		// monitorResolutions
		case monitorResolutionsDisplay
		case monitorResolutionsInfo

		// rendering
		case renderingFilterMode
		case renderingFilterModeInfo

		// frameRateSetting
		case frameRateSettingToggle
		case frameRateSettingInfo

		// gammaRampSetting
		case gammaRampSetting
		case gammaRampSettingInfo

		// graphicsAcceleration
		case graphicsAccelerationNqdToggle
		case graphicsAccelerationRaveToggle
		case graphicsAccelerationGlToggle
		case graphicsAccelerationInfo
	}

	private let model: PreferencesGraphicsModel
	private let preferencesResolutionsVC: PreferencesResolutionsViewController
	private let changeSubject: PassthroughSubject<PreferencesChange, Never>

	private var dataSource: TableViewDiffableDataSource<Section, Row>!

	private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

	private var anyCancellables = Set<AnyCancellable>()

	init(changeSubject: PassthroughSubject<PreferencesChange, Never>) {
		self.changeSubject = changeSubject
		model = .init(changeSubject: changeSubject)
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
			case .monitorResolutionsDisplay:
				let monitorResolutionsState = PreferencesGeneralModel.MonitorResolutionsState(
					enabledResolutions: model.monitorResolutions,
					willBootFromCD: model.willBootFromCD
				)
				return PreferencesGeneralEnabledMonitorResolutionsCell(
					monitorResolutionsState: monitorResolutionsState
				) { [weak self] in
					guard let self else { return }
					let vc = preferencesResolutionsVC
					let navVC = UINavigationController()
					navVC.viewControllers = [vc]

					present(navVC, animated: true)
				}
			case .monitorResolutionsInfo:
				var text = "Resolutions made available to Mac OS. "
				if model.willBootFromCD {
					text += "List is restricted since emulation will boot from an install CD."
				} else {
					text += "Can be edited."
				}
				return PreferencesInformationCell(text: text)

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
					text: "Nearest neighbor gives a sharp, retro pixelated look. Bilinear produces a smoother image through interpolation. Takes effect on next resolution change or restart."
				)

			case .frameRateSettingToggle:
				return PreferencesAdvancedFrameRateSettingCell(
					initialFrameRateSetting: model.frameRateSetting
				) { [weak self] newFrameRateSetting in
					guard let self else { return }
					model.frameRateSetting = newFrameRateSetting
					feedbackGenerator.impactOccurred()
				}
			case .frameRateSettingInfo:
				return PreferencesInformationCell(
					text: "Most games and apps have a maximum frame rate of 60 hz, 75 hz or lower. Higher frame rate settings impact performance. Changes in frame rate setting requires PocketShaver to restart."
				)

			case .gammaRampSetting:
				return PreferencesAdvancedGammaRampSettingCell(
					initialGammaRampSetting: model.gammaRampSetting
				) { [weak self] newGammaRampSetting in
					guard let self else { return }
					model.gammaRampSetting = newGammaRampSetting
					feedbackGenerator.impactOccurred()
				}
			case .gammaRampSettingInfo:
				return PreferencesInformationCell(
					text: "Linear gamma ramp generally produces a darker, but less color distorted image. A higher set screen brightness can compansate the darkness and, in some instances, produce a higher color dynamic. Has effect on next resolution change or restart of PocketShaver."
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
			case .graphicsAccelerationInfo:
				return PreferencesInformationCell(
					text: "Experimental — Requires Metal GPU. Changes take effect on restart."
				)
			}
		}

		dataSource.sectionTitleProvider = { section in
			switch section {
			case .monitorResolutions:
				return "Monitor resolutions"
			case .rendering:
				return "Rendering"
			case .frameRateSetting:
				return "Frame rate setting"
			case .gammaRampSetting:
				return "Gamma ramp"
			case .graphicsAcceleration:
				return "Graphics Acceleration"
			}
		}

		dataSource.defaultRowAnimation = .fade
		tableView.dataSource = dataSource

		reloadData()
	}

	private func reloadData() {
		var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()

		snapshot.appendSections([.monitorResolutions])
		snapshot.appendItems([
			.monitorResolutionsDisplay,
			.monitorResolutionsInfo
		])

		snapshot.appendSections([.rendering])
		snapshot.appendItems([
			.renderingFilterMode,
			.renderingFilterModeInfo
		])

		if UIScreen.supportsHighRefreshRate {
			snapshot.appendSections([.frameRateSetting])
			snapshot.appendItems([
				.frameRateSettingToggle,
				.frameRateSettingInfo
			])
		}

		snapshot.appendSections([.gammaRampSetting])
		snapshot.appendItems([
			.gammaRampSetting,
			.gammaRampSettingInfo
		])

		snapshot.appendSections([.graphicsAcceleration])
		snapshot.appendItems([
			.graphicsAccelerationNqdToggle,
			.graphicsAccelerationRaveToggle,
			.graphicsAccelerationGlToggle,
			.graphicsAccelerationInfo
		])

		dataSource.apply(snapshot)
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}
}
