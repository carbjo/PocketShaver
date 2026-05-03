//
//  PreferencesNetworModel.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-15.
//

import UIKit
import Combine

class PreferencesNetworkModel {
	enum Change {
		case didUpdate
	}

	@MainActor
	private var manager: BonjourManager {
		BonjourManager.shared
	}

	private var anyCancellables = Set<AnyCancellable>()
	let changeSubject = PassthroughSubject<Change, Never>()

	let mode: PreferencesLaunchMode

	@MainActor
	var hasDismissedOsWarning: Bool {
		get {
			NetworkSettings.current.hasDismissedOsWarning
		}
		set {
			NetworkSettings.current.set(hasDismissedOsWarning: newValue)
			changeSubject.send(.didUpdate)
		}
	}

	@MainActor
	var serviceType: NetworkServiceType {
		get {
			NetworkSettings.current.serviceType
		}
		set {
			NetworkSettings.current.set(serviceType: newValue)
		}
	}

	@MainActor
	private let originalServiceType: NetworkServiceType = NetworkSettings.current.serviceType

	@MainActor
	var shouldDisplayServiceTypeChangeWarning: Bool {
		mode == .duringEmulation && serviceType != originalServiceType
	}

	@MainActor
	var bonjourRole: BonjourManager.Role {
		get {
			BonjourManager.shared.role
		}
		set {
			if newValue != bonjourRole {
				connectedPeers = []
				manager.set(role: newValue)
			}
		}
	}

	@MainActor
	var bonjourName: String {
		get {
			manager.thisDeviceName
		}
		set {
			manager.thisDeviceName = newValue
			changeSubject.send(.didUpdate)
		}
	}

	@MainActor
	private(set) var connectedPeers: [ConnectedPeer] = []
	
	@MainActor
	private(set) var clientsInSameHostRoom: [BonjourManager.Client] = []

	private(set) var selectedRouterPeer: ConnectedPeer?

	@MainActor
	var isConnectedToPeers: Bool {
		!connectedPeers.isEmpty
	}

	@MainActor
	var isSelectedRouterPeerAutojoinEnabled: Bool {
		get {
			guard let selectedRouterPeer else {
				return false
			}
			return BonjourManager.shared.isAutojoinEnabled(for: selectedRouterPeer)
		}
		set {
			guard let selectedRouterPeer else {
				return
			}

			BonjourManager.shared.setAutojoin(for: selectedRouterPeer, enabled: newValue)

			changeSubject.send(.didUpdate)
		}
	}

	@MainActor
	init(
		mode: PreferencesLaunchMode,
	) {
		self.mode = mode

		listenToChanges()
	}

	@MainActor
	private func listenToChanges() {
		BonjourManager.shared.changeSubject.sink { [weak self] change in
			guard let self else { return }
			Task { @MainActor [weak self] in
				guard let self else { return }
				switch change {
				case .connectedPeersDidChange:
					connectedPeers = manager.connectedPeers
					if let selectedRouterPeer {
						self.selectedRouterPeer = manager
							.connectedPeers
							.first(where: { $0.hardwareAddress == selectedRouterPeer.hardwareAddress })
					}

				case .clientsInSameHostRoomDidChange:
					clientsInSameHostRoom = manager.clientsInSameHostRoom

				case .didAutojoinRouterPeer:
					selectedRouterPeer = manager.selectedRouterPeer

				case .didDisconnectFromRouter:
					selectedRouterPeer = nil

				case .didReset:
					connectedPeers = []
					clientsInSameHostRoom = []
					selectedRouterPeer = nil
				}

				changeSubject.send(.didUpdate)
			}
		}.store(in: &anyCancellables)
	}

	@MainActor
	func set(selectedRouterPeer: ConnectedPeer) throws {
		try BonjourManager.shared.pickRouterPeer(selectedRouterPeer)

		self.selectedRouterPeer = selectedRouterPeer
	}

	@MainActor
	func resetSelectedRouterPeer() {
		guard selectedRouterPeer != nil else {
			return
		}

		selectedRouterPeer = nil

		BonjourManager.shared.resetRouterPeer()
	}

	@MainActor
	func reloadData() {
		guard connectedPeers != manager.connectedPeers ||
			clientsInSameHostRoom != manager.clientsInSameHostRoom ||
			selectedRouterPeer != manager.selectedRouterPeer else {
			return
		}

		connectedPeers = manager.connectedPeers
		clientsInSameHostRoom = manager.clientsInSameHostRoom
		selectedRouterPeer = manager.selectedRouterPeer

		changeSubject.send(.didUpdate)
	}
}
