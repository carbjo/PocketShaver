//
//  DoneButton.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-15.
//

import UIKit

class DoneButton: UIBarButtonItem {
	init(
		target: AnyObject?,
		selector: Selector?
	) {

		super.init()

		title = "Done"
		style = .done
		self.target = target
		self.action = selector
		tintColor = Colors.primaryText
	}

	required init?(coder: NSCoder) { fatalError() }
}
