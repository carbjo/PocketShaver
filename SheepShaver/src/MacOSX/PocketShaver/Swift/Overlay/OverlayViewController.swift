//
//  OverlayViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

import UIKit
import Combine

enum OverlayState {
	case normal
	case showingKeyboard
	case showingGamepad
	case editingGamepad
}

@objc
public class OverlayViewController: UIViewController {

	// Retain state even if new instances of OverlayViewController is made by SDL
	@MainActor private static var globalState: OverlayState = .normal

	private var state: OverlayState {
		get {
			Self.globalState
		}
		set {
			Self.globalState = newValue
		}
	}

	private lazy var gestureInputView: GestureInputView = {
		let view = GestureInputView(state: state)
		view.translatesAutoresizingMaskIntoConstraints = false
		return view
	}()

	private lazy var dragInteractionModel: DragInteractionModel = {
		.init(
			fetchState: { [weak self] in
				Self.globalState
			}, fetchFrameSize: { [weak self] in
				self?.view.frame.size ?? .zero
			}, transformMainGamepadLayoutView: { [weak self] transform in
				self?.transformMainGamepadLayoutView(transform)
			}, transformAllGamepadLayoutViews: { [weak self] transform in
				self?.transformAllGamepadLayoutViews(transform)
			}, transformSDLView: { [weak self] transform in
				self?.transformSDLContainerView(transform)
			}
		)
	}()

	private lazy var gamepadLayerView: GamepadLayerView = {
		let view = GamepadLayerView(
			inputInteractionModel: inputInteractionModel,
			didRequestAssignmentForButton: { [weak self] position in
				self?.presentAlertForEditingButtonMapping(at: position)
			},
			didRequestAssignmentForSideButton: { [weak self] position in
				self?.presentAlertForEditingButtonMapping(at: position)
			},
			didRequestLayoutSettings: { [weak self] in
				self?.presentLayoutSettings()
			}
		)
		view.isUserInteractionEnabled = (state == .showingGamepad || state == .editingGamepad)
		view.alpha = 0
		return view
	}()

	private lazy var previousGamepadLayerView: GamepadLayerView = {
		GamepadLayerView()
	}()

	private lazy var nextGamepadLayerView: GamepadLayerView = {
		GamepadLayerView()
	}()

	private lazy var hiddenInputField: HiddenInputField = { [weak self] in
		guard let self else { fatalError() }
		return HiddenInputField(
			inputInteractionModel: inputInteractionModel,
			didTapPreferencesButton: { [weak self] in
				self?.presentPreferences()
			},
			didTapDismissKeyboardButton: { [weak self] in
				guard let self else { return }
				transition(to: .normal)
				informationView.showInformation(
					for: .normal,
					gamepadSettingsName: gamepadSettingsName,
					showHints: MiscellaneousSettings.current.showHints
				)
			},
			hiddenInputFieldDelegate: hiddenInputFieldDelegate
		)
	}()

	private lazy var informationView: InformationView = {
		let view = InformationView.withoutConstraints()
		view.isHidden = true
		view.alpha = 0
		return view
	}()

