@testable import RemSoundKit
import XCTest

/// Pins how this app behaves as one member of a group on a RemSound server: when it joins,
/// what it sends, who it credits an arriving packet to, and — the part upstream paid for
/// twice — what it lets go of when the server stops answering.
final class RelayGroupClientTests: XCTestCase {
    private let server = UDPEndpoint(host: "198.51.100.7", port: RemPacket.defaultPort)!
    private let elsewhere = UDPEndpoint(host: "203.0.113.9", port: RemPacket.defaultPort)!
    private let tag: [UInt8] = [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8]
    private let otherTag: [UInt8] = [0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8]
    private let ed = RelayClientId(bytes: Array(repeating: 0x11, count: 16))!
    private let chris = RelayClientId(bytes: Array(repeating: 0x22, count: 16))!

    /// Everything the client handed to the socket, in order.
    private final class Wire {
        var sent: [(packet: [UInt8], to: UDPEndpoint)] = []
        var types: [UInt8] { sent.map { $0.packet[5] } }
        func clear() { sent.removeAll() }
    }

    private func makeClient(password: [UInt8]? = nil, connect: Bool = false)
        -> (RelayGroupClient, Wire) {
        let client = RelayGroupClient(clientId: .random())
        let wire = Wire()
        client.rawTransport = { packet, destination in
            wire.sent.append((packet, destination))
            return true
        }
        client.setIdentity(name: "iPhone", passwordFingerprint: password ?? tag)
        if connect { client.connect(to: server) }
        return (client, wire)
    }

    private func rosterPacket(_ entries: [(RelayClientId, String, Bool)],
                              listFlags: UInt8 = 0) -> [UInt8] {
        let serverId = RelayClientId(bytes: Array(repeating: 0, count: 16))!
        var packet = [UInt8](RelayGroup.writeHeader(type: .lobbyRoster, streamId: 0,
                                                    sequence: 0, clientId: serverId))
        packet.append(UInt8(entries.count))
        for (id, name, ticksUs) in entries {
            packet.append(contentsOf: id.bytes)
            packet.append(contentsOf: RelayGroup.encodeName(name))
            packet.append(ticksUs ? 1 : 0)
        }
        packet.append(listFlags)
        return packet
    }

    private func groupPacket(from id: RelayClientId, type: RemPacketType,
                             streamId: UInt16 = 5, payload: [UInt8]) -> [UInt8] {
        var packet = [UInt8](RelayGroup.writeHeader(type: type, streamId: streamId,
                                                    sequence: 1, clientId: id))
        packet.append(contentsOf: payload)
        return packet
    }

    private func ordinaryPacket(type: RemPacketType, sequence: UInt32 = 1,
                                payload: [UInt8] = []) -> [UInt8] {
        var packet = [UInt8](RemPacket.writeHeader(type: type, streamId: 3, sequence: sequence))
        packet.append(contentsOf: payload)
        return packet
    }

    @discardableResult
    private func joinGroup(_ client: RelayGroupClient, _ wire: Wire,
                           members: [(RelayClientId, String, Bool)] = [],
                           listFlags: UInt8 = 0) -> Bool {
        let packet = rosterPacket(members, listFlags: listFlags)
        _ = client.handleInbound(packet, length: packet.count, remote: server)
        wire.clear()
        return client.isInGroup
    }

    // MARK: - The safety rail

    /// A server is somewhere you go. Until the user has asked to connect to one, nothing on
    /// this path does anything at all.
    func testNothingHappensWithoutConnect() {
        let (client, wire) = makeClient()
        client.tick()
        XCTAssertTrue(wire.sent.isEmpty, "no hello to a server we were never told about")
        XCTAssertNil(client.connectedServer)
        XCTAssertFalse(client.isInGroup)

        let packet = rosterPacket([(ed, "Ed", true)])
        guard case .notGroup = client.handleInbound(packet, length: packet.count, remote: server) else {
            return XCTFail("a roster from a server we have not connected to is not ours")
        }
        XCTAssertTrue(client.members.isEmpty)
    }

    /// The rule that keeps old and new together: until a member list has arrived, every
    /// packet goes exactly as it always has. `route` returning false is what "unchanged"
    /// means here — the caller sends it itself, ordinary framing, straight to the address.
    func testBeforeTheFirstRosterEverythingTakesTheOrdinaryPath() {
        let (client, _) = makeClient(connect: true)
        for type in [RemPacketType.audio, .format, .heartbeat, .control] {
            XCTAssertFalse(client.route(ordinaryPacket(type: type), to: server, send: { _, _ in true }),
                           "\(type) must go the ordinary way until we are in a group")
        }
    }

