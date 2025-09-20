//
//  PreferencesGamepadViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit
import Combine

class PreferencesGamepadViewController: UITableViewController {
	@MainActor
	enum SectionType: Int, CaseIterable {
		case information
		case gamepadLayouts
	}

	private var gamepadConfigs: [GamepadConfig] {
		GamepadSettings.current.configurations
	}

	private let changeSubject: PassthroughSubject<PreferencesChange, Never>

	init(changeSubject: PassthroughSubject<PreferencesChange, Never>) {
		self.changeSubject = changeSubject

		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		view.translatesAutoresizingMaskIntoConstraints = false
		view.backgroundColor = .white
	}

	func presentEditConfig(config: GamepadConfig) {
		let parentVc = parent!

		let vc = PreferencesGamepadEditConfigViewController(
			gamepadConfig: config,
			dismissRequestCallback: { [weak self] vc in
				vc.removeFromParent()
				vc.view.removeFromSuperview()
				self?.tableView.reloadData()
			}
		)

		vc.willMove(toParent: parentVc)

		parentVc.addChild(vc)
		parentVc.view.addSubview(vc.view)

		NSLayoutConstraint.activate([
			vc.view.leadingAnchor.constraint(equalTo: parentVc.view.leadingAnchor),
			vc.view.topAnchor.constraint(equalTo: parentVc.view.topAnchor),
			vc.view.trailingAnchor.constraint(equalTo: parentVc.view.trailingAnchor),
			vc.view.bottomAnchor.constraint(equalTo: parentVc.view.bottomAnchor)
		])

		vc.didMove(toParent: parentVc)

		vc.animatePresent()
	}
}

extension PreferencesGamepadViewController { // UITableViewDataSource, UITableViewDelegate

	override func numberOfSections(in tableView: UITableView) -> Int {
		SectionType.count
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		let sectionType = SectionType(sectionIndex: section)
		switch sectionType {
		case .information:
			return 1
		case .gamepadLayouts:
			return gamepadConfigs.isEmpty ? 1 : gamepadConfigs.count
		}
	}

	override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
		let sectionType = SectionType(sectionIndex: section)
		switch sectionType {
		case .information:
			return UIView.withoutConstraints()
		case .gamepadLayouts:
			return PreferencesGamepadConfigHeaderCell(
				shouldShowEdit: !gamepadConfigs.isEmpty,
				didTapEditButton: {
					tableView.setEditing(!tableView.isEditing, animated: true)
				}
			)
		}
	}

	override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
		let sectionType = SectionType(sectionIndex: section)
		switch sectionType {
		case .information:
			return 0.0001
		case .gamepadLayouts:
			return UITableView.automaticDimension
		}
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let sectionType = SectionType(sectionIndex: indexPath.section)
		switch sectionType {
		case .information:
			return PreferencesGamepadInformationCell()
		case .gamepadLayouts:
			if gamepadConfigs.isEmpty {
				return PreferencesGamepadConfigsEmptyStateCell()
			}

			let gamepadConfig = gamepadConfigs[indexPath.row]
			return PreferencesGamepadConfigCell(
				gamepadConfig: gamepadConfig
			) { [weak self] in
				self?.presentEditConfig(config: gamepadConfig)
			}
		}
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
		let sectionType = SectionType(sectionIndex: indexPath.section)
		switch sectionType {
		case .information:
			return false
		case .gamepadLayouts:
			return !gamepadConfigs.isEmpty
		}
	}

	override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
		let sectionType = SectionType(sectionIndex: indexPath.section)
		switch sectionType {
		case .information:
			return false
		case .gamepadLayouts:
			return true
		}
	}

	override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
		GamepadSettings.current.move(from: sourceIndexPath.row, to: destinationIndexPath.row)
	}

	override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
		guard editingStyle == .delete else {
			return
		}

		GamepadSettings.current.remove(at: indexPath.row)

		if gamepadConfigs.isEmpty {
			if let gamepadConfigHeaderCell = tableView.headerView(forSection: SectionType.gamepadLayouts.rawValue) as? PreferencesGamepadConfigHeaderCell {
				gamepadConfigHeaderCell.config(shouldShowEdit: false)
			}

			tableView.performBatchUpdates {
				tableView.insertRows(at: [indexPath], with: .fade)
				tableView.deleteRows(at: [indexPath], with: .fade)
			}
			tableView.setEditing(false, animated: false)

		} else {
			tableView.deleteRows(at: [indexPath], with: .automatic)
		}
	}
}

extension PreferencesGamepadViewController.SectionType {
	init(sectionIndex: Int) {
		self = Self(rawValue: sectionIndex)!
	}

	static var count: Int {
		allCases.count
	}

	func sectionIndex() -> Int {
		rawValue
	}
}
