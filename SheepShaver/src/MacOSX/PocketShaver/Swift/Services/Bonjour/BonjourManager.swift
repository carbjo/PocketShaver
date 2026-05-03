//
//  BonjourManager.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-09.
//

import UIKit
import Combine

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

struct ConnectedPeer: Hashable {
	let id: String
	let name: String
	let hardwareAddress: String
	let role: BonjourManager.Role
}

enum BonjourManagerError: Error {
	case pickedRouterWasNotAvailable
}

class BonjourManager {
	private enum RouterResponsibiliyStatus {
		case thisDevice(Router)
		case otherDevice(Peer)
		case undecided
	}

	enum Role: String, Codable, CaseIterable {
		case host
		case client
	}

	struct Client: Codable, Hashable {
		let name: String
		let hardwareAddress: String
	}

	enum Change {
		case connectedPeersDidChange
		case clientsInSameHostRoomDidChange
		case didAutojoinRouterPeer
		case didDisconnectFromRouter
		case didReset
	}

	@MainActor
	static let shared = BonjourManager()

	private var session: BonjourSession?

	private lazy var thisDeviceAddress: HardwareAddress = {
		NetworkSettingsCachedSettings.hardwareAddress!
	}()

	@MainActor
	private var networkSettings: NetworkSettings {
		.current
	}

	private var routerResponsibiliyStatus: RouterResponsibiliyStatus = .undecided
	private lazy var dataRecieveQueue: OperationQueue = {
		let queue = OperationQueue()
		queue.maxConcurrentOperationCount = 1
		return queue
	}()


	// Recover when host suspends and resumes app
	private var recoverableRouter: Router? // Used by host
	private var recoverableRouterHardwareAddress: String? // Used by client

	let changeSubject = PassthroughSubject<Change, Never>()

	@MainActor
	var thisDeviceName: String {
		get {
			networkSettings.bonjourName
		}
		set {
			set(name: newValue)
		}
	}

	// connectedPeers is used in two different ways depending on role:
	// Host: Clients that has joined the LAN group
	// Client: Available hosts
	private(set) var connectedPeers: [ConnectedPeer] = []

	private(set) var clientsInSameHostRoom: [Client] = [] // Only used when role is Client

	var selectedRouterPeer: ConnectedPeer? {
		guard case .otherDevice(let routerRawPeer) = routerResponsibiliyStatus,
			  let routerPeer = connectedPeers.first(where: { $0.id == routerRawPeer.id }) else {
			return nil
		}

		return routerPeer
	}

	private(set) var role: Role = .host