    /// And it switches back off. A server that stops answering leaves us an ordinary pair
    /// client again, which is the only state that can still reach anybody.
    func testGroupGoesColdWhenTheListsStop() {
        let (client, wire) = makeClient(connect: true)
        var events: [String] = []
        client.onEvent = { events.append($0.message) }
        XCTAssertTrue(joinGroup(client, wire, members: [(ed, "Ed", true)]))

        client.backdateRosterForTesting(by: RelayGroup.rosterAliveFor + 1)
        client.tick()
        XCTAssertFalse(client.isInGroup)
        XCTAssertTrue(events.contains { $0.contains("ordinary pair again") })
        XCTAssertFalse(client.route(ordinaryPacket(type: .audio), to: server, send: { _, _ in true }))
    }

    /// Upstream's sting, and the reason `forgetServerLocked` clears everything rather than
    /// only what is on screen: a member exists *only* because a member list said so, and a
    /// member only gets added when a list names somebody we have not already got. Keep half
    /// of one and that person can never be listed again when the server comes back.
    func testAMemberKeptPastTheColdGroupCouldNeverComeBack() {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [(ed, "Ed", false)])
        XCTAssertEqual(client.members.map(\.name), ["Ed"])

        client.backdateRosterForTesting(by: RelayGroup.rosterAliveFor + 1)
        client.tick()
        XCTAssertTrue(client.members.isEmpty, "the people go with the server")

