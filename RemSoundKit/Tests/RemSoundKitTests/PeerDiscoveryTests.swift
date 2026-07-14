import XCTest
@testable import RemSoundKit

/// Pins the multi-homed peer behaviour: one Windows instance reachable over several paths
/// (LAN + VPN) announces from several source addresses. The peer must stay ONE entry with a
/// stable primary address — the old one-address-per-instance model flapped between paths on
/// every alternating announcement, churning the allow-list, heartbeat state, and row identity.
final class PeerDiscoveryTests: XCTestCase {
    private let lanAddress: UInt32 = 0x0101A8C0   // 192.168.1.1 in network byte order
    private let vpnAddress: UInt32 = 0x01010A0A   // 10.10.1.1

    private func announce(_ service: PeerDiscoveryService, instanceId: UUID,
                          name: String = "PC", from address: UInt32) throws {
        let message = DiscoveryMessage(
            InstanceId: instanceId, Name: name, AudioPort: 47830, CanSend: true, CanReceive: false)
        let bytes = [UInt8](try JSONEncoder().encode(message))
        service.handleAnnouncement(buffer: bytes, length: bytes.count,
                                   remote: UDPEndpoint(address: address, port: 47821))
    }

    func testMultiHomedPeerIsOneEntryWithAllAddresses() throws {
        let service = PeerDiscoveryService()
        let id = UUID()

        try announce(service, instanceId: id, from: lanAddress)
        try announce(service, instanceId: id, from: vpnAddress)

        let peers = service.currentPeers
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers[0].addresses, [lanAddress, vpnAddress])
        XCTAssertEqual(peers[0].address, lanAddress) // primary = first seen
        XCTAssertEqual(peers[0].audioEndpoints.map(\.port), [47830, 47830])
    }

    func testAlternatingAnnouncementsDoNotFlapOrNotify() throws {
        let service = PeerDiscoveryService()
        let id = UUID()
        var changeNotifications = 0
        service.onPeersChanged = { changeNotifications += 1 }

        try announce(service, instanceId: id, from: lanAddress)
        try announce(service, instanceId: id, from: vpnAddress)
        XCTAssertEqual(changeNotifications, 2) // new peer, then a new path

        // The steady state: both paths keep announcing on the 1.5 s cadence.
        for _ in 0..<5 {
            try announce(service, instanceId: id, from: lanAddress)
            try announce(service, instanceId: id, from: vpnAddress)
        }
        XCTAssertEqual(changeNotifications, 2) // repeats must not fire change events
        XCTAssertEqual(service.currentPeers[0].address, lanAddress) // primary never rotated
    }

    func testDistinctInstancesStaySeparate() throws {
        let service = PeerDiscoveryService()

        try announce(service, instanceId: UUID(), name: "PC one", from: lanAddress)
        try announce(service, instanceId: UUID(), name: "PC two", from: vpnAddress)

        XCTAssertEqual(service.currentPeers.count, 2)
    }

    // Battery finding 4: an auto-learned announcement source is a unicast target only while
    // it keeps announcing — it must expire once the peer goes quiet, so we stop transmitting
    // our 1.5 s announcement to a vanished IP. A user-provided (manual/selected) peer never
    // expires, even while quiet.
    func testLearnedUnicastTargetExpiresButProvidedDoesNot() throws {
        let service = PeerDiscoveryService()
        service.setUnicastPeerAddresses([vpnAddress]) // provided — never expires

        try announce(service, instanceId: UUID(), from: lanAddress) // learned, stamped ~now
        let now = Date()

        // Both present while the learned source is fresh.
        XCTAssertEqual(Set(service.unicastTargets(asOf: now)), [lanAddress, vpnAddress])

        // Past the 8 s peer-expiry window the learned one is pruned; the provided one stays.
        XCTAssertEqual(service.unicastTargets(asOf: now.addingTimeInterval(9)), [vpnAddress])
    }

    func testAllLearnedTargetsExpireWhenPeersGoQuiet() throws {
        let service = PeerDiscoveryService()
        try announce(service, instanceId: UUID(), from: lanAddress)
        try announce(service, instanceId: UUID(), from: vpnAddress)

        XCTAssertEqual(Set(service.unicastTargets(asOf: Date())), [lanAddress, vpnAddress])
        XCTAssertTrue(service.unicastTargets(asOf: Date().addingTimeInterval(9)).isEmpty)
    }
}