	@MainActor
	init() {
		role = networkSettings.bonjourRole
		start()

		NotificationCenter.default.addObserver(self, selector: #selector(appWillSuspend), name: UIScene.willDeactivateNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(appDidResume), name: UIScene.didActivateNotification, object: nil)
	}

	// MARK: - Public functions

	// MARK: Lifecycle

	@MainActor
	func start() {
		stop()

		guard networkSettings.serviceType == .bonjour else {
			return
		}

		let session = BonjourSession(
			discoveryInfo: [
				"peerName" : thisDeviceName,
				"hardwareAddress" : networkSettings.hardwareAddress.string,
				"role" : role.rawValue
			]
		)

		session.onReceive = { [weak self] data, peer in
			self?.handleReceive(data, from: peer)
		}

		session.onPeerDiscovery = { [weak self] peer in
			print("- onPeerDiscovery")
			print("\(peer.id)")
			print()
			self?.handlePeerDiscovery(peer)
		}

		session.onPeerLoss = { [weak self] peer in
			print("- onPeerLoss")
			print("\(peer.id)")
			print()
			self?.handlePeerDisconnection(peer)
		}

		session.onPeerConnection = { [weak self] peer in
			print("- onPeerConnection")
			print("\(peer.id)")
			print()
			self?.handlePeerConnection(peer)
		}

		session.onPeerDisconnection = { [weak self] peer in
			print("- onPeerDisconnection")
			print("\(peer.id) \(peer.isConnected)")
			self?.handlePeerDisconnection(peer)
		}

		if role == .host {
			becomeRouter()
		}

		self.session = session

		session.start()
	}

	func stop() {
		routerResponsibiliyStatus = .undecided
		connectedPeers = []
		clientsInSameHostRoom = []

		guard let session else {
			return
		}

		session.stop()
		session.disconnect()

		self.session = nil
	}

	// MARK: Router peer

	func pickRouterPeer(_ connectedPeer: ConnectedPeer) throws {
		guard let session,
			  connectedPeer.role == .host,
			  let rawPeer = session.availablePeers.first(where: { $0.id == connectedPeer.id }) else {
			throw BonjourManagerError.pickedRouterWasNotAvailable
		}

		routerResponsibiliyStatus = .otherDevice(rawPeer)
		recoverableRouterHardwareAddress = connectedPeer.hardwareAddress

		let payload = PocketShaverPayload(messageType: .didConnectToRouter)
		sendPayload(payload, to: rawPeer)
	}

	@MainActor
	func resetRouterPeer() {
		if let selectedRouterPeer {
			setAutojoin(for: selectedRouterPeer, enabled: false)
		}

		guard case .otherDevice(let rawRouterPeer) = routerResponsibiliyStatus else {
			return
		}

		routerResponsibiliyStatus = .undecided

		let payload = PocketShaverPayload(messageType: .didDisconnectFromRouter)
		sendPayload(payload, to: rawRouterPeer)
	}

	@MainActor
	func isAutojoinEnabled(for connectedPeer: ConnectedPeer) -> Bool {
		NetworkSettings.current.autojoinHardwareAddresses.contains(connectedPeer.hardwareAddress)
	}

	@MainActor
	func setAutojoin(for connectedPeer: ConnectedPeer, enabled: Bool) {
		var autojoinHardwareAddresses = networkSettings.autojoinHardwareAddresses
		if enabled {
			guard !autojoinHardwareAddresses.contains(connectedPeer.hardwareAddress) else {
				return
			}
			autojoinHardwareAddresses.insert(connectedPeer.hardwareAddress)
		} else {
			guard autojoinHardwareAddresses.contains(connectedPeer.hardwareAddress) else {
				return
			}
			autojoinHardwareAddresses.remove(connectedPeer.hardwareAddress)
		}

		networkSettings.set(autojoinHardwareAddresses: autojoinHardwareAddresses)
	}

	// MARK: Role

	@MainActor
	func set(role: Role) {
		guard session != nil,
			  self.role != role else {
			return
		}

		networkSettings.set(bonjourRole: role)
		self.role = role

		connectedPeers = []
		clientsInSameHostRoom = []
		changeSubject.send(.didReset)

		start()
	}

	// MARK: - Private functions

	// MARK: Bonjour session handlers

	private func handleReceive(_ data: Data, from peer: Peer) {
		if let payload = PocketShaverPayload(data: data) {
			handlePayload(payload, from: peer)
			return
		}

		switch routerResponsibiliyStatus {
		case .thisDevice(let router):
			if thisDeviceAddress.matchesHardwareAddress(in: data, atOffset: 0) {
				processReceiveData(data)
			} else {
				router.handle(data, from: peer)
			}
		case .otherDevice:
			guard thisDeviceAddress.matchesHardwareAddress(in: data, atOffset: 0) else {
				print("- got data that was not destined for this device")
				data.printHexString()

				return
			}

			processReceiveData(data)
		case .undecided:
			print("- got data before router was decided")
			data.printHexString()
		}
	}

	private func handlePeerDiscovery(_ peer: Peer) {
		guard let session else {
			return
		}
		session.inviteAvailablePeer(peer)
		print("- invited other peer isConnected \(peer.isConnected)")
	}

	private func handlePeerConnection(_ peer: Peer) {
		guard let connectedPeer = ConnectedPeer(peer),
			  !connectedPeers.contains(where: { $0.id == connectedPeer.id }),
			  role == .client,
			  connectedPeer.role == .host else {
			return
		}

		connectedPeers.append(connectedPeer)

		print("- did append available router")
		changeSubject.send(.connectedPeersDidChange)

		Task { @MainActor [weak self] in
			self?.autojoinIfEligible(connectedPeer)
		}
	}

	private func handlePeerDisconnection(_ peer: Peer) {
		if let index = connectedPeers.firstIndex(where: { $0.id == peer.id }) {

			connectedPeers.remove(at: index)
			changeSubject.send(.connectedPeersDidChange)

			if case .thisDevice(let router) = routerResponsibiliyStatus {
				router.handleDisconnectionFromPeer(peer)
			}

			sendUpdatedClientList()
			updateRouterResponsibilityStatus()
		}
	}


	// MARK: - Payload send / receive

	private func sendPayload(_ payload: PocketShaverPayload, to peer: Peer) {
		guard let data = payload.asData() else {
			print("- could not encode payload")
			return
		}

		print("- sendPayload \(payload.messageType.rawValue)")

		session?.send(data, to: [peer])
	}

	private func sendPayload(_ payload: PocketShaverPayload, to peers: [Peer]) {
		for peer in peers {
			sendPayload(payload, to: peer)
		}
	}

	private func sendPayload(_ payload: PocketShaverPayload, to connectedPeers: [ConnectedPeer]) {
		guard let session else {
			return
		}
		let rawPeers = connectedPeers.compactMap({ connectedPeer in
			session.availablePeers.first(where: { $0.id == connectedPeer.id })
		})
		sendPayload(payload, to: rawPeers)
	}

	private func handlePayload(_ payload: PocketShaverPayload, from peer: Peer) {
		print("- handlePayload \(payload.messageType.rawValue)")
		switch payload.messageType {
		case .didConnectToRouter:
			if case .thisDevice(let router) = routerResponsibiliyStatus {
				guard let connectedPeer = ConnectedPeer(peer),
					  !connectedPeers.contains(where: { $0.id == connectedPeer.id }) else {
					return
				}

				connectedPeers.append(connectedPeer)

				router.handleConnectedToPeer(peer)

				print("- did append connected client")
				changeSubject.send(.connectedPeersDidChange)

				sendUpdatedClientList()
			}
		case .didDisconnectFromRouter:
			if let index = connectedPeers.firstIndex(where: { $0.id == peer.id }) {
				connectedPeers.remove(at: index)

				changeSubject.send(.connectedPeersDidChange)

				sendUpdatedClientList()
			}
		case .updatedConnectedPeerNames:
			if role == .client {
				guard case .otherDevice(let routerPeer) = routerResponsibiliyStatus,
					  routerPeer.id == peer.id else {
					return
				}

				print("- updated clientsInSameHostRoom")

				clientsInSameHostRoom = payload.connectedPeerNames
				changeSubject.send(.clientsInSameHostRoomDidChange)
			}
		case .didUpdateName:
			guard let newPeerName = payload.name,
				  let session else {
				return
			}

			session.updateName(of: peer, withName: newPeerName)

			if case .otherDevice(let routerPeer) = routerResponsibiliyStatus,
			   peer.id == routerPeer.id {
				routerResponsibiliyStatus = .otherDevice(peer.withName(newPeerName))
			}

			if let index = connectedPeers.firstIndex(where: { $0.id == peer.id }) {
				connectedPeers[index] = connectedPeers[index].withName(newPeerName)

				let hardwareAddress = connectedPeers[index].hardwareAddress
				changeSubject.send(.connectedPeersDidChange)

				if let index = clientsInSameHostRoom.firstIndex(where: { $0.hardwareAddress == hardwareAddress }) {
					clientsInSameHostRoom[index] = clientsInSameHostRoom[index].withName(newPeerName)

					changeSubject.send(.clientsInSameHostRoomDidChange)
				}

				sendUpdatedClientList()
			}
		}
	}

	// MARK: Other private functions

	@MainActor
	private func set(name: String) {
		networkSettings.set(bonjourName: name)

		guard let session else {
			return
		}

		session.updatePeerNameAndRecreateAdvertiser(name)

		let payload = PocketShaverPayload(messageType: .didUpdateName, name: name)
		sendPayload(payload, to: Array(session.availablePeers))
	}

	fileprivate func sendToRouter(_ data: Data) {
		switch routerResponsibiliyStatus {
		case .thisDevice(let router):
			let dataCopy = Data(data) // Since allocated with "no copy" earlier
			DispatchQueue.global().async {
				router.handle(dataCopy, from: nil)
			}
		case .otherDevice(let peer):
			session?.send(data, to: [peer])
		case .undecided:
			// Have to connect to router first
			break
		}
	}

	private func processReceiveData(_ data: Data) {
		let operation = BlockOperation()
		operation.addExecutionBlock {
			if Thread.isMainThread {
				fatalError()
			}
			objc_bonjourReceiveData(data)
		}

		dataRecieveQueue.addOperation(operation)
	}

	private func sendUpdatedClientList() {
		guard role == .host else {
			return
		}

		let clientsInSameHostRoom = connectedPeers.map {
			Client(name: $0.name, hardwareAddress: $0.hardwareAddress)
		}

		let payload = PocketShaverPayload(
			messageType: .updatedConnectedPeerNames,
			connectedPeerNames: clientsInSameHostRoom
		)
		sendPayload(payload, to: connectedPeers)
	}

	private func updateRouterResponsibilityStatus() {
		if case .otherDevice(let routerPeer) = routerResponsibiliyStatus {
			guard let session,
				  session.availablePeers.contains(routerPeer) else {
				routerResponsibiliyStatus = .undecided
				changeSubject.send(.didDisconnectFromRouter)
				return
			}
		}
	}

	@MainActor
	private func autojoinIfEligible(_ connectedPeer: ConnectedPeer) {
		guard case .undecided = routerResponsibiliyStatus else {
			return
		}

		if networkSettings.autojoinHardwareAddresses.contains(connectedPeer.hardwareAddress) ||
			connectedPeer.hardwareAddress == recoverableRouterHardwareAddress {
			try? pickRouterPeer(connectedPeer)

			changeSubject.send(.didAutojoinRouterPeer)
		}
	}

	private func becomeRouter() {
		if let recoverableRouter {
			// App has re-entered foreground
			print("- did recover router")
			routerResponsibiliyStatus = .thisDevice(recoverableRouter)
			self.recoverableRouter = nil
			return
		}

		routerResponsibiliyStatus = .thisDevice(.init(sendToPeer: { [weak self] data, peer in
			self?.session?.send(data, to: [peer])
		}))
	}

	// MARK: - Lifecycle listeners

	@objc
	private func appWillSuspend() {
		if case .thisDevice(let router) = routerResponsibiliyStatus {
			recoverableRouter = router
		}
		stop()
	}

	@objc
	private func appDidResume() {
		Task { @MainActor [weak self] in
			self?.start()
		}
	}
}

// MARK: - PocketShaver payload

private struct PocketShaverPayload: Codable {
	enum MessageType: String, Codable {
		case didConnectToRouter
		case didDisconnectFromRouter
		case updatedConnectedPeerNames
		case didUpdateName
	}

