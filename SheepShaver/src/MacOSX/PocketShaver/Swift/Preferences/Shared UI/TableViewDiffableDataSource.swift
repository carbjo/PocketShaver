//
//  TableViewDiffableDataSource.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-03-04.
//

import UIKit

class TableViewDiffableDataSource<T: Hashable, S: Hashable> : UITableViewDiffableDataSource<T, S> {
	var sectionTitleProvider: ((T) -> String?)?

	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		if let sectionTitleProvider,
		   let sectionIdentifier = sectionIdentifier(for: section) {
			return sectionTitleProvider(sectionIdentifier)
		}

		return super.tableView(tableView, titleForHeaderInSection: section)
	}
}
