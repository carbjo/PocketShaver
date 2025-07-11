//
//  OverlayViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

import UIKit


@objc(OverlayViewController)
public class OverlayViewController: UIViewController {

	private lazy var leftStack: UIStackView = {
		let stack = UIStackView()
		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.axis = .horizontal

		return stack
	}()

	private lazy var rightStack: UIStackView = {
		let stack = UIStackView()
		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.axis = .horizontal

		return stack
	}()

	private lazy var blockGestureRecognizer: UITapGestureRecognizer = {
		let gesture = UITapGestureRecognizer()
		gesture.numberOfTouchesRequired = 2
		gesture.addTarget(self, action: #selector(toggleBlockActivated))
		gesture.delegate = self

		return gesture
	}()

	private var testKeyboardLabel: UILabel!

	private var overlayView: OverlayView!
	private let testPushed: ((SDLKey) -> Void)
	private let testReleased: ((SDLKey) -> Void)
	private let testRaw: ((Int) -> Void)

	@objc
	public static func injectOverlayViewController(
		testPushed: @escaping ((SDLKey) -> Void),
		testReleased: @escaping ((SDLKey) -> Void),
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
		testPushed: @escaping ((SDLKey) -> Void),
		testReleased: @escaping ((SDLKey) -> Void),
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

	private var pushedKeys = Set<SDLKey>()

	public override func viewDidLoad() {
		super.viewDidLoad()

		overlayView = OverlayView()
		overlayView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(overlayView)

		NSLayoutConstraint.activate([
			overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			overlayView.topAnchor.constraint(equalTo: view.topAnchor),
			overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])

		overlayView.addGestureRecognizer(blockGestureRecognizer)

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

//		rightStack.addArrangedSubview(createButton(for: .minus))
//		rightStack.addArrangedSubview(createButton(for: .return))
//		rightStack.addArrangedSubview(createButton(for: .down))
//		rightStack.addArrangedSubview(createButton(for: .left))
//		rightStack.addArrangedSubview(createButton(for: .right))
//		rightStack.addArrangedSubview(createButton(for: .slash))

//		let testKeyboardButton = createButton()
//		testKeyboardButton.setTitle("Start", for: .normal)
//		testKeyboardButton.addTarget(self, action: #selector(testKeyboardButtonPushed), for: .touchUpInside)
//		leftStack.addArrangedSubview(testKeyboardButton)
//
//		rightStack.addArrangedSubview(createTestKeyboardView())

		overlayView.addSubview(leftStack)
		overlayView.addSubview(rightStack)

		NSLayoutConstraint.activate([
			leftStack.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: 64),
			leftStack.bottomAnchor.constraint(equalTo: overlayView.safeAreaLayoutGuide.bottomAnchor),

			rightStack.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: -80),
			rightStack.bottomAnchor.constraint(equalTo: overlayView.safeAreaLayoutGuide.bottomAnchor)
		])
	}

	private func createButton() -> UIButton {
		let button = UIButton()
		button.translatesAutoresizingMaskIntoConstraints = false
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
		button.tag = key.rawValue

		return button
	}

	private func createTestKeyboardView() -> UIView {
		let view = UIView()
		view.translatesAutoresizingMaskIntoConstraints = false
		view.backgroundColor = .gray.withAlphaComponent(0.3)

		let label = UILabel()
		label.translatesAutoresizingMaskIntoConstraints = false
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

	@objc func toggleBlockActivated() {
		overlayView.toggleBlockActivated()
	}

	@objc func testButtonPushed(sender: UIButton) {
		let key = SDLKey(rawValue: sender.tag)!
		guard !pushedKeys.contains(key) else {
			return
		}
		pushedKeys.insert(key)

		UIImpactFeedbackGenerator(style: .light).impactOccurred()

		testPushed(key)
	}

	@objc func testButtonReleased(sender: UIButton) {
		let key = SDLKey(rawValue: sender.tag)!
		testReleased(key)

		pushedKeys.remove(key)
	}

	@objc func cmdQpushed() {
		testPushed(.cmd)
		testPushed(.q)
		testReleased(.q)
		testReleased(.cmd)
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
	private var isBlockActivated: Bool = false

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		if !isBlockActivated {
			super.touchesBegan(touches, with: event)
		}
	}

	func toggleBlockActivated() {
		if isBlockActivated {
			print("block enabled")
			isBlockActivated = false
		} else {
			print("block disabled")
			isBlockActivated = true
		}
	}
}