	private static let magicCookie = HardwareAddress(0x7c, 0x48, 0xc8, 0xb0, 0xa8, 0x3f)

	let messageType: MessageType
	let connectedPeerNames: [BonjourManager.Client]
	let name: String?

	init(
		messageType: MessageType,
		connectedPeerNames: [BonjourManager.Client] = [],
		name: String? = nil
	) {
		self.messageType = messageType
		self.connectedPeerNames = connectedPeerNames
		self.name = name
	}

	init?(
		data: Data
	) {
		guard Self.magicCookie.matchesHardwareAddress(in: data, atOffset: 0) else {
			// This guard catches all Bonjour data packages received by the device which
			// is not a PocketShaverPayload. Do not add expensive operations here.
			return nil
		}

		do {
			self = try decoder.decode(
				PocketShaverPayload.self,
				from: data[6..<data.count]
			)
		} catch {
			print("- could not decode payload")
			return nil
		}
	}

	func asData() -> Data? {
		guard let payloadData = try? encoder.encode(self) else {
			return nil
		}

		return Self.magicCookie.asData + payloadData
	}
}

// MARK: Router

private class Router {
	private let broadcastAddress = HardwareAddress(0xff, 0xff, 0xff, 0xff, 0xff, 0xff)
	private let routerIpAddress = IpAddress(10, 8, 0, 100)
	private lazy var routerHardwareAddress = {
		NetworkSettingsCachedSettings.routerHardwareAddress!
	}()

