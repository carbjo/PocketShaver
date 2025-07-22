//
//  OverlayViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

import UIKit


@objc(OverlayViewController)
public class OverlayViewController: UIViewController {

	enum State {
		case normal
		case showingKeyboard
		case showingGamepad
	}

	private lazy var overlayView: OverlayView = {
		OverlayView.withoutConstraints()
	}()

	private lazy var leftStack: UIStackView = {
		let stack = UIStackView.withoutConstraints()
		stack.axis = .horizontal
		stack.spacing = 4
		return stack
	}()

	private lazy var rightStack: UIStackView = {
		let stack = UIStackView.withoutConstraints()
		stack.axis = .horizontal
		stack.spacing = 4
		return stack
	}()

	private lazy var gamepadLayerView: UIView = {
		let view = UIView.withoutConstraints()
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
		let delegate = HiddenInputFieldDelegate { [weak self] output in
			guard let self else { return }
			self.handle(hiddenInputFieldOutput: output)
		}
		return delegate
	}()

	private var testKeyboardLabel: UILabel!

	private let pushKey: ((Int) -> Void)
	private let releaseKey: ((Int) -> Void)
	private let pushAndReleaseKey: ((Int) -> Void)

	private var state: State = .normal

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
			testPushed: pushKey,
			testReleased: releaseKey,
			testRaw: pushAndReleaseKey
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

	init(
		testPushed: @escaping ((Int) -> Void),
		testReleased: @escaping ((Int) -> Void),
		testRaw: @escaping ((Int) -> Void)
	) {
		self.pushKey = testPushed
		self.releaseKey = testReleased
		self.pushAndReleaseKey = testRaw

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

		NSLayoutConstraint.activate([
			hiddenInputField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			hiddenInputField.bottomAnchor.constraint(equalTo: view.topAnchor)
		])


//		leftStack.addArrangedSubview(createButton(for: .ctrl))
//		leftStack.addArrangedSubview(createButton(for: .up))
//		leftStack.addArrangedSubview(createButton(for: .space))
//		leftStack.addArrangedSubview(createButton(for: .escape))
//		leftStack.addArrangedSubview(cmdQButton)
//		leftStack.addArrangedSubview(createButton(for: .up))
//		leftStack.addArrangedSubview(createButton(for: .shift))
//		leftStack.addArrangedSubview(createButton(for: .z))
		leftStack.addArrangedSubview(createButton(for: .down))
		leftStack.addArrangedSubview(createButton(for: .space))
		leftStack.addArrangedSubview(createButton(for: .up))

//		rightStack.addArrangedSubview(createButton(for: .minus))
//		rightStack.addArrangedSubview(createButton(for: .return))
//		rightStack.addArrangedSubview(createButton(for: .down))
		rightStack.addArrangedSubview(createButton(for: .ctrl))
		rightStack.addArrangedSubview(createButton(for: .alt))
		rightStack.addArrangedSubview(createButton(for: .tab))
		rightStack.addArrangedSubview(createButton(for: .left))
		rightStack.addArrangedSubview(createButton(for: .right))
//		rightStack.addArrangedSubview(createButton(for: .slash))

//		let testKeyboardButton = createButton()
//		testKeyboardButton.setTitle("Start", for: .normal)
//		testKeyboardButton.addTarget(self, action: #selector(testKeyboardButtonPushed), for: .touchUpInside)
//		leftStack.addArrangedSubview(testKeyboardButton)
////
//		rightStack.addArrangedSubview(createTestKeyboardView())

		gamepadLayerView.addSubview(leftStack)
		gamepadLayerView.addSubview(rightStack)

		NSLayoutConstraint.activate([
			leftStack.leadingAnchor.constraint(equalTo: gamepadLayerView.leadingAnchor, constant: 64),
			leftStack.bottomAnchor.constraint(equalTo: gamepadLayerView.safeAreaLayoutGuide.bottomAnchor),

			rightStack.trailingAnchor.constraint(equalTo: gamepadLayerView.trailingAnchor, constant: -64),
			rightStack.bottomAnchor.constraint(equalTo: gamepadLayerView.safeAreaLayoutGuide.bottomAnchor)
		])
	}

	private func createButton() -> UIButton {
		let button = UIButton.withoutConstraints()
//		button.backgroundColor = .gray.withAlphaComponent(0.3)
		button.configuration = buttonConfig()

		NSLayoutConstraint.activate([
			button.widthAnchor.constraint(equalToConstant: 80),
			button.heightAnchor.constraint(equalToConstant: 80)
		])

		return button
	}

