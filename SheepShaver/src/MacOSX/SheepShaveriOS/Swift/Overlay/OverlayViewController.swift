//
//  OverlayViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

import UIKit

@MainActor fileprivate var globalState: OverlayViewController.State = .normal

@objc(OverlayViewController)
public class OverlayViewController: UIViewController {

	enum State {
		case normal
		case showingKeyboard
		case showingGamepad
	}

	private lazy var overlayView: UIView = {
		UIView.withoutConstraints()
	}()

	private lazy var gamepadLayerView: ButtonLayerView = {
		let view = ButtonLayerView(pushKey: self.pushKey, releaseKey: self.releaseKey)
		view.translatesAutoresizingMaskIntoConstraints = false
		view.isHidden = true
		return view
	}()

	private lazy var overlaySwipeDownGestureRecognizer: UISwipeGestureRecognizer = { [weak self] in
		guard let self else { fatalError() }
		let gesture = UISwipeGestureRecognizer()
		gesture.direction = .down
		gesture.numberOfTouchesRequired = 3
		gesture.delaysTouchesBegan = false
		gesture.delaysTouchesEnded = false
		gesture.addTarget(self, action: #selector(overlaySwipeDown))
		gesture.delegate = self

		return gesture
	}()

	private lazy var overlaySwipeUpGestureRecognizer: UISwipeGestureRecognizer = { [weak self] in
		guard let self else { fatalError() }
		let gesture = UISwipeGestureRecognizer()
		gesture.direction = .up
		gesture.numberOfTouchesRequired = 3
		gesture.delaysTouchesBegan = false
		gesture.delaysTouchesEnded = false
		gesture.addTarget(self, action: #selector(overlaySwipeUp))
		gesture.delegate = self

		return gesture
	}()

	private lazy var gamepadSwipeUpGestureRecognizer: UISwipeGestureRecognizer = { [weak self] in
		guard let self else { fatalError() }
		let gesture = UISwipeGestureRecognizer()
		gesture.direction = .up
		gesture.numberOfTouchesRequired = 3
		gesture.delaysTouchesBegan = false
		gesture.delaysTouchesEnded = false
		gesture.addTarget(self, action: #selector(gamepadSwipeUp))
		gesture.delegate = self

		return gesture
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

	private lazy var hiddenInputFieldDelegate: HiddenInputFieldDelegate = {
		HiddenInputFieldDelegate()
	}()

	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)
	private let pushAndReleaseKey: ((Int) -> Void)

	init(
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

	private var pushedKeys = Set<Int>()

	public override func viewDidLoad() {
		super.viewDidLoad()

		view.addSubview(overlayView)
		view.addSubview(gamepadLayerView)

		NSLayoutConstraint.activate([
			overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			overlayView.topAnchor.constraint(equalTo: view.topAnchor),
			overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

			gamepadLayerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			gamepadLayerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			gamepadLayerView.topAnchor.constraint(equalTo: view.topAnchor),
			gamepadLayerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])

		overlayView.addGestureRecognizer(overlaySwipeUpGestureRecognizer)
		overlayView.addGestureRecognizer(overlaySwipeDownGestureRecognizer)
		gamepadLayerView.addGestureRecognizer(gamepadSwipeUpGestureRecognizer)

		overlayView.addSubview(hiddenInputField)
		hiddenInputFieldDelegate.didInputSDLKey = { [weak self] output in
			guard let self else { return }
			self.handle(hiddenInputFieldOutput: output)
		}

		NSLayoutConstraint.activate([
			hiddenInputField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			hiddenInputField.bottomAnchor.constraint(equalTo: view.topAnchor)
		])

		if globalState != .normal {
			transition(to: globalState)
		}
	}

	private func transition(to state: State) {
		globalState = state
		switch state {
		case .normal:
			gamepadLayerView.isHidden = true
			hiddenInputField.resignFirstResponder()
		case .showingGamepad:
			gamepadLayerView.isHidden = false
		case .showingKeyboard:
			hiddenInputField.becomeFirstResponder()
		}
	}

	@objc
	private func overlaySwipeDown() {
		switch globalState {
		case .normal:
			transition(to: .showingGamepad)
		case .showingKeyboard:
			transition(to: .normal)
		default: break
		}
	}

	@objc
	private func overlaySwipeUp() {
		switch globalState {
		case .normal:
			transition(to: .showingKeyboard)
		default: break
		}
	}

	@objc
	private func gamepadSwipeUp() {
		switch globalState {
		case .showingGamepad:
			transition(to: .normal)
		default: break
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

	@objc private func resignKeyboard() {
		hiddenInputField.resignFirstResponder()
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

extension OverlayViewController: UIGestureRecognizerDelegate {
	public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
		return true
	}
}