	private var addressAssignments = [HardwareAddress: IpAddress]()
	private var peerTable = [HardwareAddress: Peer]()

	private let sendToPeer: ((Data, Peer) -> Void)

	enum RouterResponsibilityMessageType {
		case bootDiscover
		case bootRequest
		case arpRequest
		case unknown
	}

	private var nextLeastSignificantNumber: UInt8 = 2

	init(
		sendToPeer: @escaping ((Data, Peer) -> Void)
	) {
		self.sendToPeer = sendToPeer
	}

	func handle(_ data: Data, from sourcePeer: Peer?) {
		switch routerResponsibilityMessageType(in: data) {
		case .bootDiscover:
			handleBootDiscover(data, from: sourcePeer)
			return
		case .bootRequest:
			handleBootRequest(data, from: sourcePeer)
			return
		case .arpRequest:
			handleArpRequest(data, from: sourcePeer)
			return
		default:
			break
		}

		guard let destinationAddress = HardwareAddress.fromData(in: data, atOffset: 0),
			  let destinationPeer = peerTable[destinationAddress] else {
			print("- Did not have a peer for destination")
			data.printHexString()
			return
		}

		sendToPeer(data, destinationPeer)
	}

	func handleConnectedToPeer(_ peer: Peer) {
		guard let discoveryInfo = peer.discoveryInfo,
			  let hardwareAddressString = discoveryInfo["hardwareAddress"],
			let hardwareAddress = HardwareAddress(hardwareAddressString) else {
			return
		}

		print("- router added client \(hardwareAddressString) to peer list")
		peerTable[hardwareAddress] = peer

	}

