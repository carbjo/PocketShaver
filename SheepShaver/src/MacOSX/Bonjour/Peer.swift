import Foundation
import MultipeerConnectivity
import CommonCrypto

struct Peer: Hashable, Identifiable {
    let id: String
    let discoveryInfo: [String: String]?
    let peerID: MCPeerID
    var isConnected: Bool

    init(peer: MCPeerID, discoveryInfo: [String: String]?) throws {
        /**
         According to Apple's docs, every MCPeerID is unique, therefore encoding it
         and hashing the resulting data is a good way to generate an unique identifier
         that will be always the same for the same peer ID.
         */
        let peerData = try NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true)
        self.id = peerData.idHash

        self.peerID = peer
        self.discoveryInfo = discoveryInfo
        self.isConnected = false
    }

	fileprivate init(
		id: String,
		discoveryInfo: [String: String]?,
		peerID: MCPeerID,
		isConnected: Bool
	) {
		self.id = id
		self.discoveryInfo = discoveryInfo
		self.peerID = peerID
		self.isConnected = isConnected
	}
}

fileprivate extension Data {
    var idHash: String {
        var sha1 = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(count), &sha1) }
        return sha1.map({ String(format: "%02hhx", $0) }).joined()
    }
}

extension Peer {
	func withName(_ name: String) -> Self {
		var discoveryInfo = self.discoveryInfo
		discoveryInfo?["peerName"] = name
		
		return .init(
			id: id,
			discoveryInfo: discoveryInfo,
			peerID: peerID,
			isConnected: isConnected
		)
	}
}
