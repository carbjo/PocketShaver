//
//  GamepadKeysJoystickCreationViewController.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-08-04.
//

import UIKit

class GamepadKeysJoystickCreationViewController: UITableViewController {
	enum Section {
		case keysType
		case directions
		case size
	}

	enum Row: Hashable {
		// keysType
		case keysTypeWasd
		case keysTypeArrows

		// directions
		case directionsFourWay
		case directionsEightWay

		// size
		case sizeRegular
		case sizeSmall
	}

	private(set) var model = GamepadKeysJoystickCreationModel()
	private var dataSource: TableViewDiffableDataSource<Section, Row>!

	init() {
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		view.translatesAutoresizingMaskIntoConstraints = false

		view.backgroundColor = .clear

		setupDataSource()
	}

	private func setupDataSource() {
		dataSource = .init(tableView: tableView) { [weak self] tableView, indexPath, itemIdentifier in
			guard let self else { return UITableViewCell() }
			switch itemIdentifier {
			case .keysTypeWasd:
				return PreferencesRadioButtonChoiceCell(
					title: "WASD",
					isSelected: model.keys == .wasd,
					marginSize: .small
				)
			case .keysTypeArrows:
				return PreferencesRadioButtonChoiceCell(
					title: "Arrows",
					isSelected: model.keys == .arrows,
					marginSize: .small
				)
			case .directionsFourWay:
				return PreferencesRadioButtonChoiceCell(
					title: "Four-way",
					isSelected: model.directions == .fourWay,
					marginSize: .small
				)
			case .directionsEightWay:
				return PreferencesRadioButtonChoiceCell(
					title: "Eight-way",
					isSelected: model.directions == .eightWay,
					marginSize: .small
				)
			case .sizeRegular:
				return PreferencesRadioButtonChoiceCell(
					title: "Regular",
					isSelected: model.size == .regular,
					marginSize: .small
				)
			case .sizeSmall:
				return PreferencesRadioButtonChoiceCell(
					title: "Small",
					isSelected: model.size == .small,
					marginSize: .small
				)
			}
		}

		dataSource.sectionTitleProvider = { section in
			switch section {
			case .keysType:
				return "Keys type"
			case .directions:
				return "Directions"
			case .size:
				return "Size"

			}
		}

		tableView.dataSource = dataSource

		reloadData()
	}

	private func reloadData() {
		var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()

		snapshot.appendSections([.keysType])
		snapshot.appendItems([
			.keysTypeWasd,
			.keysTypeArrows
		])

		snapshot.appendSections([.directions])
		snapshot.appendItems([
			.directionsFourWay,
			.directionsEightWay
		])

		snapshot.appendSections([.size])
		snapshot.appendItems([
			.sizeRegular,
			.sizeSmall
		])

		dataSource.apply(snapshot)
	}

	private func updateKeysTypeCells() {
		let wasdIndexPath = dataSource.indexPath(for: .keysTypeWasd)!
		if let wasdCell = tableView.cellForRow(at: wasdIndexPath) as? PreferencesRadioButtonChoiceCell {
			wasdCell.configure(isSelected: model.keys == .wasd)
		}

		let arrowsIndexPath = dataSource.indexPath(for: .keysTypeArrows)!
		if let arrowsCell = tableView.cellForRow(at: arrowsIndexPath) as? PreferencesRadioButtonChoiceCell {
			arrowsCell.configure(isSelected: model.keys == .arrows)
		}
	}

	private func updateDirectionsCells() {
		let fourWayIndexPath = dataSource.indexPath(for: .directionsFourWay)!
		if let fourWayCell = tableView.cellForRow(at: fourWayIndexPath) as? PreferencesRadioButtonChoiceCell {
			fourWayCell.configure(isSelected: model.directions == .fourWay)
		}

		let eightWayIndexPath = dataSource.indexPath(for: .directionsEightWay)!
		if let eightWayCell = tableView.cellForRow(at: eightWayIndexPath) as? PreferencesRadioButtonChoiceCell {
			eightWayCell.configure(isSelected: model.directions == .eightWay)
		}
	}

	private func updateSizeCells() {
		let regularIndexPath = dataSource.indexPath(for: .sizeRegular)!
		if let regularCell = tableView.cellForRow(at: regularIndexPath) as? PreferencesRadioButtonChoiceCell {
			regularCell.configure(isSelected: model.size == .regular)
		}

		let smallIndexPath = dataSource.indexPath(for: .sizeSmall)!
		if let smallCell = tableView.cellForRow(at: smallIndexPath) as? PreferencesRadioButtonChoiceCell {
			smallCell.configure(isSelected: model.size == .small)
		}
	}
}

extension GamepadKeysJoystickCreationViewController { // UITableViewDataSource, UITableViewDelegate

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let itemIdentifier = dataSource.itemIdentifier(for: indexPath)

		switch itemIdentifier {
		case .keysTypeWasd:
			model.keys = .wasd
			updateKeysTypeCells()
		case .keysTypeArrows:
			model.keys = .arrows
			updateKeysTypeCells()
		case .directionsFourWay:
			model.directions = .fourWay
			updateDirectionsCells()
		case .directionsEightWay:
			model.directions = .eightWay
			updateDirectionsCells()
		case .sizeRegular:
			model.size = .regular
			updateSizeCells()
		case .sizeSmall:
			model.size = .small
			updateSizeCells()
		default: break
		}
	}
}
