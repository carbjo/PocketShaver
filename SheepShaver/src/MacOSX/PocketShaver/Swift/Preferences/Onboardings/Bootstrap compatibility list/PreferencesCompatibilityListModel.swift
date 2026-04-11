//
//  PreferencesCompatibilityListModel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-12.
//

import Foundation

class PreferencesCompatibilityModel {
	enum Entry {
		case newWorldRomVersion(NewWorldRomVersion)
		case other(String)
	}

	let entries: [Entry] = [
		.other("Mac OS 8.0 and lower"),
		
		.newWorldRomVersion(.v110),
		.other("Any Mac OS 8.1 install disc other than the one bundled on iMac, Rev A"),
		.newWorldRomVersion(.v112),
		.newWorldRomVersion(.v115),
		.newWorldRomVersion(.v120),
		.newWorldRomVersion(.v121),
		.newWorldRomVersion(.v140),
		.newWorldRomVersion(.v160),
		.newWorldRomVersion(.v171),
		.newWorldRomVersion(.v181),
		.newWorldRomVersion(.v231),
		.newWorldRomVersion(.v251),
		.newWorldRomVersion(.v300),
		.newWorldRomVersion(.v311),
		.newWorldRomVersion(.v321),
		.newWorldRomVersion(.v350),
		.newWorldRomVersion(.v360),
		.newWorldRomVersion(.v370),
		.newWorldRomVersion(.v380),
		.newWorldRomVersion(.v390),
		.newWorldRomVersion(.v461),
		.newWorldRomVersion(.v491),
		.newWorldRomVersion(.v521),
		.newWorldRomVersion(.v531),
		.newWorldRomVersion(.v551),

		.other("Mac OS 9.1 and higher"),
	]
}
