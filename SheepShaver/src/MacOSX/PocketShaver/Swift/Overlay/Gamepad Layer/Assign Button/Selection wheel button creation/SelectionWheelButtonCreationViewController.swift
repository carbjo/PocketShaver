//
//  SelectionWheelButtonCreationViewController.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-10-10.
//

import UIKit

enum SelectionWheelButtonCreationPresentationType {
	case `default`
	case prePopulateWithNumbers
}

class SelectionWheelButtonCreationViewController: UITableViewController {
	enum Section {
		case name
		case assignments
	}

	enum Row: Hashable {
		// name
		case buttonName

		// assignments
		case assignment(Int, String)
		case addAssignment
	}

	private(set) var model = SelectionWheelButtonCreationModel()
	private var dataSource: TableViewDiffableDataSource<Section, Row>!

	private var isDisplayingEditMode = false

	let addAssignmentRequested: (() -> Void)

	init(
		addAssignmentRequested: @escaping (() -> Void)
	) {
		self.addAssignmentRequested = addAssignmentRequested

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
			case .buttonName:
				return SelectionWheelButtonCreationButtonNameCell(
					initialName: model.buttonName,
				) { [weak self] buttonName in
					self?.model.buttonName = buttonName
				}
			case .assignment(_, let label):
				return SelectionWheelButtonCreationAssignmentCell(
					title: label
				)
			case .addAssignment:
				return SelectionWheelButtonCreationAddAssignmentCell(
					initiallyVisible: !isDisplayingEditMode
				)
			}
		}

		dataSource.sectionTitleProvider = { section in
			switch section {
			case .name:
				return "Name"
			case .assignments:
				// Using PreferencesEditableSectionHeaderCell in delegate
				return nil
			}
		}

		dataSource.canEditProvider = { identifier in
			switch identifier {
			case .assignment:
				return true
			default:
				return false
			}
		}

		dataSource.commitEditProvider = { [weak self] row, editingStyle in
			guard let self,
				  editingStyle == .delete,
				  case .assignment(let index, _) = row else {
				return
			}

			model.removeAssignment(at: index)
			reloadData()

			if model.assignments.isEmpty {
				setEditing(false)

				if let sectionIndex = dataSource.index(for: .assignments),
				   let cell = tableView.headerView(forSection: sectionIndex) as? PreferencesEditableSectionHeaderCell {
					cell.config(shouldShowEdit: false)
				}
			}
		}

		dataSource.canMoveProvider = { identifier in
			switch identifier {
			case .assignment:
				return true
			default:
				return false
			}
		}

		dataSource.commitMoveRow = { [weak self] source, destination in
			guard let self else { return }
			let moveResult = model.moveAssignment(from: source.row, to: destination.row)
			if moveResult == .reloadRequired {
				reloadData()
			}
		}

		tableView.dataSource = dataSource

		reloadData()
	}

	fileprivate func reloadData() {
		var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()

		snapshot.appendSections([.name])
		snapshot.appendItems([
			.buttonName
		])

		snapshot.appendSections([.assignments])
		for (index, value) in model.assignments.enumerated() {
			snapshot.appendItems([
				.assignment(index, value.label)
			])
		}

		if model.canAddAssignments {
			snapshot.appendItems([
				.addAssignment
			])
		}

		dataSource.apply(snapshot)
	}

	private func setEditing(_ editing: Bool) {
		tableView.setEditing(editing, animated: true)

		// Want this distinguished from the temporary tableView.isEditing = true that happens during swipe-to-delete
		isDisplayingEditMode = editing

		UIView.animate(withDuration: 0.2) {
			guard let indexPath = self.dataSource.indexPath(for: .addAssignment),
				  let cell = self.tableView.cellForRow(at: indexPath) as? SelectionWheelButtonCreationAddAssignmentCell else {
					  return
				  }
			cell.contentView.alpha = editing ? 0 : 1
		}
	}

	func addAssignment(_ assignment: SelectionWheelButtonAssignment) {
		model.addAssigment(assignment)
		reloadData()

		if let sectionIndex = dataSource.index(for: .assignments),
		   let cell = tableView.headerView(forSection: sectionIndex) as? PreferencesEditableSectionHeaderCell {
			cell.config(shouldShowEdit: true)
		}
	}

	func load(config: SelectionWheelButtonConfig) {
		model.buttonName = config.buttonName
		model.assignments = config.assignments
	}
}

extension SelectionWheelButtonCreationViewController { // UITableViewDelegate
	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		let itemIdentifier = dataSource.itemIdentifier(for: indexPath)
		return itemIdentifier == .addAssignment
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let itemIdentifier = dataSource.itemIdentifier(for: indexPath)

		switch itemIdentifier {
		case .addAssignment:
			addAssignmentRequested()
		default:
			fatalError()
		}
	}

	override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
		guard let sectionIdentifier = dataSource.sectionIdentifier(for: section) else {
			return nil
		}

		switch sectionIdentifier {
		case .name:
			return super.tableView(tableView, viewForHeaderInSection: section)
		case .assignments:
			return PreferencesEditableSectionHeaderCell(
				title: "Assignments",
				shouldShowEdit: !model.assignments.isEmpty,
				isEditing: tableView.isEditing,
				didTapEditButton: { [weak self] in
					self?.setEditing(!tableView.isEditing)
				}
			)
		}
	}
}

extension SelectionWheelButtonCreationViewController {
	func resetIfNeeded() {
		guard tableView.isEditing || !model.assignments.isEmpty else {
			return
		}

		if tableView.isEditing {
			tableView.isEditing = false
		}

		model.reset()
		reloadData()
	}

	func setupWithNumbersTemplate() {
		model.addAssigment(.sdlKey(.n1))
		model.addAssigment(.sdlKey(.n2))
		model.addAssigment(.sdlKey(.n3))
		model.addAssigment(.sdlKey(.n4))
		model.addAssigment(.sdlKey(.n5))
		model.addAssigment(.sdlKey(.n6))
		model.addAssigment(.sdlKey(.n7))
		model.addAssigment(.sdlKey(.n8))
		model.addAssigment(.sdlKey(.n9))
		model.addAssigment(.sdlKey(.n0))

		reloadData()
	}
}
