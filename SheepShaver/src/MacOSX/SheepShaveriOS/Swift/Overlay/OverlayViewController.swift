//
//  OverlayViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

import UIKit


@objc(OverlayViewController)
public class OverlayViewController: UIViewController {

	private lazy var overlayView: OverlayView = {
		let view = OverlayView {
			self.buttonLayerView.isHidden = !self.buttonLayerView.isHidden
		}
		view.translatesAutoresizingMaskIntoConstraints = false
		return view
	}()

	private lazy var overlayViewGestureRecognizer: UISwipeGestureRecognizer = {
		let gesture = UISwipeGestureRecognizer()
		gesture.direction = .down
		gesture.numberOfTouchesRequired = 3
		gesture.addTarget(self, action: #selector(hideKeyboard))
		gesture.delegate = self

		return gesture
	}()

	private lazy var leftStack: UIStackView = {
		let stack = UIStackView.withoutConstraints()
		stack.axis = .horizontal

		return stack
	}()

	private lazy var rightStack: UIStackView = {
		let stack = UIStackView.withoutConstraints()
		stack.axis = .horizontal

		return stack
	}()

	private lazy var buttonLayerView: UIView = {
		let view = UIView.withoutConstraints()
		view.isHidden = true
		return view
	}()

	private lazy var buttonLayerViewGestureRecognizer: UISwipeGestureRecognizer = {
		let gesture = UISwipeGestureRecognizer()
		gesture.direction = .up
		gesture.numberOfTouchesRequired = 3
		gesture.addTarget(self, action: #selector(showKeyboard))
		gesture.delegate = self

		return gesture
	}()

	private lazy var hiddenInputField: UITextField = {
		let field = UITextField.withoutConstraints()
		field.autocapitalizationType = .none
		field.text = " "
		field.delegate = self.hiddenInputFieldDelegate
		return field
	}()

	private lazy var hiddenInputFieldDelegate: HiddenInputFieldDelegate = {
		let delegate = HiddenInputFieldDelegate { output in
			self.handle(hiddenInputFieldOutput: output)
		}
		return delegate
	}()

	private var testKeyboardLabel: UILabel!

	private let testPushed: ((Int) -> Void)
	private let testReleased: ((Int) -> Void)
	private let testRaw: ((Int) -> Void)

	@objc
	public static func injectOverlayViewController(
		testPushed: @escaping ((Int) -> Void),
		testReleased: @escaping ((Int) -> Void),
		testRaw: @escaping ((Int) -> Void)
	) {
		guard let window = UIApplication.shared.delegate?.window,
		let sdlVC = window?.rootViewController else {
			return
		}

		let vc = OverlayViewController(
			sdlVC: sdlVC,
			testPushed: testPushed,
			testReleased: testReleased,
			testRaw: testRaw
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
		sdlVC: UIViewController,
		testPushed: @escaping ((Int) -> Void),
		testReleased: @escaping ((Int) -> Void),
		testRaw: @escaping ((Int) -> Void)
	) {
		self.sdlVC = sdlVC
		self.testPushed = testPushed
		self.testReleased = testReleased
		self.testRaw = testRaw

		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	private weak var sdlVC: UIViewController!

	private var pushedKeys = Set<Int>()

	public override func viewDidLoad() {
		super.viewDidLoad()

		view.addSubview(overlayView)
		view.addSubview(buttonLayerView)

		NSLayoutConstraint.activate([
			overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			overlayView.topAnchor.constraint(equalTo: view.topAnchor),
			overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

			buttonLayerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			buttonLayerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			buttonLayerView.topAnchor.constraint(equalTo: view.topAnchor),
			buttonLayerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])

		overlayView.addGestureRecognizer(overlayViewGestureRecognizer)
		overlayView.addGestureRecognizer(buttonLayerViewGestureRecognizer)

		overlayView.addSubview(hiddenInputField)

		NSLayoutConstraint.activate([
			hiddenInputField.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
			hiddenInputField.bottomAnchor.constraint(equalTo: overlayView.topAnchor)
		])

//		let cmdQButton = createButton()
//		cmdQButton.setTitle("⌘Q", for: .normal)
//		cmdQButton.addTarget(self, action: #selector(cmdQpushed), for: .touchUpInside)


//		leftStack.addArrangedSubview(createButton(for: .ctrl))
//		leftStack.addArrangedSubview(createButton(for: .up))
//		leftStack.addArrangedSubview(createButton(for: .space))
//		leftStack.addArrangedSubview(createButton(for: .escape))
//		leftStack.addArrangedSubview(cmdQButton)
//		leftStack.addArrangedSubview(createButton(for: .up))
//		leftStack.addArrangedSubview(createButton(for: .shift))
//		leftStack.addArrangedSubview(createButton(for: .z))
//		leftStack.addArrangedSubview(createButton(for: .down))
//		leftStack.addArrangedSubview(createButton(for: .space))
//		leftStack.addArrangedSubview(createButton(for: .up))

//		rightStack.addArrangedSubview(createButton(for: .minus))
//		rightStack.addArrangedSubview(createButton(for: .return))
//		rightStack.addArrangedSubview(createButton(for: .down))
//		rightStack.addArrangedSubview(createButton(for: .ctrl))
//		rightStack.addArrangedSubview(createButton(for: .alt))
//		rightStack.addArrangedSubview(createButton(for: .tab))
//		rightStack.addArrangedSubview(createButton(for: .left))
//		rightStack.addArrangedSubview(createButton(for: .right))
//		rightStack.addArrangedSubview(createButton(for: .slash))

//		let testKeyboardButton = createButton()
//		testKeyboardButton.setTitle("Start", for: .normal)
//		testKeyboardButton.addTarget(self, action: #selector(testKeyboardButtonPushed), for: .touchUpInside)
//		leftStack.addArrangedSubview(testKeyboardButton)
////
//		rightStack.addArrangedSubview(createTestKeyboardView())

		buttonLayerView.addSubview(leftStack)
		buttonLayerView.addSubview(rightStack)

		NSLayoutConstraint.activate([
			leftStack.leadingAnchor.constraint(equalTo: buttonLayerView.leadingAnchor, constant: 64),
			leftStack.bottomAnchor.constraint(equalTo: buttonLayerView.safeAreaLayoutGuide.bottomAnchor),

			rightStack.trailingAnchor.constraint(equalTo: buttonLayerView.trailingAnchor, constant: -64),
			rightStack.bottomAnchor.constraint(equalTo: buttonLayerView.safeAreaLayoutGuide.bottomAnchor)
		])
	}

	private func createButton() -> UIButton {
		let button = UIButton.withoutConstraints()
		button.backgroundColor = .gray.withAlphaComponent(0.3)

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
		button.addTarget(self, action: #selector(testButtonReleased), for: .touchUpOutside)
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
	func showKeyboard() {
		hiddenInputField.becomeFirstResponder()
	}

	@objc
	func hideKeyboard() {
		hiddenInputField.resignFirstResponder()
	}

	@objc func toggleBlockActivated() {
		hiddenInputField.becomeFirstResponder()

//		buttonLayerView.isHidden = !buttonLayerView.isHidden
	}

	@objc func testButtonPushed(sender: UIButton) {
		let key = sender.tag
		guard !pushedKeys.contains(key) else {
			return
		}
		pushedKeys.insert(key)

		UIImpactFeedbackGenerator(style: .light).impactOccurred()

		testPushed(key)
	}

	@objc func testButtonReleased(sender: UIButton) {
		let key = sender.tag
		testReleased(key)

		pushedKeys.remove(key)
	}

	@objc func cmdQpushed() {
		testPushed(SDLKey.cmd.enValue)
		testPushed(SDLKey.q.enValue)
		testReleased(SDLKey.q.enValue)
		testReleased(SDLKey.cmd.enValue)
	}

	private func handle(hiddenInputFieldOutput: HiddenInputFieldOutput) {
		if hiddenInputFieldOutput.withShift {
			testPushed(SDLKey.shift.enValue)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
				guard let self else { return }
				self.testPushed(hiddenInputFieldOutput.value)
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
				guard let self else { return }
				self.testReleased(SDLKey.shift.enValue)
				self.testReleased(hiddenInputFieldOutput.value)
			}
		} else {
			testPushed(hiddenInputFieldOutput.value)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
				guard let self else { return }
				self.testReleased(hiddenInputFieldOutput.value)
			}
		}
	}

	@objc
	private func testKeyboardButtonPushed() {
		Task {
			for i in 0..<0x7f {
				let hexString = String(format:"%02X", i)
				Task { @MainActor in
					self.testKeyboardLabel.text = hexString
				}
				testRaw(i)
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
	private let overlayViewRecievedTwoFingerTap: (() -> Void)

	init(overlayViewRecievedTwoFingerTap: @escaping (() -> Void)) {
		self.overlayViewRecievedTwoFingerTap = overlayViewRecievedTwoFingerTap

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
		overlayViewRecievedTwoFingerTap()
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
