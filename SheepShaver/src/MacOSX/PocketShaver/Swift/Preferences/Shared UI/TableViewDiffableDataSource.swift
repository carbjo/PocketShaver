//
//  TableViewDiffableDataSource.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-03-04.
//

import UIKit

class TableViewDiffableDataSource<T: Hashable, S: Hashable> : UITableViewDiffableDataSource<T, S> {
	var sectionTitleProvider: ((T) -> String?)?
	var canEditProvider: ((S) -> Bool)?
	var commitEditProvider: ((S, UITableViewCell.EditingStyle) -> Void)?

	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		if let sectionTitleProvider,
		   let sectionIdentifier = sectionIdentifier(for: section) {
			return sectionTitleProvider(sectionIdentifier)
		}

		return super.tableView(tableView, titleForHeaderInSection: section)
	}

	override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
		guard let canEditProvider,
			  let identifier = itemIdentifier(for: indexPath) else {
			return false
		}

		return canEditProvider(identifier)
	}

	override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
		guard let commitEditProvider,
			  let identifier = itemIdentifier(for: indexPath) else {
			return
		}

		commitEditProvider(identifier, editingStyle)
	}

	func reloadSection(_ section: T) {
		var snapshot = snapshot()
		snapshot.reloadSections([section])
		apply(snapshot)
	}

	func reloadItems(_ items: [S]) {
		var snapshot = snapshot()
		snapshot.reloadItems(items)
		apply(snapshot)
	}

	// Source - https://stackoverflow.com/a/60736803
	// Posted by alexkent, modified by community. See post 'Timeline' for change history
	// Retrieved 2026-03-22, License - CC BY-SA 4.0

	func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath, completion: (() -> Void)? = nil) {
		super.tableView(tableView, moveRowAt: sourceIndexPath, to: destinationIndexPath)

		var snapshot = self.snapshot()
		if let sourceId = itemIdentifier(for: sourceIndexPath) {
			if let destinationId = itemIdentifier(for: destinationIndexPath) {
				guard sourceId != destinationId else {
					completion?()
					return // destination is same as source, no move.
				}
				// valid source and destination
				if sourceIndexPath.row > destinationIndexPath.row {
					snapshot.moveItem(sourceId, beforeItem: destinationId)
				} else {
					snapshot.moveItem(sourceId, afterItem: destinationId)
				}
			} else {
				// no valid destination, eg. moving to the last row of a section
				snapshot.deleteItems([sourceId])
				snapshot.appendItems([sourceId], toSection: snapshot.sectionIdentifiers[destinationIndexPath.section])
			}
		}

		apply(snapshot, animatingDifferences: false, completion: completion)
	}
}