	private lazy var performanceLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.textColor = .white
		label.isUserInteractionEnabled = false
		label.numberOfLines = 0
		return label
	}()

	private lazy var inputInteractionModel: InputInteractionModel = {
		let model = InputInteractionModel.shared
		model.showWarning = { [weak self] warning in
			guard let self else { return }
			let alertVC = UIAlertController.withMessage(warning)
			present(alertVC, animated: true)
		}
		return model
	}()
	
	private let hiddenInputFieldDelegate = HiddenInputFieldDelegate()

	private var anyCancellables = Set<AnyCancellable>()

	private var gamepadConfig = GamepadManager.shared.config
	private var upcomingGamepadConfig: GamepadConfig?
	private var gamepadSettingsName: String {
		upcomingGamepadConfig?.name ?? gamepadConfig.name
	}

	private var performanceCounter: PerformanceCounter?

	private var queuedAlertController: UIAlertController?

	public override func viewDidLoad() {
		super.viewDidLoad()

		setupViews()

		hiddenInputFieldDelegate.didInputSDLKey = { [weak self] output in
			self?.inputInteractionModel.handle(output)
		}

		setupGestureInputView()

		if state != .normal {
			transition(to: state)
		}

		loadGamepadSettings()

		updatePerformanceCounter()

		listenToChanges()
	}

	public override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		if state != .showingGamepad {
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
		}

		if state == .normal {
			informationView.showInformation(
				for: .normal,
				gamepadSettingsName: gamepadSettingsName,
				showHints: MiscellaneousSettings.current.showHints,
				atBottom: true
			)
		}
		if gamepadLayerView.alpha == 0 {
			UIView.animate(withDuration: 0.2, delay: 0.5) {
				self.gamepadLayerView.alpha = 1
			}
		}
	}

	private func setupViews() {
		view.addSubview(gestureInputView)
		gestureInputView.addSubview(gamepadLayerView)
		gestureInputView.addSubview(previousGamepadLayerView)
		gestureInputView.addSubview(nextGamepadLayerView)

		gestureInputView.addSubview(hiddenInputField)

		view.addSubview(informationView)

		view.addSubview(performanceLabel)

		NSLayoutConstraint.activate([
			gestureInputView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			gestureInputView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			gestureInputView.topAnchor.constraint(equalTo: view.topAnchor),
			gestureInputView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

			gamepadLayerView.leadingAnchor.constraint(equalTo: gestureInputView.leadingAnchor),
			gamepadLayerView.trailingAnchor.constraint(equalTo: gestureInputView.trailingAnchor),
			gamepadLayerView.topAnchor.constraint(equalTo: gestureInputView.topAnchor),
			gamepadLayerView.bottomAnchor.constraint(equalTo: gestureInputView.bottomAnchor),

			previousGamepadLayerView.widthAnchor.constraint(equalTo: gamepadLayerView.widthAnchor),
			previousGamepadLayerView.heightAnchor.constraint(equalTo: gamepadLayerView.heightAnchor),
			previousGamepadLayerView.centerYAnchor.constraint(equalTo: gamepadLayerView.centerYAnchor),
			previousGamepadLayerView.trailingAnchor.constraint(equalTo: gamepadLayerView.leadingAnchor),

			nextGamepadLayerView.widthAnchor.constraint(equalTo: gamepadLayerView.widthAnchor),
			nextGamepadLayerView.heightAnchor.constraint(equalTo: gamepadLayerView.heightAnchor),
			nextGamepadLayerView.centerYAnchor.constraint(equalTo: gamepadLayerView.centerYAnchor),
			nextGamepadLayerView.leadingAnchor.constraint(equalTo: gamepadLayerView.trailingAnchor),

			hiddenInputField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			hiddenInputField.bottomAnchor.constraint(equalTo: view.topAnchor),

			informationView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			informationView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -UIScreen.main.bounds.size.height / 4),
			informationView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
			informationView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),

			performanceLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
			performanceLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
		])

		if UIDevice.isSimulator {
			becomeFirstResponder()
		}
	}

	public override var canBecomeFirstResponder: Bool {
		get {
			return UIDevice.isSimulator
		}
	}

	public override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
		if UIDevice.isSimulator,
		   motion == .motionShake {
			// For debugging purposes
			transition(to: .showingGamepad)
		}
	}

	private func listenToChanges() {
		inputInteractionModel.changeSubject.sink{ [weak self] change in
			guard let self else { return }
			switch change {
			case .relativeMouseModeChanged(let isEnabled):

				var hint: String
				if isEnabled {
					hint = "Relative mouse mode on"
					if MiscellaneousSettings.current.showHints,
					   !MiscellaneousSettings.current.iPadMousePassthrough {
						hint += "\nDrag to move mouse"
					}
				} else {
					hint = "Relative mouse mode off"
				}

				informationView.show(
					hintIcon: .computermouse,
					hint: hint,
					atBottom: state != .showingKeyboard
				)
			default: break
			}
		}.store(in: &anyCancellables)

		NotificationCenter.default.addObserver(self, selector: #selector(updatePerformanceCounter), name: LocalNotifications.performanceCounterSettingChanged, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayRelativeMouseCapabilityDialogueIfEligible), name: LocalNotifications.relativeMouseModeCapabilityFound, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayJaggyCursorWarningDialogueIfEligible), name: LocalNotifications.jaggyCursorResolutionSelected, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayGotIpAddress), name: LocalNotifications.gotIpAddress, object: nil)
	}

	private func loadGamepadSettings() {
		gamepadLayerView.load(config: gamepadConfig)
		previousGamepadLayerView.load(config: GamepadManager.shared.previousConfig)
		nextGamepadLayerView.load(config: GamepadManager.shared.nextConfig)
	}

	private func transition(to state: OverlayState) {
		self.state = state
		switch state {
		case .normal:
			transformSDLContainerView(.identity)
			dragInteractionModel.resetSdlViewVerticalOffset()
			hiddenInputField.resignFirstResponder()
			transformAllGamepadLayoutViews(.init(translationX: 0, y: -view.frame.size.height))
			gestureInputView.set(state: state)
			gamepadLayerView.isUserInteractionEnabled = false
		case .showingGamepad:
			transformAllGamepadLayoutViews(.identity)
			gamepadLayerView.set(isEditing: false)
			gestureInputView.set(state: state)
			gamepadLayerView.isUserInteractionEnabled = true
		case .showingKeyboard:
			hiddenInputField.becomeFirstResponder()
			transformAllGamepadLayoutViews(.init(translationX: 0, y: -view.frame.size.height))
			gestureInputView.set(state: state)
			gamepadLayerView.isUserInteractionEnabled = false
		case .editingGamepad:
			transformAllGamepadLayoutViews(.identity)
			gamepadLayerView.set(isEditing: true)
			gestureInputView.set(state: state)
			gamepadLayerView.isUserInteractionEnabled = true
		}

		inputInteractionModel.handleKeyboardShown(state == .showingKeyboard)
	}

	private func transitionToUpcomingGamepadConfig() {
		guard let upcomingGamepadConfig else {
			return
		}
		upcomingGamepadConfig.saveAsCurrent()
		gamepadConfig = upcomingGamepadConfig
		self.upcomingGamepadConfig = nil
		loadGamepadSettings()
		transition(to: .showingGamepad)
	}

	private func setupGestureInputView() {
		gestureInputView.reportThreeFingerDragProgress = { [weak self] delta in
			self?.dragInteractionModel.handleThreeFingerDragProgress(delta)
		}

		gestureInputView.didBeginThreeFingerGesture = { [weak self] in
			guard let self else { return }
			UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

			gamepadLayerView.layer.removeAllAnimations()
			previousGamepadLayerView.layer.removeAllAnimations()
			nextGamepadLayerView.layer.removeAllAnimations()
		}

		gestureInputView.didReleaseThreeFingerGesture = { [weak self] in
			guard let self else { return }

			let result = dragInteractionModel.handleReleaseThreeFingerGesture()

			switch result.gamepadChange {
			case .next:
				upcomingGamepadConfig = GamepadManager.shared.nextConfig
			case .previous:
				upcomingGamepadConfig = GamepadManager.shared.previousConfig
			default: break
			}

			informationView.showInformation(
				for: result.state,
				gamepadSettingsName: gamepadSettingsName,
				showHints: MiscellaneousSettings.current.showHints
			)

			UIView.animate(
				withDuration: result.willTranslateInLongAxis ? 0.6 : 0.28,
				delay: 0.0,
				usingSpringWithDamping: 0.6,
				initialSpringVelocity: 1.5,
				animations: {
					switch result.gamepadChange {
					case .none:
						self.transition(to: result.state)
					case .next:
						self.transformAllGamepadLayoutViews(.init(translationX: -self.view.frame.size.width, y: 0))
					case .previous:
						self.transformAllGamepadLayoutViews(.init(translationX: self.view.frame.size.width, y: 0))
					}
				},
				completion: { [weak self] _ in
					guard let self else { return }
					transitionToUpcomingGamepadConfig()
					if gamepadConfig.updateSlotPositionsIfNeeded() {
						gamepadLayerView.load(config: gamepadConfig)
					}
				}
			)
		}

		gestureInputView.reportTwoFingerDragProgress = { [weak self] delta in
			self?.dragInteractionModel.handleTwoFingerDragProgress(delta)
		}

		gestureInputView.reportSecondFingerDragProgress = { [weak self] delta in
			guard let self else { return }
			dragInteractionModel.handleSecondFingerDragProgress(delta)
			inputInteractionModel.handleSecondFingerDragDuringTwoFingerGesture()
		}

		gestureInputView.didBeginTwoFingerGesture = { [weak self] in
			self?.inputInteractionModel.beginSecondFingerClickIfEligible()
		}

		gestureInputView.didReleaseOneFingerDuringTwoFingerGesture = { [weak self] releaseFinger in
			guard let self else { return }
			if releaseFinger == .firstFinger {
				inputInteractionModel.handleFirstFingerReleaseDuringTwoFingerGesture()
			} else {
				inputInteractionModel.handleFinishTwoFingerGesture()
				dragInteractionModel.handleFinishTwoFingerGesture()
			}
		}

		dragInteractionModel.hasDraggedSecondFingerOverThreshold = { [weak self] result in
			self?.inputInteractionModel.handleSecondFingerReleaseResultIfEligible(result)
		}
	}

	private func transformMainGamepadLayoutView(_ transform: CGAffineTransform) {
		gamepadLayerView.transform = transform
	}

	private func transformAllGamepadLayoutViews(_ transform: CGAffineTransform) {
		gamepadLayerView.transform = transform
		previousGamepadLayerView.transform = transform
		nextGamepadLayerView.transform = transform
	}

	private func transformSDLContainerView(_ transform: CGAffineTransform) {
		guard let sdlView = view.superview else {
			return
		}

		sdlView.transform = transform
		view.transform = transform.inverted()
	}

	private func presentPreferences() {
		let vc = PreferencesViewController(mode: .duringEmulation)
		present(vc, animated: true)
	}

	private func presentAlertForEditingButtonMapping(at position: GamepadButtonPosition) {
		guard !gestureInputView.isDragging else {
			return
		}

		let vc = GamepadAssignButtonViewController(
			for: .regular
		){ [weak self] vc, result in
			guard let self else { return }

			vc.removeFromParent()
			vc.view.removeFromSuperview()

			switch result {
			case .assignment(let assignment):
				switch assignment {
				case .specialButton(let specialButton):
					gamepadConfig.replace(with: specialButton, at: position)
				case .key(let key):
					gamepadConfig.replace(with: key, at: position)
				case .joystick(let joystickType):
					do {
						try gamepadConfig.replace(with: joystickType, at: position)
					} catch GamepadConfigError.joystickAtBottomRow {
						let alertVc = UIAlertController.withMessage("Joystick must be placed above bottom row")
						present(alertVc, animated: true)
					} catch GamepadConfigError.joystickAtRightEdge {
						let alertVc = UIAlertController.withMessage("Joystick must be placed at least one column left of rightmost column")
						present(alertVc, animated: true)
					} catch GamepadConfigError.joystickHasNoLayoutSpace {
						let alertVc = UIAlertController.withMessage("The slot to the right, below and diagnoally right and below must all be vacant for a joystick to be placed. A joystick needs 2x2 slots.")
						present(alertVc, animated: true)
					} catch {}
				}
			case .unassign:
				gamepadConfig.removeAssignment(at: position)
			default:
				break
			}

			gamepadLayerView.load(config: gamepadConfig)
		}

		embed(vc)
		vc.animatePresent()
	}

	private func presentAlertForEditingButtonMapping(at position: GamepadSideButtonPosition) {
		guard !gestureInputView.isDragging else {
			return
		}

		let vc = GamepadAssignButtonViewController(
			for: .small
		) { [weak self] vc, result in
			guard let self else { return }

			vc.removeFromParent()
			vc.view.removeFromSuperview()

			switch result {
			case .assignment(let assignment):
				switch assignment {
				case .specialButton(let specialButton):
					gamepadConfig.replace(with: specialButton, at: position)
				case .key(let key):
					gamepadConfig.replace(with: key, at: position)
				case .joystick:
					fatalError()
				}
			case .unassign:
				gamepadConfig.removeAssignment(at: position)
			default:
				break
			}

			gamepadLayerView.load(config: gamepadConfig)

			view.layoutIfNeeded()

			UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) {
				self.gamepadLayerView.updateSlotVisiblity(afterUpdating: position)
			}
		}

		embed(vc)
		vc.animatePresent()
	}

	private func presentLayoutSettings() {
		guard !gestureInputView.isDragging else {
			return
		}

		let alertVC = UIAlertController(title: "Name layout", message: nil, preferredStyle: .alert)
		alertVC.addTextField() { textField in
			textField.autocapitalizationType = .words
		}
		alertVC.addAction(.init(title: "Cancel", style: .cancel))
		alertVC.addAction(.init(title: "OK", style: .default, handler: { [weak self] _ in
			guard let self,
				  let text = alertVC.textFields?[0].text,
			!text.isEmpty else {
				return
			}

			gamepadConfig.set(name: text)

			gamepadLayerView.load(config: gamepadConfig)
		}))

		present(alertVC, animated: true)
	}


	@objc
	private func updatePerformanceCounter() {
		if MiscellaneousSettings.current.fpsReporting ||
			MiscellaneousSettings.current.networkTransferRateReportingEnabled {
			let performanceCounter = PerformanceCounter()
			performanceCounter.delegate = self
			self.performanceCounter = performanceCounter
			performanceLabel.isHidden = false
		} else {
			self.performanceCounter = nil
			performanceLabel.isHidden = true
		}
	}

	@objc
	private func displayRelativeMouseCapabilityDialogueIfEligible() {
		guard !InformationConsumption.current.hasDisplayedFirstRelativeMouseDetectionDialogue else {
			return
		}
		InformationConsumption.current.reportHasDisplayedFirstRelativeMouseDetectionDialogue()

		let alertVC = UIAlertController(
			title: "Relative mouse mode",
			message: "The software launched might require relative mouse mode to be turned on in order to function. Mostly 3D games required this. Do you want PocketShaver to automatically turn relative mouse mode on and off in the future, or handle it manually? This behavior can be changed in Preferences, under Advanced tab. Relative mouse mode can be manually toggled on and off by the mouse button over the keyboard. Note that automatic detection is not perfect and can sometimes give false positives.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Manual", style: .cancel, handler: { [weak self] _ in
			guard let self else { return }
			if let queuedAlertController {
				self.queuedAlertController = nil
				present(queuedAlertController, animated: true)
			}
		}))
		alertVC.addAction(.init(title: "Automatic", style: .default, handler: { [weak self] _ in
			guard let self else { return }
			if !inputInteractionModel.isRelativeMouseModeEnabled {
				inputInteractionModel.toggleRelativeMouseMode()
			}
			MiscellaneousSettings.current.set(relativeMouseModeSetting: .automatic)

			if let queuedAlertController {
				self.queuedAlertController = nil
				present(queuedAlertController, animated: true)
			}
		}))

		if presentedViewController == nil {
			present(alertVC, animated: true)
		} else {
			queuedAlertController = alertVC
		}
	}

	@objc
	private func displayJaggyCursorWarningDialogueIfEligible() {
		let userCanSeeCursor = inputInteractionModel.isRelativeMouseModeEnabled || inputInteractionModel.hoverOffsetMode != .off

		guard !InformationConsumption.current.hasDisplayedJaggyCursorWarningDialogue,
		userCanSeeCursor else {
			return
		}
		InformationConsumption.current.reportHasDisplayedJaggyCursorWarningDialogue()

		let alertVC = UIAlertController(
			title: "Jaggy cursor warning",
			message: "The combination of screen resolution and color depth might result in a mouse cursor that is not moving in a smooth way. If you are experiencing issues with this and want to use 256 colors (8-bit) or thousands of colors (16-bit) mode, try using one of the classic screen resolutions 640x480, 800x600, 1024x768 or 1152x870.\nThis message will not be displayed again.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default, handler: { [weak self] _ in
			guard let self else { return }
			if let queuedAlertController {
				self.queuedAlertController = nil
				present(queuedAlertController, animated: true)
			}
		}))

		if presentedViewController == nil {
			present(alertVC, animated: true)
		} else {
			queuedAlertController = alertVC
		}
	}

	@objc
	private func displayGotIpAddress(notification: Notification) {
		guard let ipAddress = notification.object as? IpAddress,
		NetworkSettings.current.reportIpAddressAssignment else {
			return
		}

		informationView.show(
			hint: "Got IP address \(ipAddress.string)",
			atBottom: true
		)
	}
}

