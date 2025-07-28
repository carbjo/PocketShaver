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
	private var gestureDragYDelta: CGFloat = 0
	private var gestureDragYDeltaSinceLatestHapticFeedback: CGFloat = 0
	private var gestureDragHapticFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

	private lazy var gamepadLayerView: GamepadLayerView = {
		GamepadLayerView(pushKey: pushKey, releaseKey: releaseKey) { [weak self] position in
			guard let self else { return }
			presentAlertForEditingButtonMapping(at: position)
		}
	}()

	private lazy var hiddenInputField: UITextField = { [weak self] in
		guard let self else { fatalError() }
		return HiddenInputField(
			pushKey: pushKey,
			releaseKey: releaseKey,
			hiddenInputFieldDelegate: hiddenInputFieldDelegate
		)
	}()

	private let hiddenInputFieldDelegate = HiddenInputFieldDelegate()

	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)
	private let pushAndReleaseKey: ((Int) -> Void)

	private var gamepadConfig = GamepadConfig.current

	private init(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void),
		pushAndReleaseKey: @escaping ((Int) -> Void)
	) {
		self.pushKey = pushKey
		self.releaseKey = releaseKey
		self.pushAndReleaseKey = pushAndReleaseKey

		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	public override func viewDidLoad() {
		super.viewDidLoad()

		view.addSubview(gestureInputView)
		gestureInputView.addSubview(gamepadLayerView)

		gestureInputView.addSubview(hiddenInputField)

		NSLayoutConstraint.activate([
			gestureInputView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			gestureInputView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			gestureInputView.topAnchor.constraint(equalTo: view.topAnchor),
			gestureInputView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

			gamepadLayerView.leadingAnchor.constraint(equalTo: gestureInputView.leadingAnchor),
			gamepadLayerView.trailingAnchor.constraint(equalTo: gestureInputView.trailingAnchor),
			gamepadLayerView.topAnchor.constraint(equalTo: gestureInputView.topAnchor),
			gamepadLayerView.bottomAnchor.constraint(equalTo: gestureInputView.bottomAnchor),

			hiddenInputField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			hiddenInputField.bottomAnchor.constraint(equalTo: view.topAnchor)
		])

		hiddenInputFieldDelegate.didInputSDLKey = { [weak self] output in
			guard let self else { return }
			self.handle(hiddenInputFieldOutput: output)
		}

		setupGestureInputView()

		if state != .normal {
			transition(to: state)
		}

		gamepadLayerView.load(config: gamepadConfig)
	}

	public override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		if state != .showingGamepad {
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
		}
	}

	private func transition(to state: State) {
		self.state = state
		switch state {
		case .normal:
			hiddenInputField.resignFirstResponder()
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
		case .showingGamepad:
			gamepadLayerView.transform = .identity
			gamepadLayerView.set(isEditing: false)
		case .showingKeyboard:
			hiddenInputField.becomeFirstResponder()
			gamepadLayerView.transform = .init(translationX: 0, y: -view.frame.size.height)
		case .editingGamepad:
			gamepadLayerView.set(isEditing: true)
			gamepadLayerView.transform = .identity
		}
	}

	private func setupGestureInputView() {
		gestureInputView.reportDragProgress = { [weak self] deltaY in
			guard let self else { return }

			gestureDragYDelta += deltaY
			gestureDragYDeltaSinceLatestHapticFeedback += deltaY

			if abs(gestureDragYDeltaSinceLatestHapticFeedback) > 60 {
				triggerGamepadLayerViewTranslationHapticFeedback()
			}

			switch state {
			case .normal:
				let y = gestureDragYDelta - self.view.frame.size.height
				gamepadLayerView.transform = .init(translationX: 0, y: y)
			case .showingGamepad, .editingGamepad:
				let y = gestureDragYDelta
				gamepadLayerView.transform = .init(translationX: 0, y: y)
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

			UIView.animate(
				withDuration: 0.28,
				delay: 0.0,
				usingSpringWithDamping: 0.6,
				initialSpringVelocity: 1.5,
				animations: {
					switch self.state {
					case .normal:
						if self.gestureDragYDelta > threshold {
							self.transition(to: .showingGamepad)
						} else if self.gestureDragYDelta < -threshold {
							self.transition(to: .showingKeyboard)
						} else {
							self.transition(to: .normal)
						}
					case .showingGamepad:
						if self.gestureDragYDelta > threshold {
							self.transition(to: .editingGamepad)
						} else if self.gestureDragYDelta < -threshold {
							self.transition(to: .normal)
						} else {
							self.transition(to: .showingGamepad)
						}
					case .showingKeyboard:
						if self.gestureDragYDelta > threshold {
							self.transition(to: .normal)
						} else {
							self.transition(to: .showingKeyboard)
						}
					case .editingGamepad:
						if self.gestureDragYDelta < -threshold {
							self.transition(to: .showingGamepad)
						} else {
							self.transition(to: .editingGamepad)
						}
					}
				}
			)

			gestureDragYDelta = 0
		}
	}

	private func handle(hiddenInputFieldOutput: HiddenInputFieldOutput) {
		if hiddenInputFieldOutput.withShift {
			pushKey(SDLKey.shift.enValue)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
				guard let self else { return }
				self.pushKey(hiddenInputFieldOutput.value)
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
				guard let self else { return }
				self.releaseKey(SDLKey.shift.enValue)
				self.releaseKey(hiddenInputFieldOutput.value)
			}
		} else {
			pushKey(hiddenInputFieldOutput.value)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
				guard let self else { return }
				self.releaseKey(hiddenInputFieldOutput.value)
			}
		}
	}

	private func triggerGamepadLayerViewTranslationHapticFeedback() {
		gestureDragHapticFeedbackGenerator.impactOccurred()
		gestureDragYDeltaSinceLatestHapticFeedback = 0
	}

	private func presentAlertForEditingButtonMapping(at position: GamepadButtonPosition) {
		guard !gestureInputView.isDragging else {
			return
		}
		
		let alertVC = UIAlertController(title: "Assign", message: nil, preferredStyle: .alert)
		alertVC.addTextField()
		alertVC.addAction(.init(title: "Cancel", style: .cancel))
		alertVC.addAction(.init(title: "OK", style: .default, handler: { [weak self] _ in
			guard let self,
			let text = alertVC.textFields?[0].text else {
				return
			}

			if text.isEmpty {
				gamepadConfig = gamepadConfig.removingAssignment(at: position)
			} else {
				guard let key = SDLKey(rawValue: text) else {
					print("-- could not map \(text)")
					return
				}

				gamepadConfig = gamepadConfig.replacing(key: key, at: position)
			}

			gamepadLayerView.load(config: gamepadConfig)
			gamepadConfig.saveAsCurrent()
		}))

		present(alertVC, animated: true)
	}
}

extension OverlayViewController {
	@objc
	public static func injectOverlayViewController(
		pushKey: @escaping ((Int) -> Void),
		releaseKey: @escaping ((Int) -> Void),
		pushAndReleaseKey: @escaping ((Int) -> Void)
	) {
		guard let window = UIApplication.shared.delegate?.window,
		let sdlVC = window?.rootViewController else {
			return
		}

		let vc = OverlayViewController(
			pushKey: pushKey,
			releaseKey: releaseKey,
			pushAndReleaseKey: pushAndReleaseKey
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
