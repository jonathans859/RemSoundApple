import CryptoKit
@testable import RemSoundKit
import XCTest

/// Pins the tick proof (packet 11) to upstream's own known answers
/// (`SelfTest.KnownAnswers.cs` / `SelfTest.CrossPort.cs`): "the iPhone and Android apps send
/// and read it by this number", at 53 bytes, version 1, time little-endian, id big-endian.
final class TickProofTests: XCTestCase {
    private let key = [UInt8](repeating: 0x42, count: 32)
    private let otherKey = [UInt8](repeating: 0x24, count: 32)
    private let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    private let when: Int64 = 1_790_000_000

    /// Upstream's `tickPlain`, byte for byte.
    private let upstreamPlain: [UInt8] = [0x01,
        0x80, 0x3B, 0xB1, 0x6A, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]

    /// Seal in the wire's nonce ‖ tag ‖ ciphertext order without going through `TickProof`,
    /// as a port that builds it by hand would.
    private func sealByHand(_ plain: [UInt8], key: [UInt8]) throws -> [UInt8] {
        let box = try AES.GCM.seal(Data(plain), using: SymmetricKey(data: key))
        return [UInt8](box.nonce) + [UInt8](box.tag) + [UInt8](box.ciphertext)
    }

    func testOurPlaintextIsUpstreamsLayout() {
        XCTAssertEqual(TickProof.plaintext(instanceId: id, unixSeconds: when), upstreamPlain)
    }

