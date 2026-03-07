//
//  PreferencesTwoFingerSteeringDetailsViewController.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-03-07.
//

import UIKit

class PreferencesTwoFingerSteeringDetailsViewController: UITableViewController {
	private lazy var doneButton: DoneButton = {
		DoneButton(target: self, selector: #selector(doneButtonPressed))
	}()

	private var miscSettings: MiscellaneousSettings {
		.current
	}

	private let didChangeCallback: (() -> Void)

	init(didChangeCallback: @escaping () -> Void) {
		self.didChangeCallback = didChangeCallback

		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		view.translatesAutoresizingMaskIntoConstraints = false
		view.backgroundColor = .white
		tableView.showsVerticalScrollIndicator = false

		navigationItem.rightBarButtonItem = doneButton
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		if miscSettings.secondFingerSwipe {
			return 6
		} else if miscSettings.secondFingerClick {
			return 4
		} else {
			return 2
		}
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		switch indexPath.row {
		case 0:
			return PreferencesEnabledSettingCell(
				title: "Second finger click",
				isOn: miscSettings.secondFingerClick
			) { [weak self] isOn in
				self?.set(secondFingerClick: isOn)
			}
		case 1:
			return PreferencesInformationCell(
				text: "A second finger can be used for mouse clicking, while the first finger controls the position. Only has effect when a hover mode, or relative mouse mode, is enabled.",
				separatorHidden: !miscSettings.secondFingerClick
			)
		case 2:
			return PreferencesEnabledSettingCell(
				title: "Second finger swipe",
				isOn: miscSettings.secondFingerSwipe
			) { [weak self] isOn in
				self?.set(secondFingerSwipe: isOn)
			}
		case 3:
			return PreferencesInformationCell(
				text: "A second finger can be used for quickly swiping between the four mouse hover modes. Only has effect when a hover mode is already enabled.",
				separatorHidden: !miscSettings.secondFingerSwipe
			)
		case 4:
			return PreferencesEnabledSettingCell(
				title: "Boot in hover mode",
				isOn: miscSettings.bootInHoverMode
			) { [weak self] isOn in
				self?.set(bootInHoverMode: isOn)
			}
		case 5:
			return PreferencesInformationCell(
				text: "Hover (just above) is on by default when booting, making Two finger steering available from the start."
			)
		default: fatalError()
		}
	}

	private func set(
		secondFingerClick: Bool? = nil,
		secondFingerSwipe: Bool? = nil,
		bootInHoverMode: Bool? = nil
	) {
		let prevSecondFingerClick = miscSettings.secondFingerClick
		let prevSecondFingerSwipe = miscSettings.secondFingerSwipe

		let secondFingerClick = secondFingerClick ?? miscSettings.secondFingerClick
		var secondFingerSwipe = secondFingerSwipe ?? miscSettings.secondFingerSwipe
		var bootInHoverMode = bootInHoverMode ?? miscSettings.bootInHoverMode

		if !secondFingerClick {
			secondFingerSwipe = false
			bootInHoverMode = false
		} else if !secondFingerSwipe {
			bootInHoverMode = false
		}

		miscSettings.set(secondFingerClick: secondFingerClick)
		miscSettings.set(secondFingerSwipe: secondFingerSwipe)
		miscSettings.set(bootInHoverMode: bootInHoverMode)


		let sectionIndex = 0

		tableView.performBatchUpdates {
			if !prevSecondFingerClick,
			   secondFingerClick {
				tableView.insertRows(at: [
					.init(row: 2, section: sectionIndex),
					.init(row: 3, section: sectionIndex)
				], with: .fade)
				tableView.reloadRows(at: [
					.init(row: 1, section: sectionIndex)
				], with: .fade)
			} else if prevSecondFingerClick,
					  !secondFingerClick {
				tableView.deleteRows(at: [
					.init(row: 2, section: sectionIndex),
					.init(row: 3, section: sectionIndex)
				], with: .fade)
				tableView.reloadRows(at: [
					.init(row: 1, section: sectionIndex)
				], with: .fade)
			}
			if !prevSecondFingerSwipe,
			   secondFingerSwipe {
				tableView.insertRows(at: [
					.init(row: 4, section: sectionIndex),
					.init(row: 5, section: sectionIndex)
				], with: .fade)
				if secondFingerClick {
					tableView.reloadRows(at: [
						.init(row: 3, section: sectionIndex)
					], with: .fade)
				}
			} else if prevSecondFingerSwipe,
					  !secondFingerSwipe {
				tableView.deleteRows(at: [
					.init(row: 4, section: sectionIndex),
					.init(row: 5, section: sectionIndex)
				], with: .fade)
				if secondFingerClick {
					tableView.reloadRows(at: [
						.init(row: 3, section: sectionIndex)
					], with: .fade)
				}
			}
		}

		didChangeCallback()
	}

	@objc
	private func doneButtonPressed() {
		dismiss(animated: true)
	}
}