extension OverlayViewController {
	
	public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
		guard action.description != "_performClose:" else {
			// Handle Cmd+W: forward it to the emulated app instead of closing
			// The emulator will receive the keyboard event normally
			// We intentionally do nothing here to prevent the app from closing
			return true
		}

		return super.canPerformAction(action, withSender: sender)
	}

	@objc
	public static func injectOverlayViewController() {
		guard let window = UIApplication.shared.delegate?.window,
		let sdlVC = window?.rootViewController else {
			return
		}

		guard !sdlVC.children.contains(where: { $0 is OverlayViewController }) else {
			return
		}

		let vc = OverlayViewController()


		sdlVC.embed(vc)
	}
}

extension OverlayViewController: @preconcurrency PerformanceCounterDelegate {

	func performanceCounter(_ counter: PerformanceCounter, didUpdateWithReport report: PerformanceCounterReport) {
		if MiscellaneousSettings.current.fpsReporting && MiscellaneousSettings.current.networkTransferRateReportingEnabled {
			performanceLabel.text = "\(report.framesRendered)\n\(report.bytesTransferredString)"
		} else if MiscellaneousSettings.current.fpsReporting {
			performanceLabel.text = "\(report.framesRendered)"
		} else if MiscellaneousSettings.current.networkTransferRateReportingEnabled {
			performanceLabel.text = "\(report.bytesTransferredString)"
		}
	}
}
