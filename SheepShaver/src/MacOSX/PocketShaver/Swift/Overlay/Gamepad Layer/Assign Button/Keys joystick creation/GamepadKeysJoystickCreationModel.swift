//
//  GamepadKeysJoystickCreationModel.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-08-04.
//

import Foundation

class GamepadKeysJoystickCreationModel {
	var keys: KeysJoystickConfig.Keys = .wasd

	var directions: KeysJoystickConfig.Directions = .eightWay

	var size: KeysJoystickConfig.Size = .regular

	func compileConfig() -> KeysJoystickConfig {
		.init(
			keys: keys,
			directions: directions,
			size: size
		)
	}
}