	private func createButton(for key: SDLKey) -> UIButton {
		let button = createButton()
		button.setTitle(key.label, for: .normal)
		button.addTarget(self, action: #selector(testButtonPushed), for: .touchDown)
		button.addTarget(self, action: #selector(testButtonReleased), for: .touchUpInside)
		button.addTarget(self, action: #selector(testButtonReleasedOutside), for: .touchUpOutside)
		button.tag = key.svValue

		return button
	}

	private func createTestKeyboardView() -> UIView {
		let view = UIView.withoutConstraints()
		view.backgroundColor = .gray.withAlphaComponent(0.3)

		let label = UILabel.withoutConstraints()
		label.textColor = .white

		view.addSubview(label)

		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: view.centerYAnchor),

			view.widthAnchor.constraint(equalToConstant: 80),
			view.heightAnchor.constraint(equalToConstant: 80)
		])

		testKeyboardLabel = label

		return view
	}

	@objc
	private func overlaySwipeDown() {
		switch state {
		case .normal:
			state = .showingGamepad
			gamepadLayerView.isHidden = false
		case .showingKeyboard:
			state = .normal
			hiddenInputField.resignFirstResponder()
		default: break
		}
	}

	@objc
	private func overlaySwipeUp() {
		switch state {
		case .normal:
			state = .showingKeyboard
			hiddenInputField.becomeFirstResponder()
		default: break
		}
	}

	@objc
	private func gamepadSwipeUp() {
		switch state {
		case .showingGamepad:
			state = .normal
			gamepadLayerView.isHidden = true
		default: break
		}
	}

	@objc func testButtonPushed(sender: UIButton) {
		let key = sender.tag
		guard !pushedKeys.contains(key) else {
			return
		}
		pushedKeys.insert(key)

		UIImpactFeedbackGenerator(style: .light).impactOccurred()

		print(String(format:"-- push %02X", key))
		pushKey(key)
	}

	@objc func testButtonReleased(sender: UIButton) {
		let key = sender.tag

		print(String(format:"-- release %02X", key))
		releaseKey(key)

		pushedKeys.remove(key)
	}

	@objc func testButtonReleasedOutside(sender: UIButton) {
		let key = sender.tag

		print(String(format:"-- release outside %02X", key))
		releaseKey(key)

		pushedKeys.remove(key)
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

	@objc
	private func testKeyboardButtonPushed() {
		Task { [weak self] in
			guard let self else { return }
			for i in 0..<0x7f {
				let hexString = String(format:"%02X", i)
				Task { @MainActor in
					self.testKeyboardLabel.text = hexString
				}
				pushAndReleaseKey(i)
				let mSec: UInt64 = 1000 * 1000
				try await Task.sleep(nanoseconds: 250 * mSec)
			}
		}
	}
}

extension OverlayViewController: UIGestureRecognizerDelegate {
	public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
		return true
	}
}

private class OverlayView: UIView {
//	private var isBlockActivated: Bool = false
//	private let overlayViewRecievedTwoFingerTap: (() -> Void)

	init() {
//		self.overlayViewRecievedTwoFingerTap = overlayViewRecievedTwoFingerTap

		super.init(frame: .zero)
	}
	
	required init?(coder: NSCoder) { fatalError() }

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
//		if !isBlockActivated {
			super.touchesBegan(touches, with: event)
//		}
	}

	func toggleBlockActivated() {
		print("-- did recieve gesture")
//		overlayViewRecievedTwoFingerTap()
//		if isBlockActivated {
//			print("block enabled")
//			isBlockActivated = false
//		} else {
//			print("block disabled")
//			isBlockActivated = true
//		}
	}
}

private class ButtonLayerView: UIView {
//	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
//	}
}

extension UIView {
	static func withoutConstraints() -> Self {
		let view = Self()
		view.translatesAutoresizingMaskIntoConstraints = false
		return view
	}
}

private func buttonConfig() -> UIButton.Configuration {
	var configuration = UIButton.Configuration.filled()
	configuration.baseForegroundColor = .white
	configuration.baseBackgroundColor = .lightGray.withAlphaComponent(0.5)
	configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
	configuration.background.cornerRadius = 8
	return configuration
}
