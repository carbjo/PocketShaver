//
//  OverlayViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

import UIKit
import NotificationCenter

enum OverlayState {
	case normal
	case showingKeyboard
	case showingGamepad
	case editingGamepad
}

@objc
public class OverlayViewController: UIViewController {

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

	private var threeFingerGestureDragDelta: CGVector = .zero
	private var threeFingerGestureDragDeltaSinceLatestHapticFeedback: CGVector = .zero

	private var sdlViewVerticalOffset: CGFloat = .zero
	private var twoFingerGestureDragDeltaSinceLatestHapticFeedback: CGFloat = .zero

	private var dragHapticFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

	private lazy var gamepadLayerView: GamepadLayerView = {
		GamepadLayerView(
			keyInteraction: keyInteraction,
			specialButtonInteraction: specialButtonInteraction,
			didRequestAssignmentAt: { [weak self] position in
				self?.presentAlertForEditingButtonMapping(at: position)
			},
			didRequestLayoutSettings: { [weak self] in
				self?.presentLayoutSettings()
			}
		)
	}()

	private lazy var previousGamepadLayerView: GamepadLayerView = {
		let view = GamepadLayerView()
		view.isUserInteractionEnabled = false
		return view
	}()

	private lazy var nextGamepadLayerView: GamepadLayerView = {
		let view = GamepadLayerView()
		view.isUserInteractionEnabled = false
		return view
	}()

	private lazy var hiddenInputField: UITextField = { [weak self] in
		guard let self else { fatalError() }
		return HiddenInputField(
			pushKey: { [weak self] key in
				self?.keyInteraction(key, true)
			},
			releaseKey: { [weak self] key in
				self?.keyInteraction(key, false)
			},
			didTapPreferencesButton: { [weak self] in
				self?.presentPreferences()
			},
			hiddenInputFieldDelegate: hiddenInputFieldDelegate
		)
	}()

	private lazy var informationView: InformationView = {
		let view = InformationView.withoutConstraints()
		view.isHidden = true
		view.alpha = 0
		view.isUserInteractionEnabled = false
		return view
	}()

	private lazy var fpsLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.textColor = .white
		label.isUserInteractionEnabled = false
		return label
	}()

	private let hiddenInputFieldDelegate = HiddenInputFieldDelegate()

	private let keyInteraction: ((Int, Bool) -> Void)
	private let specialButtonInteraction: ((SpecialButton, Bool) -> Void)

	private var gamepadConfig = GamepadManager.shared.config
	private var upcomingGamepadConfig: GamepadConfig?
	private var gamepadSettingsName: String {
		upcomingGamepadConfig?.name ?? gamepadConfig.name
	}

	private var fpsCounter: FPSCounter?

	private init(
		keyInteraction: @escaping ((Int, Bool) -> Void),
		specialButtonInteraction: @escaping ((SpecialButton, Bool) -> Void)
	) {
		self.keyInteraction = keyInteraction
		self.specialButtonInteraction = specialButtonInteraction

		super.init(nibName: nil, bundle: nil)

		NotificationCenter.default.addObserver(self, selector: #selector(updateFpsCounter), name: MiscellaneousNotifications.fpsCounterSettingChanged, object: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	public override func viewDidLoad() {
		super.viewDidLoad()

		view.addSubview(gestureInputView)
		gestureInputView.addSubview(gamepadLayerView)
		gestureInputView.addSubview(previousGamepadLayerView)
		gestureInputView.addSubview(nextGamepadLayerView)

		gestureInputView.addSubview(hiddenInputField)

		view.addSubview(informationView)

		view.addSubview(fpsLabel)

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

			fpsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
			fpsLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
		])

		hiddenInputFieldDelegate.didInputSDLKey = { [weak self] output in
			guard let self else { return }
			self.handle(hiddenInputFieldOutput: output)
		}

		setupGestureInputView()

		if state != .normal {
			transition(to: state)
		}

		loadGamepadSettings()

		updateFpsCounter()