    func testOurSealIsFiftyThreeBytesAndOpensByHand() throws {
        let sealed = try XCTUnwrap(TickProof.seal(key: key, plaintext: upstreamPlain))
        XCTAssertEqual(sealed.count, 53)
        // Open it the way the other ports do: nonce, then tag, then ciphertext.
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(sealed[0..<12])),
                                        ciphertext: Data(sealed[28...]), tag: Data(sealed[12..<28]))
        XCTAssertEqual([UInt8](try AES.GCM.open(box, using: SymmetricKey(data: key))), upstreamPlain)
    }

    func testTheirProofOpensToTheSameIdAndTime() throws {
        let opened = try XCTUnwrap(TickProof.open(key: key, payload: try sealByHand(upstreamPlain, key: key)[...]))
        XCTAssertEqual(opened.instanceId, id)
        XCTAssertEqual(opened.unixSeconds, when)
    }

    func testAnotherPasswordOrATamperedProofDoesNotOpen() throws {
        var sealed = try sealByHand(upstreamPlain, key: key)
        XCTAssertNil(TickProof.open(key: otherKey, payload: sealed[...]))
        sealed[40] ^= 1
        XCTAssertNil(TickProof.open(key: key, payload: sealed[...]))
    }

    func testAnUnknownVersionOrWrongSizeIsRefused() throws {
        var plain = upstreamPlain
        plain[0] = 2
        XCTAssertNil(TickProof.open(key: key, payload: try sealByHand(plain, key: key)[...]))
        XCTAssertNil(TickProof.open(key: key, payload: try sealByHand(upstreamPlain + [0], key: key)[...]))
    }

    func testThePacketIsTypeElevenOnTheHeartbeatStream() throws {
        let packet = try XCTUnwrap(TickProof.buildPacket(key: key, instanceId: id, unixSeconds: when, sequence: 7))
        XCTAssertEqual(packet.count, RemPacket.headerSize + 53)
        let header = try XCTUnwrap(RemPacket.readHeader(packet, length: packet.count))
        XCTAssertEqual(header.type, .tickProof)
        XCTAssertEqual(packet[5], 11)
        XCTAssertEqual(header.streamId, 0xFFFF)
        XCTAssertEqual(TickProof.open(key: key, payload: packet[RemPacket.headerSize...])?.instanceId, id)
    }

    // MARK: - The guard

    private var now: Date { Date(timeIntervalSince1970: TimeInterval(when)) }

    func testGuardAcceptsOnceAndRefusesTheReplay() throws {
        var guardian = TickProofGuard()
        let sealed = try XCTUnwrap(TickProof.seal(key: key, plaintext: upstreamPlain))
        XCTAssertEqual(guardian.check(key: key, payload: sealed[...], now: now), .accepted(id))
        XCTAssertEqual(guardian.check(key: key, payload: sealed[...], now: now), .replay,
                       "a captured proof, replayed from anywhere, proves nothing")
        // A fresh seal of the same content is a new packet, as the sender's next one is.
        let next = try XCTUnwrap(TickProof.seal(key: key, plaintext: upstreamPlain))
        XCTAssertEqual(guardian.check(key: key, payload: next[...], now: now), .accepted(id))
    }

    func testGuardAllowsTenMinutesOfClockSkewEitherWay() throws {
        var guardian = TickProofGuard()
        let sealed = { try XCTUnwrap(TickProof.seal(key: self.key, plaintext: self.upstreamPlain)) }
        XCTAssertEqual(guardian.check(key: key, payload: try sealed()[...], now: now.addingTimeInterval(590)), .accepted(id))
        XCTAssertEqual(guardian.check(key: key, payload: try sealed()[...], now: now.addingTimeInterval(-590)), .accepted(id))
        XCTAssertEqual(guardian.check(key: key, payload: try sealed()[...], now: now.addingTimeInterval(601)), .stale)
        XCTAssertEqual(guardian.check(key: key, payload: try sealed()[...], now: now.addingTimeInterval(-601)), .stale)
    }

    func testGuardReportsAnotherPassword() throws {
        var guardian = TickProofGuard()
        let sealed = try XCTUnwrap(TickProof.seal(key: otherKey, plaintext: upstreamPlain))
        XCTAssertEqual(guardian.check(key: key, payload: sealed[...], now: now), .notOurPassword)
    }

    // MARK: - The engine hands proofs on, sparingly

    func testTheEngineHandsOnAProofAtMostOnceEveryTwoSecondsPerAddress() throws {
        let engine = AudioReceiverEngine()
        var heard: [UDPEndpoint] = []
        engine.onTickProofReceived = { _, remote in heard.append(remote) }
        let packet = try XCTUnwrap(TickProof.buildPacket(key: key, instanceId: id, unixSeconds: when, sequence: 1))
        let a = UDPEndpoint(host: "192.168.1.50", port: 47830)!
        let b = UDPEndpoint(host: "192.168.1.51", port: 47830)!
        for _ in 0..<5 { engine.handlePacketForTesting(packet, from: a) }
        engine.handlePacketForTesting(packet, from: b)
        XCTAssertEqual(heard, [a, b])
    }

    /// Like the address check, a proof is not gated by the allow-list or by receiving being
    /// on: it is about the other end listening to US.
    func testAProofIsHandedOnWhateverTheAllowListAndReceiveSwitchSay() throws {
        let engine = AudioReceiverEngine()
        engine.setAllowedSenders([])
        engine.setPlaybackEnabled(false)
        var heard = 0
        engine.onTickProofReceived = { _, _ in heard += 1 }
        let packet = try XCTUnwrap(TickProof.buildPacket(key: key, instanceId: id, unixSeconds: when, sequence: 1))
        engine.handlePacketForTesting(packet, from: UDPEndpoint(host: "10.0.0.9", port: 47830)!)
        XCTAssertEqual(heard, 1)
    }
}

/// Discovery input hardening (upstream `TryParseAnnouncement`, 6.0).
final class DiscoveryHardeningTests: XCTestCase {
    private func announce(_ service: PeerDiscoveryService, id: UUID, name: String = "PC",
                          port: Int = 47830) throws {
        let message = DiscoveryMessage(InstanceId: id, Name: name, AudioPort: port,
                                       CanSend: true, CanReceive: true)
        let bytes = [UInt8](try JSONEncoder().encode(message))
        service.handleAnnouncement(buffer: bytes, length: bytes.count,
                                   remote: UDPEndpoint(address: 0x0101A8C0, port: 47821))
    }

    func testAnAllZeroIdIsIgnored() throws {
        let service = PeerDiscoveryService()
        try announce(service, id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        XCTAssertTrue(service.currentPeers.isEmpty)
    }

    func testAPortNobodyCanBeReachedOnIsIgnored() throws {
        let service = PeerDiscoveryService()
        try announce(service, id: UUID(), port: 0)
        try announce(service, id: UUID(), port: 70_000)
        XCTAssertTrue(service.currentPeers.isEmpty)
    }

    func testALongNameIsCapped() throws {
        let service = PeerDiscoveryService()
        try announce(service, id: UUID(), name: String(repeating: "x", count: 500))
        XCTAssertEqual(service.currentPeers.first?.name.count, 128)
    }
}
