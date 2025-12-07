//
//  PreferencesViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit
import Combine

@MainActor var prefsWindow : UIWindow = {
	UIWindow(frame: UIScreen.main.bounds)
}()

enum PreferencesLaunchMode {
	case startup
	case duringEmulation
}

@objc
public class PreferencesViewController: UIViewController {
	enum Tab: Int, CaseIterable {
		case general
		case resolutions
		case gamepad
		case advanced

		var label: String {
			switch self {
			case .general: "General"
			case .resolutions: "Resolutions"
			case .gamepad: "Gamepad"
			case .advanced: "Advanced"
			}
		}
	}

	private lazy var tabSegmentedControl: UISegmentedControl = {
		let segmentedControl = UISegmentedControl.withoutConstraints()
		for (index, tab) in Tab.allCases.enumerated() {
			segmentedControl.insertSegment(withTitle: tab.label, at: index, animated: false)
		}
		segmentedControl.selectedSegmentIndex = 0
		segmentedControl.addTarget(self, action: #selector(tabSegmentedControlChanged), for: .valueChanged)
		return segmentedControl
	}()

	private lazy var contentView: UIView = {
		UIView.withoutConstraints()
	}()

	private lazy var bottomButton: UIButton = {
		let button = UIButton.withoutConstraints()
		button.configuration = .defaultConfig
		button.configuration?.baseBackgroundColor = .gray
		button.addTarget(self, action: #selector(bottomButtonTapped), for: .touchUpInside)
		return button
	}()

	private let model: PreferencesModel

	private lazy var generalVC: PreferencesGeneralViewController = {
		PreferencesGeneralViewController(
			mode: model.mode,
			changeSubject: model.changeSubject
		)
	}()

	private lazy var resolutionsVC: PreferencesResolutionsViewController = {
		PreferencesResolutionsViewController(changeSubject: model.changeSubject)
	}()

	private lazy var gamepadVC: PreferencesGamepadViewController = {
		PreferencesGamepadViewController(changeSubject: model.changeSubject)
	}()

	private lazy var advancedVC: PreferencesAdvancedViewController = {
		PreferencesAdvancedViewController(changeSubject: model.changeSubject)
	}()

	private var anyCancellables = Set<AnyCancellable>()


	@objc public private(set) var isDone: Bool = false

	private var displayedViewController: UIViewController?

	private var lockInterfaceOrientationsToLandscape = false

	public override var shouldAutorotate: Bool {
		return true
	}

	public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
		if lockInterfaceOrientationsToLandscape {
			return .landscape
		} else {
			return .allButUpsideDown
		}
	}

	init(mode: PreferencesLaunchMode) {
		model = PreferencesModel(mode: mode)

		super.init(nibName: nil, bundle: nil)

		view.backgroundColor = Colors.primaryBackground
	}

	required init?(coder: NSCoder) { fatalError() }

	public override func viewDidLoad() {
		super.viewDidLoad()

		view.backgroundColor = .white

		view.addSubview(tabSegmentedControl)
		view.addSubview(contentView)
		view.addSubview(bottomButton)

		NSLayoutConstraint.activate([
			tabSegmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			tabSegmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
			tabSegmentedControl.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor),
			tabSegmentedControl.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor),

			contentView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
			contentView.topAnchor.constraint(equalTo: tabSegmentedControl.bottomAnchor, constant: 8),
			contentView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
			contentView.bottomAnchor.constraint(equalTo: bottomButton.topAnchor, constant: -8),

			bottomButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
			bottomButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
			bottomButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
			bottomButton.heightAnchor.constraint(equalToConstant: 44)
		])

		embedViewController(generalVC)
		embedViewController(resolutionsVC)
		embedViewController(gamepadVC)
		embedViewController(advancedVC)

		display(tab: .general)

		updateBottomButton()