        // The server is back, listing the same person. They must appear again.
        var events: [String] = []
        client.onEvent = { events.append($0.message) }
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        XCTAssertEqual(client.members.map(\.name), ["Ed"])
        XCTAssertTrue(client.members[0].ticksUs)
        XCTAssertTrue(events.contains { $0.contains("Ed joined the group") })
    }

    // MARK: - Hello

    func testHelloIsSentOnConnectAndThenEveryTwoSeconds() throws {
        let (client, wire) = makeClient(connect: true)
        client.tick()
        let first = try XCTUnwrap(wire.sent.first)
        XCTAssertEqual(first.to, server)
        XCTAssertEqual(first.packet[4], 2)
        XCTAssertEqual(first.packet[5], 6, "hello")
        XCTAssertEqual(Array(first.packet[28..<36]), [UInt8]("iPhone".utf8) + [0, 0])
        XCTAssertEqual(Array(first.packet[60..<68]), tag, "the group tag is our fingerprint")

        wire.clear()
        client.tick()
        XCTAssertTrue(wire.sent.isEmpty, "not due yet")
        client.backdateHelloForTesting(by: RelayGroup.helloInterval)
        client.tick()
        XCTAssertEqual(wire.sent.count, 1)
    }

    /// The server groups by the password tag and nothing else, so with no password there is
    /// no group to join — and the user has to be told, because the server list would
    /// otherwise just sit there empty with no explanation.
    func testNoPasswordMeansNoHelloButAnExplanation() {
        let client = RelayGroupClient(clientId: .random())
        let wire = Wire()
        client.rawTransport = { packet, to in
            wire.sent.append((packet, to))
            return true
        }
        var events: [String] = []
        client.onEvent = { events.append($0.message) }
        client.setIdentity(name: "iPhone", passwordFingerprint: nil)
        client.connect(to: server)
        client.tick()
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertTrue(events.contains { $0.contains("set a password") })
    }

    /// Ticking somebody has to reach the server at once — it is what decides who hears whom,
    /// and waiting out the 2 s cadence is two seconds of silence the user is watching.
    func testTickingSomebodyResendsTheHelloImmediately() throws {
        let (client, wire) = makeClient(connect: true)
        client.tick()
        wire.clear()
        client.setTicked([ed], pairPartner: false)
        let hello = try XCTUnwrap(wire.sent.first)
        XCTAssertEqual(hello.packet[5], 6)
        XCTAssertEqual(hello.packet[68], 1, "one id in the tick list")
        XCTAssertEqual(Array(hello.packet[69..<85]), ed.bytes)

        // Setting the same thing again says nothing: the 2 s cadence covers it.
        wire.clear()
        client.setTicked([ed], pairPartner: false)
        XCTAssertTrue(wire.sent.isEmpty)
    }

    /// A new password is a new group. The spec is explicit: resend the hello at once with
    /// the new tag and an **empty** tick list, and drop everyone you had ticked — the ids
    /// mean nothing in the group we are about to land in.
    func testChangingPasswordStartsANewGroupWithNoTicks() throws {
        let (client, wire) = makeClient(connect: true)
        client.tick()
        client.setTicked([ed, chris], pairPartner: true)
        joinGroup(client, wire, members: [(ed, "Ed", true)])

        client.setIdentity(name: "iPhone", passwordFingerprint: otherTag)
        let hello = try XCTUnwrap(wire.sent.first { $0.packet[5] == 6 })
        XCTAssertEqual(Array(hello.packet[60..<68]), otherTag)
        XCTAssertEqual(hello.packet[68], 0, "nobody is ticked in a group we have just joined")
    }

    func testDisconnectSaysGoodbyeAndEmptiesTheList() throws {
        let (client, wire) = makeClient(connect: true)
        client.tick() // the hello that registers us
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        client.disconnect()
        let bye = try XCTUnwrap(wire.sent.first)
        XCTAssertEqual(bye.packet[5], 9)
        XCTAssertEqual(bye.packet.count, 28, "a bye is a header and nothing else")
        XCTAssertNil(client.connectedServer)
        XCTAssertTrue(client.members.isEmpty)
        XCTAssertFalse(client.isInGroup)
    }

    /// Connecting somewhere else leaves the first server — one at a time, and the people
    /// from the old one must not linger.
    func testConnectingElsewhereLeavesTheFirstServer() {
        let (client, wire) = makeClient(connect: true)
        client.tick()
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        client.connect(to: elsewhere)
        XCTAssertEqual(client.connectedServer, elsewhere)
        XCTAssertTrue(client.members.isEmpty)
        XCTAssertFalse(client.isInGroup)
        XCTAssertTrue(wire.sent.contains { $0.packet[5] == 9 && $0.to == server }, "goodbye to the old one")
    }

    // MARK: - The member list

    func testRosterNamesTheGroupAndLeavesUsOut() {
        let (client, wire) = makeClient(connect: true)
        let mine = client.clientId
        let packet = rosterPacket([(ed, "Ed", true), (mine, "iPhone", false), (chris, "Chris", false)])
        _ = client.handleInbound(packet, length: packet.count, remote: server)
        wire.clear()
        XCTAssertEqual(client.members.map(\.name), ["Chris", "Ed"], "in name order, us excepted")
        XCTAssertTrue(client.isInGroup)
    }

    /// The per-member flags byte exists for exactly one sentence the app can say and a
    /// person cannot work out: "waiting for them to tick you".
    func testTicksUsIsReportedAndAnnouncedWhenItChanges() {
        let (client, wire) = makeClient(connect: true)
        var events: [String] = []
        client.onEvent = { events.append($0.message) }
        joinGroup(client, wire, members: [(ed, "Ed", false)])
        XCTAssertFalse(client.members[0].ticksUs)

        joinGroup(client, wire, members: [(ed, "Ed", true)])
        XCTAssertTrue(client.members[0].ticksUs)
        XCTAssertTrue(events.contains("Ed has ticked you"))

        joinGroup(client, wire, members: [(ed, "Ed", false)])
        XCTAssertTrue(events.contains("Ed has unticked you"))
    }

    func testLeavingTheListMeansGone() {
        let (client, wire) = makeClient(connect: true)
        var events: [String] = []
        client.onEvent = { events.append($0.message) }
        joinGroup(client, wire, members: [(ed, "Ed", true), (chris, "Chris", true)])
        joinGroup(client, wire, members: [(chris, "Chris", true)])
        XCTAssertEqual(client.members.map(\.name), ["Chris"])
        XCTAssertTrue(events.contains("Ed left the group"))
    }

    func testPairedWithAnOrdinaryClientIsReportedFromTheListFlags() {
        let (client, wire) = makeClient(connect: true)
        XCTAssertFalse(client.isPairedWithOrdinary)
        joinGroup(client, wire, members: [], listFlags: RelayGroup.listFlagPairedWithOrdinary)
        XCTAssertTrue(client.isPairedWithOrdinary)
        joinGroup(client, wire, members: [])
        XCTAssertFalse(client.isPairedWithOrdinary)
    }

    func testServerFullIsReported() {
        let (client, _) = makeClient(connect: true)
        var events: [String] = []
        client.onEvent = { events.append($0.message) }
        let serverId = RelayClientId(bytes: Array(repeating: 0, count: 16))!
        var packet = [UInt8](RelayGroup.writeHeader(type: .lobbyFull, streamId: 0, sequence: 0,
                                                    clientId: serverId))
        packet.append(contentsOf: [64, 64])
        _ = client.handleInbound(packet, length: packet.count, remote: server)
        XCTAssertTrue(events.contains { $0.contains("full (64 of 64)") })
    }

    // MARK: - Receiving

    /// The core of it: a version-2 packet from the server came from the member whose client
    /// id it carries, and everything downstream must see an ordinary packet from a peer of
    /// that member's own.
    func testAMembersPacketIsCreditedToThatMember() throws {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        let payload: [UInt8] = (0..<32).map { UInt8($0) }
        let packet = groupPacket(from: ed, type: .format, streamId: 9, payload: payload)

        guard case .delivered(let header, let offset, let source) =
                client.handleInbound(packet, length: packet.count, remote: server) else {
            return XCTFail("a member's packet must be delivered")
        }
        XCTAssertEqual(header.type, .format)
        XCTAssertEqual(header.streamId, 9)
        XCTAssertEqual(offset, 28)
        XCTAssertEqual(Array(packet[offset..<packet.count]), payload)
        XCTAssertEqual(source, client.members[0].endpoint)
        XCTAssertTrue(RelayGroupClient.isMemberAddress(source.address))
    }

    /// A member can be heard before the first list names them (their audio and the roster
    /// race). They have to get their address then, or the first second of their audio is
    /// dropped.
    func testAnUnlistedMembersPacketStillOpensAMember() throws {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [])
        let packet = groupPacket(from: ed, type: .audio, payload: [1, 2, 3])
        guard case .delivered(_, _, let source) =
                client.handleInbound(packet, length: packet.count, remote: server) else {
            return XCTFail("delivered")
        }
        XCTAssertEqual(client.members.count, 1)
        XCTAssertEqual(client.members[0].name, "", "not named until a list says so")
        XCTAssertEqual(client.member(at: source.address)?.id, ed)
    }

    func testOurOwnPacketComingBackIsDropped() {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [])
        let packet = groupPacket(from: client.clientId, type: .audio, payload: [1])
        guard case .consumed = client.handleInbound(packet, length: packet.count, remote: server) else {
            return XCTFail("our own audio is never played back at us")
        }
        XCTAssertTrue(client.members.isEmpty)
    }

    func testGroupFramingFromSomewhereElseIsNotOurs() {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [])
        let packet = groupPacket(from: ed, type: .audio, payload: [1])
        guard case .notGroup = client.handleInbound(packet, length: packet.count, remote: elsewhere) else {
            return XCTFail("only our server speaks group framing to us")
        }
    }

    func testOrdinaryPacketsFromTheServerAreLeftAlone() {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        // An ordinary packet from the server is our pair partner's, exactly as today.
        guard case .notGroup = client.handleInbound(ordinaryPacket(type: .audio), length: 12,
                                                    remote: server) else {
            return XCTFail("a version-1 packet is not group traffic")
        }
    }

    // MARK: - Sending

    /// Once in a group: one copy to the server, group-framed. The server makes the copies.
    func testAudioGoesToTheServerOnceGroupFramed() throws {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        let out = Wire()
        let packet = ordinaryPacket(type: .audio, payload: [9, 9, 9])
        XCTAssertTrue(client.route(packet, to: server, send: { bytes, to in
            out.sent.append((bytes, to))
            return true
        }))
        XCTAssertEqual(out.sent.count, 1, "one copy, and the server does the rest")
        XCTAssertEqual(out.sent[0].to, server)
        XCTAssertEqual(out.sent[0].packet[4], 2)
        XCTAssertEqual(Array(out.sent[0].packet[28...]), [9, 9, 9])
    }

    /// Heartbeats go in BOTH forms. The ordinary one is what claims an ordinary pair slot
    /// beside a phone or older app waiting for one, so we still reach somebody.
    func testHeartbeatsAlsoGoInOrdinaryForm() {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        let out = Wire()
        XCTAssertTrue(client.route(ordinaryPacket(type: .heartbeat, payload: [0]), to: server,
                                   send: { bytes, to in
            out.sent.append((bytes, to))
            return true
        }))
        XCTAssertEqual(out.sent.count, 2)
        XCTAssertEqual(out.sent.map { $0.packet[4] }.sorted(), [1, 2])
        XCTAssertTrue(out.sent.allSatisfy { $0.to == server })
    }

    /// Audio goes in ordinary form as well only while the list says we hold a pair slot AND
    /// the user has ticked that partner — the same both-ticks rule as everyone else, except
    /// that the partner cannot say it has ticked us, so being given the slot stands for it.
    func testOrdinaryAudioOnlyWhileWeHoldAPairSlotAndHaveTickedThePartner() {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [], listFlags: RelayGroup.listFlagPairedWithOrdinary)

        var sent: [UInt8] = []
        let send: ([UInt8], UDPEndpoint) -> Bool = { packet, _ in
            sent.append(packet[4])
            return true
        }
        _ = client.route(ordinaryPacket(type: .audio), to: server, send: send)
        XCTAssertEqual(sent, [2], "paired, but the partner is not ticked")

        sent = []
        client.setTicked([], pairPartner: true)
        _ = client.route(ordinaryPacket(type: .audio), to: server, send: send)
        XCTAssertEqual(sent.sorted(), [1, 2])
    }

    /// The echo proves *this address* receives, which is a version-1 fact. Dressing it up as
    /// group traffic would be a different claim, and the spec says never to.
    func testAddressChecksAreNeverRouted() {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        XCTAssertFalse(client.route(ordinaryPacket(type: .addrCheck, payload: [1, 2, 3]),
                                    to: server, send: { _, _ in true }),
                       "echoed exactly as it came, by the caller")
    }

    /// A packet for one member goes to the server, group-framed — and the stand-in address
    /// it was addressed to must never reach the socket. Nothing routes to 240.0.0.0/5; a
    /// datagram sent there goes to a stranger.
    func testAPacketForAMemberGoesToTheServerAndNeverToItsStandInAddress() throws {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        let member = try XCTUnwrap(client.members.first)
        let out = Wire()
        XCTAssertTrue(client.route(ordinaryPacket(type: .control), to: member.endpoint,
                                   send: { bytes, to in
            out.sent.append((bytes, to))
            return true
        }))
        XCTAssertEqual(out.sent.count, 1)
        XCTAssertEqual(out.sent[0].to, server)
        XCTAssertEqual(out.sent[0].packet[4], 2)
    }

    func testAPacketForAForgottenMemberIsDroppedNotSent() {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [(ed, "Ed", true)])
        let stale = client.members[0].endpoint
        joinGroup(client, wire, members: []) // Ed has left
        var sends = 0
        XCTAssertTrue(client.route(ordinaryPacket(type: .audio), to: stale, send: { _, _ in
            sends += 1
            return true
        }), "handled — the caller must not send it either")
        XCTAssertEqual(sends, 0)
    }

    /// One ping is addressed to every tracked peer, and every member is a tracked peer. The
    /// datagram is identical, so wrapping it once per member would put N copies on the
    /// server, each of which it fans out to the whole group, each of which every member
    /// pongs. One ping, one copy.
    func testOneHeartbeatToSeveralMembersIsWrappedOnce() {
        let (client, wire) = makeClient(connect: true)
        joinGroup(client, wire, members: [(ed, "Ed", true), (chris, "Chris", true)])
        let endpoints = client.members.map(\.endpoint)
        XCTAssertEqual(endpoints.count, 2)

        var sends = 0
        let ping = ordinaryPacket(type: .heartbeat, sequence: 42, payload: [0])
        for endpoint in endpoints {
            _ = client.route(ping, to: endpoint, send: { _, _ in
                sends += 1
                return true
            })
        }
        XCTAssertEqual(sends, 1)

        // The server itself is a tracked peer too (its ordinary heartbeat is what claims the
        // pair slot), so the SAME ping arrives here a third time. Still one group copy — but
        // the ordinary one must go, because that is the one with a job to do.
        var versions: [UInt8] = []
        _ = client.route(ping, to: server, send: { packet, _ in
            versions.append(packet[4])
            return true
        })
        XCTAssertEqual(versions, [1], "the ordinary copy only; the group already has one")

        // The next ping has its own sequence and does go out.
        _ = client.route(ordinaryPacket(type: .heartbeat, sequence: 43, payload: [0]),
                         to: endpoints[0], send: { _, _ in
            sends += 1
            return true
        })
        XCTAssertEqual(sends, 2)
    }
}
