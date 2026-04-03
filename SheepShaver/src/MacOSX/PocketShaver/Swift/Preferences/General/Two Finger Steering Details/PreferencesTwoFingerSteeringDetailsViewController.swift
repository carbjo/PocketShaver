//
//  PreferencesTwoFingerSteeringDetailsViewController.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-03-07.
//

import UIKit

class PreferencesTwoFingerSteeringDetailsViewController: UITableViewController {
	enum Section {
		case main
	}

	enum Row: Hashable {
		case secondFingerClickEnabledToggle
		case secondFingerClickInstructions(Bool)
		case secondFingerSwipeEnabledToggle
		case secondFingerSwipeInstructions(Bool)
		case bootInHoverModeEnabledToggle
		case bootInHoverModeInstructions
	}

	private lazy var doneButton: DoneButton = {
		DoneButton(target: self, selector: #selector(doneButtonPressed))
	}()

	private var miscSettings: MiscellaneousSettings {
		.current
	}

	private let didChangeCallback: (() -> Void)

	private var dataSource: TableViewDiffableDataSource<Section, Row>!

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

		setupDataSource()
	}

	private func setupDataSource() {
		dataSource = .init(tableView: tableView) { [weak self] tableView, indexPath, itemIdentifier in
			guard let self else { return UITableViewCell() }
			switch itemIdentifier {
			case .secondFingerClickEnabledToggle:
				return PreferencesEnabledSettingCell(
					title: "Second finger click",
					isOn: miscSettings.secondFingerClick
				) { [weak self] isOn in
					guard let self else { return }

					miscSettings.set(twoFingerSteeringSetting: isOn ? .click : .off)
					reportToggleSwitched()
				}
			case .secondFingerClickInstructions(let separatorHidden):
				return PreferencesInformationCell(
					text: "A second finger can be used for mouse clicking, while the first finger controls the position. Only has effect when a hover mode is enabled.",
					separatorHidden: separatorHidden
				)
			case .secondFingerSwipeEnabledToggle:
				return PreferencesEnabledSettingCell(
					title: "Second finger swipe",
					isOn: miscSettings.secondFingerSwipe
				) { [weak self] isOn in
					guard let self else { return }

					miscSettings.set(twoFingerSteeringSetting: isOn ? .clickPlusSwipe : .click)
					reportToggleSwitched()
				}
			case .secondFingerSwipeInstructions(let separatorHidden):
				return PreferencesInformationCell(
					text: "A second finger can be used for quickly swiping between the four mouse hover modes. Only has effect when a hover mode is already enabled.",
					separatorHidden: separatorHidden
				)
			case .bootInHoverModeEnabledToggle:
				return PreferencesEnabledSettingCell(
					title: "Boot in hover mode",
					isOn: miscSettings.bootInHoverMode
				) { [weak self] isOn in
					guard let self else { return }

					miscSettings.set(twoFingerSteeringSetting: isOn ? .clickPlusSwipePlusBootInHoverMode : .clickPlusSwipe)
					reportToggleSwitched()
				}
			case .bootInHoverModeInstructions:
				return PreferencesInformationCell(
					text: "Hover (diagnoally above) is on by default when booting, making Two finger steering available from the start."
				)
			}
		}

		dataSource.defaultRowAnimation = .fade
		tableView.dataSource = dataSource

		reloadData()
	}

	private func reloadData() {
		var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()

		snapshot.appendSections([.main])

		snapshot.appendItems([
			.secondFingerClickEnabledToggle,
			.secondFingerClickInstructions(!miscSettings.secondFingerClick)
		])

		if miscSettings.secondFingerClick {
			snapshot.appendItems([
				.secondFingerSwipeEnabledToggle,
				.secondFingerSwipeInstructions(!miscSettings.secondFingerSwipe)
			])

			if miscSettings.secondFingerSwipe {
				snapshot.appendItems([
					.bootInHoverModeEnabledToggle,
					.bootInHoverModeInstructions
				])
			}
		}

		dataSource.apply(snapshot)
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	func reportToggleSwitched() {
		reloadData()
		didChangeCallback()
	}

	@objc
	private func doneButtonPressed() {
		dismiss(animated: true)
	}
}
