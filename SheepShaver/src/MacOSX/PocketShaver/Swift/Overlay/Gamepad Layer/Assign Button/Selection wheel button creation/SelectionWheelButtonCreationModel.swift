//
//  SelectionWheelButtonCreationModel.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-10-10.
//

import Foundation

enum SelectionWheelButtonCreationError: Error {
	case tooFewAssignments
}

class SelectionWheelButtonCreationModel {
	enum MoveAssignmentResult {
		case `default`
		case reloadRequired
	}

	var buttonName: String = ""

	var assignments: [SelectionWheelButtonAssignment] = []

	var canAddAssignments: Bool {
		assignments.count < 10
	}

	func addAssigment(_ assignment: SelectionWheelButtonAssignment) {
		assignments.append(assignment)
	}

	func moveAssignment(from: Int, to: Int) -> MoveAssignmentResult {
		let element = assignments.remove(at: from)
		if to <= assignments.count {
			assignments.insert(element, at: to)
			return .default
		} else {
			assignments.insert(element, at: assignments.count)
			return .reloadRequired
		}
	}

	func removeAssignment(at index: Int) {
		guard index < assignments.count else {
			return
		}

		assignments.remove(at: index)

		print("- after deletion")
		for e in assignments {
			print("\(e.label)")
		}
	}

	func reset() {
		assignments = []
	}

	func compileConfig() throws -> SelectionWheelButtonConfig {
		guard assignments.count >= 2 else {
			throw SelectionWheelButtonCreationError.tooFewAssignments
		}

		return .init(
			buttonName: buttonName,
			assignments: assignments
		)
	}
}
