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

	private let overlayView = OverlayView.withoutConstraints()
	private var overlayDragYDelta: CGFloat = 0
	private var overlayDragYDeltaSinceLatestHapticFeedback: CGFloat = 0
	private var overlayDragHapticFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

	private lazy var gamepadLayerView: GamepadLayerView = {
		let view = GamepadLayerView(pushKey: self.pushKey, releaseKey: self.releaseKey)
		view.translatesAutoresizingMaskIntoConstraints = false
		return view
	}()

	private lazy var hiddenInputField: UITextField = { [weak self] in
		guard let self else { fatalError() }
		let field = UITextField.withoutConstraints()
		field.autocapitalizationType = .none
		field.text = " "
		field.autocorrectionType = .no
		field.spellCheckingType = .no
		field.delegate = self.hiddenInputFieldDelegate
		let accessoryView = HiddenInputFieldKeyboardAccessoryView.withoutConstraints()
		accessoryView.configure(pushKey: pushKey, releaseKey: releaseKey)
		field.inputAccessoryView = accessoryView
		return field
	}()

	private let hiddenInputFieldDelegate = HiddenInputFieldDelegate()

	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)
	private let pushAndReleaseKey: ((Int) -> Void)

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

		view.addSubview(overlayView)
		view.addSubview(gamepadLayerView)

		overlayView.addSubview(hiddenInputField)

		NSLayoutConstraint.activate([
			overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			overlayView.topAnchor.constraint(equalTo: view.topAnchor),
			overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

			gamepadLayerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			gamepadLayerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			gamepadLayerView.topAnchor.constraint(equalTo: view.topAnchor),
			gamepadLayerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

			hiddenInputField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			hiddenInputField.bottomAnchor.constraint(equalTo: view.topAnchor)
		])

		hiddenInputFieldDelegate.didInputSDLKey = { [weak self] output in
			guard let self else { return }
			self.handle(hiddenInputFieldOutput: output)
		}

		setupOverlayView()

		if state != .normal {
			transition(to: state)
		}
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
			self.gamepadLayerView.transform = .identity
		case .showingKeyboard:
			hiddenInputField.becomeFirstResponder()
		}
	}

	private func setupOverlayView() {
		overlayView.reportDragProgress = { [weak self] deltaY in
			guard let self else { return }

			overlayDragYDelta += deltaY
			overlayDragYDeltaSinceLatestHapticFeedback += deltaY

			if abs(overlayDragYDeltaSinceLatestHapticFeedback) > 60 {
				triggerGamepadLayerViewTranslationHapticFeedback()
			}

			if state != .showingKeyboard {

				var y = overlayDragYDelta
				if state == .normal {
					y -= self.view.frame.size.height
				}

				gamepadLayerView.transform = .init(translationX: 0, y: y)
			}
		}

		overlayView.didBeginGesture = {
			UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
		}

		overlayView.didReleaseGesture = { [weak self] in
			guard let self else { return }

			let threshold = view.frame.height / 3

			UIView.animate(
				withDuration: 0.28,
				delay: 0.0,
				usingSpringWithDamping: 0.6,
				initialSpringVelocity: 1.5,
				animations: {
					switch self.state {
					case .normal:
						if self.overlayDragYDelta > threshold {
							self.transition(to: .showingGamepad)
						} else if self.overlayDragYDelta < -threshold {
							self.transition(to: .showingKeyboard)
						} else {
							self.transition(to: .normal)
						}
					case .showingGamepad:
						if self.overlayDragYDelta < -threshold {
							self.transition(to: .normal)
						} else {
							self.transition(to: .showingGamepad)
						}
					case .showingKeyboard:
						if self.overlayDragYDelta > threshold / 2 {
							self.transition(to: .normal)
						} else {
							self.transition(to: .showingKeyboard)
						}
					}
				}
			)

			overlayDragYDelta = 0
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
		overlayDragHapticFeedbackGenerator.impactOccurred()
		overlayDragYDeltaSinceLatestHapticFeedback = 0
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
