//
//  OverlayViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

import UIKit

@objc
public class OverlayViewController: UIViewController {

	private enum State {
		case normal
		case showingKeyboard
		case showingGamepad
		case editingGamepad
	}

	@MainActor private static var globalState: State = .normal

	private var state: State {
		get {
			Self.globalState
		}
		set {
			Self.globalState = newValue
		}
	}

	private let gestureInputView = GestureInputView.withoutConstraints()
	private var gestureDragDelta: CGVector = .zero
	private var gestureDragDeltaSinceLatestHapticFeedback: CGVector = .zero
	private var gestureDragHapticFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

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
			hiddenInputFieldDelegate: hiddenInputFieldDelegate
		)
	}()

	private lazy var informationView: InformationView = {
		let view = InformationView.withoutConstraints()
		view.isHidden = true
		view.alpha = 0
		view.set(text: gamepadSettings.config.name)
		return view
	}()

	private let hiddenInputFieldDelegate = HiddenInputFieldDelegate()

	private let keyInteraction: ((Int, Bool) -> Void)
	private let specialButtonInteraction: ((SpecialButton, Bool) -> Void)

	private var gamepadSettings = GamepadSettings.current
	private var upcomingGamepadSettings: GamepadSettings? {
		didSet {
			if let upcomingGamepadSettings {
				informationView.set(text: upcomingGamepadSettings.config.name)
			}
		}
	}

	private init(
		keyInteraction: @escaping ((Int, Bool) -> Void),
		specialButtonInteraction: @escaping ((SpecialButton, Bool) -> Void)
	) {
		self.keyInteraction = keyInteraction
		self.specialButtonInteraction = specialButtonInteraction

		super.init(nibName: nil, bundle: nil)
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
			informationView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -UIScreen.main.bounds.size.height / 4)
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
	}

	public override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		if state != .showingGamepad {
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
		}
	}

	private func loadGamepadSettings() {
		gamepadLayerView.load(config: gamepadSettings.config)
		previousGamepadLayerView.load(config: gamepadSettings.previoius.config)
		nextGamepadLayerView.load(config: gamepadSettings.next.config)
	}

	private func transition(to state: State) {
		self.state = state
		switch state {
		case .normal:
			hiddenInputField.resignFirstResponder()
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			previousGamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			nextGamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
		case .showingGamepad:
			gamepadLayerView.transform = .identity
			previousGamepadLayerView.transform = .identity
			nextGamepadLayerView.transform = .identity
			gamepadLayerView.set(isEditing: false)
			gestureInputView.set(isEditing: false)
		case .showingKeyboard:
			hiddenInputField.becomeFirstResponder()
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			previousGamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
			nextGamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
		case .editingGamepad:
			gamepadLayerView.transform = .identity
			previousGamepadLayerView.transform = .identity
			nextGamepadLayerView.transform = .identity
			gamepadLayerView.set(isEditing: true)
			gestureInputView.set(isEditing: true)
		}
	}

	private func setupGestureInputView() {
		gestureInputView.reportDragProgress = { [weak self] delta in
			guard let self else { return }

			gestureDragDelta += delta
			gestureDragDeltaSinceLatestHapticFeedback += delta

			if gestureDragDeltaSinceLatestHapticFeedback.abs > 60 {
				triggerGamepadLayerViewTranslationHapticFeedback()
			}

			switch state {
			case .normal:
				let x = gestureDragDelta.dx
				let y = gestureDragDelta.dy - self.view.frame.size.height
				gamepadLayerView.transform = .init(translationX: x, y: y)
			case .showingGamepad:
				let x = gestureDragDelta.dx
				let y = gestureDragDelta.dy
				gamepadLayerView.transform = .init(translationX: x, y: y)
				previousGamepadLayerView.transform = .init(translationX: x, y: y)
				nextGamepadLayerView.transform = .init(translationX: x, y: y)
			case .editingGamepad:
				let x = gestureDragDelta.dx
				let y = gestureDragDelta.dy
				gamepadLayerView.transform = .init(translationX: x, y: y)
			default:
				break
			}
		}

		gestureInputView.didBeginGesture = {
			UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
		}

		gestureInputView.didReleaseGesture = { [weak self] in
			guard let self else { return }

			let threshold = view.frame.height / 6

			var willTranslateInLongAxis = false
			if self.state == .showingGamepad {
				let absDx = abs(self.gestureDragDelta.dx)
				let absDy = abs(self.gestureDragDelta.dy)
				willTranslateInLongAxis = UIScreen.isPortraitMode ? absDx < absDy : absDx > absDy
			}

			UIView.animate(
				withDuration: willTranslateInLongAxis ? 0.6 : 0.28,
				delay: 0.0,
				usingSpringWithDamping: 0.6,
				initialSpringVelocity: 1.5,
				animations: {
					switch self.state {
					case .normal:
						if self.gestureDragDelta.dy > threshold {
							self.transition(to: .showingGamepad)
						} else if self.gestureDragDelta.dy < -threshold {
							self.transition(to: .showingKeyboard)
						} else {
							self.transition(to: .normal)
						}
					case .showingGamepad:
						if abs(self.gestureDragDelta.dy) > abs(self.gestureDragDelta.dx) {
							if self.gestureDragDelta.dy > threshold {
								self.transition(to: .editingGamepad)
							} else if self.gestureDragDelta.dy < -threshold {
								self.transition(to: .normal)
							} else {
								self.transition(to: .showingGamepad)
							}
						} else {
							if self.gestureDragDelta.dx > threshold {
								self.transitToPreviousGamepadLayout()
							} else if self.gestureDragDelta.dx < -threshold {
								self.transitToNextGamepadLayout()
							} else {
								self.transition(to: .showingGamepad)
							}
						}
					case .showingKeyboard:
						if self.gestureDragDelta.dy > threshold {
							self.transition(to: .normal)
						} else {
							self.transition(to: .showingKeyboard)
						}
					case .editingGamepad:
						if self.gestureDragDelta.dy < -threshold {
							self.transition(to: .showingGamepad)
						} else {
							self.transition(to: .editingGamepad)
						}
					}

					if self.state == .showingGamepad {
						self.flashInformationLabel()
					}
				},
				completion: { _ in
					if let upcomingGamepadSettings = self.upcomingGamepadSettings {
						upcomingGamepadSettings.saveAsCurrent()
						self.gamepadSettings = upcomingGamepadSettings
						self.upcomingGamepadSettings = nil
						self.loadGamepadSettings()
						self.transition(to: .showingGamepad)
					}
				}
			)

			gestureDragDelta = .zero

		}
	}

	func flashInformationLabel() {
		informationView.alpha = 0
		informationView.isHidden = false

		UIView.animate(withDuration: 0.6, animations: {
			self.informationView.alpha = 1
		}) { _ in
			UIView.animate(withDuration: 0.6, delay: 0.15, animations: {
				self.informationView.alpha = 0
			}) { _ in
				self.informationView.isHidden = false
			}
		}
	}

	func transitToNextGamepadLayout() {
		upcomingGamepadSettings = gamepadSettings.next
		gamepadLayerView.transform = .init(translationX: -view.frame.size.width, y: 0)
		previousGamepadLayerView.transform = .init(translationX: -view.frame.size.width, y: 0)
		nextGamepadLayerView.transform = .init(translationX: -view.frame.size.width, y: 0)
	}

	func transitToPreviousGamepadLayout() {
		upcomingGamepadSettings = gamepadSettings.previoius
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

	private func triggerGamepadLayerViewTranslationHapticFeedback() {
		gestureDragHapticFeedbackGenerator.impactOccurred()
		gestureDragDeltaSinceLatestHapticFeedback = .zero
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

				var gamepadConfig = gamepadSettings.config

				switch result {
				case .assignment(let assignment):
					switch assignment {
					case .specialButton(let specialButton):
						gamepadConfig = gamepadConfig.replacing(with: specialButton, at: position)
					case .key(let key):
						gamepadConfig = gamepadConfig.replacing(with: key, at: position)
					}
				case .unassign:
					gamepadConfig = gamepadConfig.removingAssignment(at: position)
				default:
					break
				}

				gamepadLayerView.load(config: gamepadConfig)
				gamepadSettings = gamepadSettings.replaceCurrentConfig(with: gamepadConfig)
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
		alertVC.addTextField()
		alertVC.addAction(.init(title: "Cancel", style: .cancel))
		alertVC.addAction(.init(title: "OK", style: .default, handler: { [weak self] _ in
			guard let self,
				  let text = alertVC.textFields?[0].text,
			!text.isEmpty else {
				return
			}

			var gamepadConfig = gamepadSettings.config

			gamepadConfig = gamepadConfig.renaming(text)

			gamepadLayerView.load(config: gamepadConfig)
			gamepadSettings = gamepadSettings.replaceCurrentConfig(with: gamepadConfig)

			informationView.set(text: text)
		}))

		present(alertVC, animated: true)
	}
}

extension OverlayViewController {
	@objc
	public static func injectOverlayViewController(
		keyInteraction: @escaping ((Int, Bool) -> Void),
		specialButtonInteraction: @escaping ((SpecialButton, Bool) -> Void)
	) {
		guard let window = UIApplication.shared.delegate?.window,
		let sdlVC = window?.rootViewController else {
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
