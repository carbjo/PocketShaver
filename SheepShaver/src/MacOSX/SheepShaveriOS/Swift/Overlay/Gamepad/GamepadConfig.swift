//
//  GamepadConfig.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-28.
//

import Foundation

enum GamepadSide: Codable, Equatable {
	case left
	case right
}

struct GamepadButtonPosition: Codable, Equatable {
	let side: GamepadSide
	let row: Int
	let index: Int
}

struct GamepadButtonAssignment: Codable {
	let position: GamepadButtonPosition
	let key: SDLKey
}

struct GamepadConfig: Codable {
	let assignments: [GamepadButtonAssignment]

	func replacing(key: SDLKey, at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = removingAssignment(at: position).assignments
		assignments.append(.init(position: position, key: key))

		return .init(assignments: assignments)
	}

	func removingAssignment(at position: GamepadButtonPosition) -> GamepadConfig {
		var assignments = assignments
		if let oldIndex = assignments.firstIndex(where: { $0.position == position }) {
			assignments.remove(at: oldIndex)
		}

		return .init(assignments: assignments)
	}

	@MainActor static var current: GamepadConfig {
		if let data = Storage.shared.load(from: .gamepad) {
			do {
				let config = try JSONDecoder().decode(Self.self, from: data)
				return config
			} catch {}
		}

		return .exampleConfig
	}

	private static var exampleConfig: GamepadConfig {
		.init(
			assignments: [
				.init(position: .init(side: .left, row: 0, index: 0), key: .down),
				.init(position: .init(side: .left, row: 0, index: 1), key: .up),
				.init(position: .init(side: .left, row: 0, index: 2), key: .space),
				.init(position: .init(side: .left, row: 1, index: 0), key: .q),
				.init(position: .init(side: .right, row: 0, index: 2), key: .tab),
				.init(position: .init(side: .right, row: 0, index: 1), key: .left),
				.init(position: .init(side: .right, row: 0, index: 0), key: .right),
				.init(position: .init(side: .right, row: 1, index: 1), key: .alt),
				.init(position: .init(side: .right, row: 1, index: 0), key: .cmd)
			]
		)
	}

	@MainActor func saveAsCurrent() {
		do {
			let data = try JSONEncoder().encode(self)
			Storage.shared.save(data, at: .gamepad)
		} catch {}
	}
}
