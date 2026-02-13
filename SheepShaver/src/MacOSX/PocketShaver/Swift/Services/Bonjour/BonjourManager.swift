//
//  BonjourManager.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-09.
//

import UIKit

class BonjourManager {
	static let shared = BonjourManager()

	private let session = BonjourSession(peerName: UIDevice.current.name)

	private var peers: Set<Peer> = []

	init() {
		session.onPeerConnection = { [weak self] peer in
			print("- found peer \(peer)")
			self?.peers.insert(peer)
		}

		session.onReceive = { [weak self] data, peer in
			self?.receive(data)
		}

		session.start()
	}

	func send(_ data: Data) {
		guard let peer = peers.first else {
			print("- No peer")
			return
		}

		session.send(data, to: [peer])
	}

	private func receive(_ data: Data) {
		objc_bonjourReceiveData(data)
	}
}

@objcMembers
class BonjourManagerObjCProxy: NSObject {
	static func send(data: Data) {
		BonjourManager.shared.send(data)
	}
}