		listenToChanges()
	}

	public override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		if MonitorResolutionManager.shared.registerSafeAreaInsets(view.safeAreaInsets) {
			resolutionsVC.tableView.reloadData()
		}
	}

	public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)

		if MonitorResolutionManager.shared.registerSafeAreaInsets(view.safeAreaInsets) {
			resolutionsVC.tableView.reloadData()
		}
	}

	public override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
			guard let self else { return }
			updateBottomButton()
		}
	}

	private func display(tab: Tab) {
		switch tab {
		case .general:
			contentView.bringSubviewToFront(generalVC.view)
		case .resolutions:
			contentView.bringSubviewToFront(resolutionsVC.view)
		case .gamepad:
			contentView.bringSubviewToFront(gamepadVC.view)
		case .advanced:
			contentView.bringSubviewToFront(advancedVC.view)
			advancedVC.tableView.reloadData()
		}
	}

	private func embedViewController(_ vc: UIViewController) {
		vc.willMove(toParent: self)
		contentView.addSubview(vc.view)

		NSLayoutConstraint.activate([
			vc.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			vc.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			vc.view.topAnchor.constraint(equalTo: contentView.topAnchor),
			vc.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
		])

		addChild(vc)
		vc.didMove(toParent: self)
	}

	private func listenToChanges() {
		model.changeSubject.sink{ [weak self] change in
			guard let self else { return }
			switch change {
			case .changeRequiringRestartBeforeBootMade:
				model.needsRestart = true
				updateBottomButton()
			case .changeRequiringRestartAfterBootMade:
				if model.mode == .duringEmulation {
					model.needsRestart = true
					updateBottomButton()
				}
			case .alwaysLandscapeModeOptionToggled:
				updateBottomButton()
			}
		}.store(in: &anyCancellables)
	}

	private func updateBottomButton() {
		if model.needsRestart {
			bottomButton.setTitle("Restart", for: .normal)
			return
		}

		switch model.mode {
		case .startup:
			let title: String
			if MiscellaneousSettings.current.alwaysLandscapeMode {
				title = "Boot"
			} else {
				title = UIScreen.isPortraitMode ? "Boot (portrait mode)" : "Boot (landscape mode)"
			}

			bottomButton.setTitle(title, for: .normal)
		case .duringEmulation:
			let title = "Done"
			bottomButton.setTitle(title, for: .normal)
		}
	}

	private func boot(forceLandscape: Bool = false) {
		do {
			try model.validate()

			if UIScreen.isPortraitMode,
			   !MiscellaneousSettings.current.hasDisplayedPortraitModeWarning {
				displayPortraitModeWarning()

				return
			}

			let bootBlock = { [weak self] in
				guard let self else { return }

				removeFromParent()
				prefsWindow.rootViewController = nil
				prefsWindow.isHidden = true

				isDone = true
			}

			if MiscellaneousSettings.current.alwaysLandscapeMode || forceLandscape,
			   !UIDevice.current.orientation.isLandscape {
				lockInterfaceOrientationsToLandscape = true
				UINavigationController.attemptRotationToDeviceOrientation()

				DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
					PreferencesManager.shared.writePreferences()
					bootBlock()
				}
			} else {
				bootBlock()
			}
		} catch PreferencesError.romFileMissing {
			if tabSegmentedControl.selectedSegmentIndex != Tab.general.rawValue {
				tabSegmentedControl.selectedSegmentIndex = Tab.general.rawValue
				display(tab: .general)
			}
			generalVC.presentRomFileMissingError()
		} catch PreferencesError.noMountedDiskFiles {
			if tabSegmentedControl.selectedSegmentIndex != Tab.general.rawValue {
				tabSegmentedControl.selectedSegmentIndex = Tab.general.rawValue
				display(tab: .general)
			}
			generalVC.presentNoDiskFilesError()
		} catch {}
	}

	private func displayNeedsRestartDialogue() {
		let alertVC = UIAlertController(
			title: "Restart needed",
			message: "PocketShaver needs to restart for the changes to take effect",
			preferredStyle: .alert
		)
		alertVC.addAction(.init(title: "Restart", style: .default, handler: { _ in
			Task { @MainActor in
				await UNUserNotificationCenter.current().scheduleRebootNotificationAndQuit()
			}
		}))
		if model.mode == .duringEmulation {
			alertVC.addAction(.init(title: "Later", style: .cancel, handler: { [weak self] _ in
				self?.dismiss(animated: true)
			}))
		}
		present(alertVC, animated: true)
	}

	private func displayPortraitModeWarning() {
		MiscellaneousSettings.current.set(hasDisplayedPortraitModeWarning: true)

		let alertVC = UIAlertController(
			title: "Landscape mode recommended",
			message: "It is recommended to boot in Landscape mode. Once booted, it is not possible to switch between portrait and landscape mode by rotating the device.\n\nThis warning will not be shown again.",
			preferredStyle: .alert
		)

		if MiscellaneousSettings.current.shouldDisplayAlwaysLandscapeModeOption {
			alertVC.addAction(.init(title: "Always boot in Landscape mode", style: .default, handler: { [weak self] _ in
				MiscellaneousSettings.current.set(alwaysLandscapeMode: true)
				self?.boot()
			}))
			alertVC.addAction(.init(title: "Boot in Landscape mode", style: .default, handler: { [weak self] _ in
				self?.boot(forceLandscape: true)
			}))
		}

		alertVC.addAction(.init(title: "Boot in Portrait mode", style: .default, handler: { [weak self] _ in
			self?.boot()
		}))

		if !MiscellaneousSettings.current.shouldDisplayAlwaysLandscapeModeOption {
			alertVC.addAction(.init(title: "Cancel", style: .cancel, handler: nil))
		}

		present(alertVC, animated: true)
	}

	@objc
	private func tabSegmentedControlChanged() {
		display(tab: Tab.allCases[tabSegmentedControl.selectedSegmentIndex])
	}

	@objc
	private func bottomButtonTapped() {
		PreferencesManager.shared.writePreferences()

		if model.needsRestart {
			displayNeedsRestartDialogue()
			return
		}

		switch model.mode {
		case .startup:
			boot()
		case .duringEmulation:
			dismiss(animated: true)
		}
	}

	@objc
	public static func present() -> PreferencesViewController {
		let vc = PreferencesViewController(mode: .startup)

		prefsWindow.windowLevel = .normal
		prefsWindow.makeKeyAndVisible()

		prefsWindow.rootViewController = vc

		return vc
	}

	@objc
	public static func resetPrefsWindow() {
		prefsWindow.rootViewController = nil
		prefsWindow.isHidden = true
	}
}