//		becomeFirstResponder()
	}

//	public override var canBecomeFirstResponder: Bool {
//		get {
//			return true
//		}
//	}
//
//	public override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
//		if motion == .motionShake {
//			transition(to: .editingGamepad)
//		}
//	}

	public override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		if state != .showingGamepad {
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
		}

		if state == .normal {
			flashInformation(for: .normal, atBottom: true)
		}
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
			sdlViewVerticalOffset = .zero
			offsetSDLViewVertically(sdlViewVerticalOffset)
			hiddenInputField.resignFirstResponder()
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			previousGamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			nextGamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			gestureInputView.set(state: state)
		case .showingGamepad:
			gamepadLayerView.transform = .identity
			previousGamepadLayerView.transform = .identity
			nextGamepadLayerView.transform = .identity
			gamepadLayerView.set(isEditing: false)
			gestureInputView.set(state: state)
		case .showingKeyboard:
			hiddenInputField.becomeFirstResponder()
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			previousGamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			nextGamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			gestureInputView.set(state: state)
		case .editingGamepad:
			gamepadLayerView.transform = .identity
			previousGamepadLayerView.transform = .identity
			nextGamepadLayerView.transform = .identity
			gamepadLayerView.set(isEditing: true)
			gestureInputView.set(state: state)
		}
	}

	private func setupGestureInputView() {
		gestureInputView.reportThreeFingerDragProgress = { [weak self] delta in
			guard let self else { return }

			threeFingerGestureDragDelta += delta
			threeFingerGestureDragDeltaSinceLatestHapticFeedback += delta

			if threeFingerGestureDragDeltaSinceLatestHapticFeedback.abs > 60 {
				triggerDragHapticFeedback()
			}

			switch state {
			case .normal:
				let x = threeFingerGestureDragDelta.dx
				let y = threeFingerGestureDragDelta.dy - self.view.frame.size.height
				gamepadLayerView.transform = .init(translationX: x, y: y)
			case .showingGamepad:
				let x = threeFingerGestureDragDelta.dx
				let y = threeFingerGestureDragDelta.dy
				gamepadLayerView.transform = .init(translationX: x, y: y)
				previousGamepadLayerView.transform = .init(translationX: x, y: y)
				nextGamepadLayerView.transform = .init(translationX: x, y: y)
			case .editingGamepad:
				let x = threeFingerGestureDragDelta.dx
				let y = threeFingerGestureDragDelta.dy
				gamepadLayerView.transform = .init(translationX: x, y: y)
			default:
				break
			}
		}

		gestureInputView.didBeginThreeFingerGesture = {
			UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
		}

		gestureInputView.didReleaseThreeFingerGesture = { [weak self] in
			guard let self else { return }

			let threshold = view.frame.height / 6

			var willTranslateInLongAxis = false
			if self.state == .showingGamepad {
				let absDx = abs(self.threeFingerGestureDragDelta.dx)
				let absDy = abs(self.threeFingerGestureDragDelta.dy)
				willTranslateInLongAxis = UIScreen.isPortraitMode ? absDx < absDy : absDx > absDy
			}

			let resultingState: OverlayState
			switch self.state {
			case .normal:
				if self.threeFingerGestureDragDelta.dy > threshold {
					resultingState = .showingGamepad
				} else if self.threeFingerGestureDragDelta.dy < -threshold {
					resultingState = .showingKeyboard
				} else {
					resultingState = .normal
				}
			case .showingGamepad:
				if abs(self.threeFingerGestureDragDelta.dy) > abs(self.threeFingerGestureDragDelta.dx) {
					if self.threeFingerGestureDragDelta.dy > threshold {
						resultingState = .editingGamepad
					} else if self.threeFingerGestureDragDelta.dy < -threshold {
						resultingState = .normal
					} else {
						resultingState = .showingGamepad
					}
				} else {
					if self.threeFingerGestureDragDelta.dx > threshold {
						self.upcomingGamepadConfig = GamepadManager.shared.previousConfig
					} else if self.threeFingerGestureDragDelta.dx < -threshold {
						self.upcomingGamepadConfig = GamepadManager.shared.nextConfig
					}
					resultingState = .showingGamepad
				}
			case .showingKeyboard:
				if self.threeFingerGestureDragDelta.dy > threshold {
					resultingState = .normal
				} else {
					resultingState = .showingKeyboard
				}
			case .editingGamepad:
				if self.threeFingerGestureDragDelta.dy < -threshold {
					resultingState = .showingGamepad
				} else {
					resultingState = .editingGamepad
				}
			}

			flashInformation(for: resultingState)

			UIView.animate(
				withDuration: willTranslateInLongAxis ? 0.6 : 0.28,
				delay: 0.0,
				usingSpringWithDamping: 0.6,
				initialSpringVelocity: 1.5,
				animations: {
					switch self.state {
					case .showingGamepad:
						if abs(self.threeFingerGestureDragDelta.dy) <= abs(self.threeFingerGestureDragDelta.dx) {
							if self.threeFingerGestureDragDelta.dx > threshold {
								self.transitToPreviousGamepadLayout()
							} else if self.threeFingerGestureDragDelta.dx < -threshold {
								self.transitToNextGamepadLayout()
							} else {
								self.transition(to: .showingGamepad)
							}
						} else {
							self.transition(to: resultingState)
						}
					default:
						self.transition(to: resultingState)
					}
				},
				completion: { [weak self] _ in
					guard let self else { return }
					if let upcomingGamepadConfig {
						upcomingGamepadConfig.saveAsCurrent()
						gamepadConfig = upcomingGamepadConfig
						self.upcomingGamepadConfig = nil
						loadGamepadSettings()
						transition(to: .showingGamepad)
					}
				}
			)

			threeFingerGestureDragDelta = .zero

		}

		gestureInputView.reportTwoFingerDragProgress = { [weak self] delta in
			guard let self else { return }

			sdlViewVerticalOffset += delta
			twoFingerGestureDragDeltaSinceLatestHapticFeedback += delta

			if abs(twoFingerGestureDragDeltaSinceLatestHapticFeedback) > 60 {
				triggerDragHapticFeedback()
			}

			offsetSDLViewVertically(sdlViewVerticalOffset)
		}
	}

	func transitToNextGamepadLayout() {
		gamepadLayerView.transform = .init(translationX: -view.frame.size.width, y: 0)
		previousGamepadLayerView.transform = .init(translationX: -view.frame.size.width, y: 0)
		nextGamepadLayerView.transform = .init(translationX: -view.frame.size.width, y: 0)
	}

	func transitToPreviousGamepadLayout() {
		gamepadLayerView.transform = .init(translationX: view.frame.size.width, y: 0)
		previousGamepadLayerView.transform = .init(translationX: view.frame.size.width, y: 0)
		nextGamepadLayerView.transform = .init(translationX: view.frame.size.width, y: 0)
	}

	private func handle(hiddenInputFieldOutput: HiddenInputFieldOutput) {
		if hiddenInputFieldOutput.withShift {
			self.keyInteraction(SDLKey.shift.enValue, true)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
				guard let self else { return }
				self.keyInteraction(hiddenInputFieldOutput.value, true)
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
				guard let self else { return }
				self.keyInteraction(SDLKey.shift.enValue, false)
				self.keyInteraction(hiddenInputFieldOutput.value, false)
			}
		} else {
			self.keyInteraction(hiddenInputFieldOutput.value, true)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
				guard let self else { return }
				self.keyInteraction(hiddenInputFieldOutput.value, false)
			}
		}
	}

	private func triggerDragHapticFeedback() {
		if MiscellaneousSettings.current.gestureHapticFeedback {
			dragHapticFeedbackGenerator.impactOccurred()
		}
		twoFingerGestureDragDeltaSinceLatestHapticFeedback = .zero
		threeFingerGestureDragDeltaSinceLatestHapticFeedback = .zero
	}

	private func flashInformation(
		for state: OverlayState,
		atBottom: Bool = false
	) {
		if MiscellaneousSettings.current.showHints {
			switch state {
			case .normal:
				informationView.show(hint: "Three finger swipe ↓ for Gamepad mode, ↑ for Keyboard mode", atBottom: atBottom)
			case .showingGamepad:
				informationView.show(
					title: gamepadSettingsName,
					hint: "Three finger swipe ↓ to edit, ← or → to switch layout, ↑ to dismiss",
					atBottom: atBottom
				)
			case .editingGamepad:
				informationView.show(
					title: "Editing \(gamepadSettingsName)",
					hint: "Three finger swipe ↑ to exit edit mode", atBottom: atBottom
				)
			case .showingKeyboard:
				informationView.show(hint: "Two finger swipe ↑ or ↓ to scroll screen\nThree finger swipe ↓ to dismiss", atBottom: atBottom)
			}
		} else if state == .showingGamepad {
			informationView.show(
				title: gamepadSettingsName,
				atBottom: atBottom
			)
		}
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
			dismissRequestCallback: { [weak self] vc, result in
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
					}
				case .unassign:
					gamepadConfig.removeAssignment(at: position)
				default:
					break
				}

				gamepadLayerView.load(config: gamepadConfig)
			}
		)

		vc.willMove(toParent: self)

		addChild(vc)
		view.addSubview(vc.view)

		NSLayoutConstraint.activate([
			vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			vc.view.topAnchor.constraint(equalTo: view.topAnchor),
			vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])

		vc.didMove(toParent: self)

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

	private func offsetSDLViewVertically(_ offset: CGFloat) {
		let sdlView = self.view.superview!

		let screenHeight = UIScreen.main.bounds.height
		let y: CGFloat
		if offset > 0 {
			y = 0
		} else if offset < -screenHeight/2 {
			y = -screenHeight/2
		} else {
			y = offset
		}

		let transform = CGAffineTransform(translationX: 0, y: y)
		sdlView.transform = transform
		self.view.transform = transform.inverted()
	}

	@objc
	private func updateFpsCounter() {
		if MiscellaneousSettings.current.fpsCounterEnabled {
			let fpsCounter = FPSCounter()
			fpsCounter.delegate = self
			self.fpsCounter = fpsCounter
			fpsLabel.isHidden = false
		} else {
			self.fpsCounter = nil
			fpsLabel.isHidden = true
		}
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
	public static func injectOverlayViewController(
		keyInteraction: @escaping ((Int, Bool) -> Void),
		specialButtonInteraction: @escaping ((SpecialButton, Bool) -> Void)
	) {
		guard let window = UIApplication.shared.delegate?.window,
		let sdlVC = window?.rootViewController else {
			return
		}

		guard !sdlVC.children.contains(where: { $0 is OverlayViewController }) else {
			return
		}

		let vc = OverlayViewController(
			keyInteraction: keyInteraction,
			specialButtonInteraction: specialButtonInteraction
		)

		vc.willMove(toParent: sdlVC)
		sdlVC.view.addSubview(vc.view)

		NSLayoutConstraint.activate([
			vc.view.leadingAnchor.constraint(equalTo: sdlVC.view.leadingAnchor),
			vc.view.trailingAnchor.constraint(equalTo: sdlVC.view.trailingAnchor),
			vc.view.topAnchor.constraint(equalTo: sdlVC.view.topAnchor),
			vc.view.bottomAnchor.constraint(equalTo: sdlVC.view.bottomAnchor)
		])

		sdlVC.addChild(vc)
		vc.didMove(toParent: sdlVC)
	}
}

extension OverlayViewController: @preconcurrency FPSCounterDelegate {

	func fpsCounter(_ counter: FPSCounter, didUpdateFramesPerSecond fps: Int) {
		fpsLabel.text = "\(fps)"
	}
}