	func handleDisconnectionFromPeer(_ peer: Peer) {
		guard let key = peerTable.keys.filter({ peerTable[$0] == peer }).first else {
			return
		}

		print("- router removed disconnected client from peer list")
		peerTable[key] = nil
		peerTable[key] = nil
}

	private func routerResponsibilityMessageType(in data: Data) -> RouterResponsibilityMessageType {
		guard broadcastAddress.matchesHardwareAddress(in: data, atOffset: 0) ||
				routerHardwareAddress.matchesHardwareAddress(in: data, atOffset: 0) else {
			return .unknown
		}

		if data.count >= 42,
		   data[12] == 0x08,
		   data[13] == 0x06,
		   data[20] == 0x00,
		   data[21] == 0x01 {
			return .arpRequest
		}

		guard broadcastAddress.matchesHardwareAddress(in: data, atOffset: 0),
			  data.count >= 285,
			  data[282] == 0x35,
			  data[283] == 0x01 else {
			return .unknown
		}

		if data[284] == 0x01 {
			return .bootDiscover
		} else if data[284] == 0x03 {
			return .bootRequest
		}

		return .unknown
	}

	private func handleBootDiscover(_ data: Data, from peer: Peer?) {
		guard let hardwareAddress = HardwareAddress.fromData(in: data, atOffset: 6) else {
			print("- Could not parse hardware address")
			return
		}

		peerTable[hardwareAddress] = peer

		let thisDeviceIsRequesting = peer == nil

		var offeredIpAddress: IpAddress!
		if thisDeviceIsRequesting {
			// Device being router always gets 10.8.0.1. For convenience.
			offeredIpAddress = .init(10, 8, 0, 1)
		} else {
			while true {
				offeredIpAddress = .init(10, 8, 0, nextLeastSignificantNumber)
				nextLeastSignificantNumber += 1

				if offeredIpAddress != routerIpAddress,
				   !addressAssignments.values.contains(offeredIpAddress) {
					break
				}
			}
		}

		addressAssignments[hardwareAddress] = offeredIpAddress
		print("- DHCP disover reply: \(hardwareAddress.string) gets ip address \(offeredIpAddress.string)")

		objc_sendBootReply(data, routerIpAddress, offeredIpAddress, thisDeviceIsRequesting, false)
	}

