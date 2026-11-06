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
		case graphics
		case network
		case advanced

		var label: String {
			switch self {
			case .general: "General"
			case .graphics: "Graphics"
			case .network: "Network"
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
		if UIDevice.deviceType == .mac {
			// The Mac idiom swaps UIButton to an AppKit-style bezel that
			// ignores the filled configuration (fill, corner radius, frame
			// height), leaving a washed-out sliver. Keep the iPad rendering.
			button.preferredBehavioralStyle = .pad
			// The prefs window fills the whole Mac screen, so the default
			// title size gets lost in the full-width bar — scale the type up
			// with the taller Mac height set in viewDidLoad.
			button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
				var attributes = attributes
				attributes.font = .boldSystemFont(ofSize: 20)
				return attributes
			}
		}
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
	
	private lazy var graphicsVC: PreferencesGraphicsViewController = {
		PreferencesGraphicsViewController(
			mode: model.mode,
			changeSubject: model.changeSubject
		)
	}()

	private lazy var networkVC: PreferencesNetworkViewController = {
		PreferencesNetworkViewController(
			mode: model.mode
		)
	}()

	private lazy var advancedVC: PreferencesAdvancedViewController = {
		PreferencesAdvancedViewController(
			mode: model.mode,
			changeSubject: model.changeSubject
		)
	}()

	private var anyCancellables = Set<AnyCancellable>()

	@objc public private(set) var isDone: Bool = false

	private var displayedViewController: UIViewController?

	private var lockInterfaceOrientationsToLandscape = false
	private var pendingBoot: (() -> Void)?
	private var bootRotationRequestID = UUID()

	public override var shouldAutorotate: Bool {
		return true
	}

	public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
		if lockInterfaceOrientationsToLandscape {
			return .landscape
		} else {
			return UIDevice.isIPadIdiom ? .all : .allButUpsideDown
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

		// side constraints smaller on SE
		let tabSegmentedControlSideMargin: CGFloat
		if UIScreen.isSESize {
			tabSegmentedControlSideMargin = 4
		} else {
			tabSegmentedControlSideMargin = 22
		}

		NSLayoutConstraint.activate([
			tabSegmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			tabSegmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
			tabSegmentedControl.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor),
			tabSegmentedControl.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor),
			tabSegmentedControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: tabSegmentedControlSideMargin).withPriority(.defaultHigh),
			tabSegmentedControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -tabSegmentedControlSideMargin).withPriority(.defaultHigh),
			tabSegmentedControl.widthAnchor.constraint(lessThanOrEqualToConstant: 358),

			contentView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
			contentView.topAnchor.constraint(equalTo: tabSegmentedControl.bottomAnchor, constant: 8),
			contentView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
			contentView.bottomAnchor.constraint(equalTo: bottomButton.topAnchor, constant: -8),

			bottomButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
			bottomButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
			bottomButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
			bottomButton.heightAnchor.constraint(equalToConstant: UIDevice.deviceType == .mac ? 60 : 44)
		])

		embedViewController(generalVC)
		embedViewController(graphicsVC)
		embedViewController(networkVC)
		embedViewController(advancedVC)

		display(tab: .general)

		updateBottomButton()

		listenToChanges()
	}

	public override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		if model.mode == .duringEmulation {
			cpp_setInputDisabled(true)
		}
	}

	public override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		MonitorResolutionManager.shared.registerSafeAreaInsets(view.safeAreaInsets)
	}

	public override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)

		if model.mode == .duringEmulation {
			cpp_setInputDisabled(false)
		}
	}

	public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)

		MonitorResolutionManager.shared.registerSafeAreaInsets(view.safeAreaInsets)
	}

	public override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		coordinator.animate(alongsideTransition: nil) { [weak self] _ in
			self?.updateBottomButton()
			self?.finishBootAfterRotationIfReady(afterTransition: true)
		}
	}

	public override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		finishBootAfterRotationIfReady()
	}

	private func finishBootAfterRotationIfReady(afterTransition: Bool = false) {
		guard let pendingBoot,
			  view.window?.windowScene?.interfaceOrientation.isLandscape == true,
			  view.bounds.width > view.bounds.height,
			  afterTransition || transitionCoordinator == nil else { return }
		self.pendingBoot = nil
		// Leave UIKit's layout callback before removing the preferences window.
		DispatchQueue.main.async(execute: pendingBoot)
	}

	private func cancelPendingBootRotation(_ message: String) {
		guard pendingBoot != nil else { return }
		pendingBoot = nil
		lockInterfaceOrientationsToLandscape = false
		bottomButton.isEnabled = true
		if #available(iOS 16.0, *) {
			setNeedsUpdateOfSupportedInterfaceOrientations()
		}
		present(UIAlertController.withMessage(message), animated: true)
	}

	private func display(tab: Tab) {
		switch tab {
		case .general:
			contentView.bringSubviewToFront(generalVC.view)
		case .graphics:
			contentView.bringSubviewToFront(graphicsVC.view)
		case .network:
			contentView.bringSubviewToFront(networkVC.view)
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
			default:
				break
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
		guard pendingBoot == nil else { return }
		do {
			try model.validate()

			let bootBlock = { [weak self] in
				guard let self else { return }

				PreferencesManager.shared.writePreferences()
				objc_set_emulation_orientation(MonitorResolutionManager.shared.willLaunchInPortraitMode)
				DiskManager.shared.reportWillBoot()

				removeFromParent()
				prefsWindow.rootViewController = nil
				prefsWindow.isHidden = true

				isDone = true
			}

			if UIDevice.deviceType != .mac,
			   MiscellaneousSettings.current.alwaysLandscapeMode || forceLandscape {
				lockInterfaceOrientationsToLandscape = true
				pendingBoot = bootBlock
				let requestID = UUID()
				bootRotationRequestID = requestID
				bottomButton.isEnabled = false
				if #available(iOS 16.0, *) {
					setNeedsUpdateOfSupportedInterfaceOrientations()
					view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { [weak self] error in
						Task { @MainActor in
							guard self?.bootRotationRequestID == requestID else { return }
							self?.cancelPendingBootRotation(error.localizedDescription)
						}
					}
				} else {
					UIViewController.attemptRotationToDeviceOrientation()
				}
				finishBootAfterRotationIfReady()
				DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
					guard self?.bootRotationRequestID == requestID else { return }
					self?.cancelPendingBootRotation("Rotate the device or resize the window to landscape, then tap Boot again.")
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
	public static func presentStartup() -> PreferencesViewController {
		let vc = PreferencesViewController(mode: .startup)

		prefsWindow.windowLevel = .normal
		prefsWindow.makeKeyAndVisible()

		prefsWindow.rootViewController = vc

		#if targetEnvironment(macCatalyst)
		prefsWindow.windowScene?.fixStaleInactiveAppearanceAtLaunch()
		#endif

		return vc
	}

	@objc
	public static func resetPrefsWindow() {
		prefsWindow.rootViewController = nil
		prefsWindow.isHidden = true
	}
}

#if targetEnvironment(macCatalyst)
@MainActor private var staleInactiveAppearanceObserver: NSObjectProtocol?

private extension UIWindowScene {
	// Workaround for getting right tint color on UISwitch directly after app launch
	func fixStaleInactiveAppearanceAtLaunch() {
		guard #available(macCatalyst 17.0, *),
			  traitCollection.activeAppearance == .inactive,
			  let app = (NSClassFromString("NSApplication") as? NSObject.Type)?
				.value(forKey: "sharedApplication") as? NSObject,
			  (app.value(forKey: "active") as? Bool) == true
		else { return }

		traitOverrides.activeAppearance = .active

		staleInactiveAppearanceObserver = NotificationCenter.default.addObserver(
			forName: Notification.Name("NSApplicationDidResignActiveNotification"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.traitOverrides.remove(UITraitActiveAppearance.self)
				if let observer = staleInactiveAppearanceObserver {
					NotificationCenter.default.removeObserver(observer)
					staleInactiveAppearanceObserver = nil
				}
			}
		}
	}
}
#endif
