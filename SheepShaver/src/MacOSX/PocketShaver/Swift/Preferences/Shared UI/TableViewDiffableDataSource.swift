//
//  TableViewDiffableDataSource.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-03-04.
//

import UIKit

/// Shared base for the preferences table screens. The stock plain-style
/// section headers are small and pale, which on the full-screen Mac window
/// makes each tab read as one undifferentiated list — replace them with big
/// bold full-contrast headings there. iPhone/iPad keep the stock look.
///
/// The header view is built from scratch rather than restyled: UIKit renders
/// the stock header title through a content configuration it re-applies after
/// `willDisplay`, so font/color set on its `textLabel` does not survive.
class PreferencesTableViewController: UITableViewController {
	private func macSectionTitle(_ tableView: UITableView, _ section: Int) -> String? {
		guard UIDevice.deviceType == .mac,
			  let title = tableView.dataSource?.tableView?(tableView, titleForHeaderInSection: section),
			  !title.isEmpty else {
			return nil
		}
		return title
	}

	private func sectionHasTitle(_ tableView: UITableView, _ section: Int) -> Bool {
		guard let title = tableView.dataSource?.tableView?(tableView, titleForHeaderInSection: section) else {
			return false
		}
		return !title.isEmpty
	}

	override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
		guard let title = macSectionTitle(tableView, section) else {
			return nil // stock header (and collapsed untitled sections)
		}

		let header = UIView()
		header.backgroundColor = Colors.primaryBackground

		let label = UILabel.withoutConstraints()
		label.text = title
		label.font = .boldSystemFont(ofSize: 20)
		label.textColor = Colors.primaryText
		header.addSubview(label)

		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
			label.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -16),
			label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8)
		])

		return header
	}

	override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
		// Collapse untitled sections. automaticDimension let the grouped style
		// reserve its default header padding, so a nil title still showed an
		// empty header; leastNonzeroMagnitude reads as zero without that default.
		guard sectionHasTitle(tableView, section) else {
			return .leastNonzeroMagnitude
		}

		return UIDevice.deviceType == .mac ? 52 : UITableView.automaticDimension
	}
}

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