	private func handleBootRequest(_ data: Data, from peer: Peer?) {
		guard let hardwareAddress = HardwareAddress.fromData(in: data, atOffset: 6) else {
			print("- Could not parse hardware address")
			return
		}

		peerTable[hardwareAddress] = peer

		guard let offeredIpAddress = addressAssignments[hardwareAddress] else {
			print("- Had no offered ip address")
			return
		}

		let thisDeviceIsRequesting = peer == nil

		print("- DHCP request reply: \(hardwareAddress.string) gets ip address \(offeredIpAddress.string)")

		objc_sendBootReply(data, routerIpAddress, offeredIpAddress, thisDeviceIsRequesting, true)
	}

	private func handleArpRequest(_ data: Data, from peer: Peer?) {
		print("- handleArpRequest")
		guard let requestedIpAddress = IpAddress.fromData(in: data, atOffset: 38) else {
			print("- got malformatted arp request")
			data.printHexString()
			return
		}

		guard let requestedHardwareAddress = addressAssignments.keys.first(where: {addressAssignments[$0] == requestedIpAddress }) else {
			print("- did not have mapping")
			return
		}

		let thisDeviceIsRequesting = peer == nil

		objc_sendArpReply(data, requestedHardwareAddress.asData, thisDeviceIsRequesting)
	}
}

// MARK: - Obj-C proxy

@objcMembers
class BonjourManagerObjCProxy: NSObject {
	static func sendToRouter(_ data: Data) {
		BonjourManager.shared.sendToRouter(data)
	}
}

// MARK: - Extensions

private extension ConnectedPeer {
	init?(_ rawPeer: Peer) {
		guard let discoveryInfo = rawPeer.discoveryInfo,
			  let name = discoveryInfo["peerName"],
			  let hardwareAddress = discoveryInfo["hardwareAddress"],
			  let roleString = discoveryInfo["role"],
			  let role = BonjourManager.Role(rawValue: roleString) else {
			return nil
		}

		self = .init(
			id: rawPeer.id,
			name: name,
			hardwareAddress: hardwareAddress,
			role: role
		)
	}
}

extension ConnectedPeer {
	func withName(_ name: String) -> Self {
		.init(
			id: id,
			name: name,
			hardwareAddress: hardwareAddress,
			role: role
		)
	}
}

extension BonjourManager.Client {
	@MainActor
	var isThisDevice: Bool {
		hardwareAddress == NetworkSettings.current.hardwareAddress.string
	}

	func withName(_ name: String) -> Self {
		.init(
			name: name,
			hardwareAddress: hardwareAddress
		)
	}
}
