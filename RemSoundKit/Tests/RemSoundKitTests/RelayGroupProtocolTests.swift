@testable import RemSoundKit
import XCTest

/// Pins the server's **group framing** and its four own packet types against the upstream
/// spec (`server/RELAY-GROUPS.md`, server-v2.9) and against the server implementation
/// (`remsound-relay.py`), which is what we actually have to interoperate with. Every offset
/// and length here is read by a Raspberry Pi running Python and by the Windows app; getting
/// one wrong is silent — the server simply never groups us.
final class RelayGroupProtocolTests: XCTestCase {
    private let id = RelayClientId(bytes: Array(repeating: 0xAB, count: 16))!
    private let tag: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

    // MARK: - Framing

    func testGroupHeaderLayout() {
        let packet = [UInt8](RelayGroup.writeHeader(type: .audio, streamId: 0x1234,
                                                    sequence: 0x0A0B_0C0D, clientId: id))
        XCTAssertEqual(packet.count, 28, "12-byte header + 16-byte client id")
        XCTAssertEqual(Array(packet[0..<4]), Array("RMND".utf8))
        XCTAssertEqual(packet[4], 2, "group framing is header version 2")
        XCTAssertEqual(packet[5], RemPacketType.audio.rawValue)
        XCTAssertEqual(Array(packet[6..<8]), [0x34, 0x12], "streamId little-endian")
        XCTAssertEqual(Array(packet[8..<12]), [0x0D, 0x0C, 0x0B, 0x0A], "sequence little-endian")
        XCTAssertEqual(Array(packet[12..<28]), id.bytes, "client id at offset 12")
    }

    /// The whole point of the framing: the payload is the ordinary payload, untouched, 16
    /// bytes further in. Wrapping then reading must give back exactly what went in.
    func testWrapKeepsTheOrdinaryPacketIntact() throws {
        var ordinary = [UInt8](RemPacket.writeHeader(type: .format, streamId: 7, sequence: 99))
        let payload: [UInt8] = (0..<46).map { UInt8($0) }
        ordinary.append(contentsOf: payload)

        let wrapped = try XCTUnwrap(RelayGroup.wrap(ordinary, clientId: id))
        XCTAssertEqual(wrapped.count, ordinary.count + 16)
        let header = try XCTUnwrap(RelayGroup.readHeader(wrapped, length: wrapped.count))
        XCTAssertEqual(header.type, .format)
        XCTAssertEqual(header.streamId, 7)
        XCTAssertEqual(header.sequence, 99)
        XCTAssertEqual(header.clientId, id)
        XCTAssertEqual(Array(wrapped[28...]), payload)
        // And the ordinary reader must see the same stream, so a member's packet needs no
        // second interpretation once the client id is accounted for.
        XCTAssertEqual(header.asOrdinary.streamId, 7)
        XCTAssertEqual(header.asOrdinary.type, .format)
    }

    /// Our own v1 reader must keep refusing group framing. This is the whole reason nothing
    /// in the field breaks when a server starts sending it: a pre-groups client drops it.
    func testOrdinaryReaderRejectsGroupFraming() {
        let packet = [UInt8](RelayGroup.writeHeader(type: .audio, streamId: 1, sequence: 1,
                                                    clientId: id))
        XCTAssertNil(RemPacket.readHeader(packet, length: packet.count))
    }

    func testGroupReaderRejectsOrdinaryFramingAndShortPackets() {
        let ordinary = [UInt8](RemPacket.writeHeader(type: .audio, streamId: 1, sequence: 1))
        XCTAssertNil(RelayGroup.readHeader(ordinary, length: ordinary.count))
        let truncated = [UInt8](RelayGroup.writeHeader(type: .audio, streamId: 1, sequence: 1,
                                                       clientId: id)).dropLast()
        XCTAssertNil(RelayGroup.readHeader(Array(truncated), length: truncated.count))
    }

    // MARK: - Hello

    func testHelloPayloadLayout() {
        let other = RelayClientId(bytes: Array(repeating: 0x11, count: 16))!
        let payload = [UInt8](RelayGroup.helloPayload(name: "Studio Mac", groupTag: tag,
                                                      ticked: [other]))
        XCTAssertEqual(payload.count, 32 + 8 + 1 + 16)
        XCTAssertEqual(RelayGroup.decodeName(payload[0..<32]), "Studio Mac")
        XCTAssertEqual(Array(payload[32..<40]), tag, "the group tag is the password fingerprint")
        XCTAssertEqual(payload[40], 1, "one person ticked")
        XCTAssertEqual(Array(payload[41..<57]), other.bytes)
    }

    /// A count of 0 means "nobody yet" and is NOT the same as leaving the list off, which
    /// means "everyone in my group". We always send the list, so the server always knows
    /// exactly who the user has ticked — including when that is nobody.
    func testHelloAlwaysCarriesACountEvenWhenNobodyIsTicked() {
        let payload = [UInt8](RelayGroup.helloPayload(name: "Phone", groupTag: tag, ticked: []))
        XCTAssertEqual(payload.count, 41, "32 name + 8 tag + the count byte")
        XCTAssertEqual(payload[40], 0)
    }

    func testHelloCapsTheTickListAtTheServersLimit() {
        let many = (0..<80).map { i -> RelayClientId in
            var bytes = [UInt8](repeating: 0, count: 16)
            bytes[0] = UInt8(i + 1)
            return RelayClientId(bytes: bytes)!
        }
        let payload = [UInt8](RelayGroup.helloPayload(name: "x", groupTag: tag, ticked: many))
        XCTAssertEqual(payload[40], 64)
        XCTAssertEqual(payload.count, 41 + 64 * 16)
    }

    /// The hello's header, as the server parses it. streamId 0 is coerced to 1 by both
    /// implementations' header writers; the server ignores it either way, and matching keeps
    /// the two byte-identical.
    func testHelloPacketHeader() {
        let packet = RelayGroup.helloPacket(clientId: id, name: "x", groupTag: tag, ticked: [])
        XCTAssertEqual(packet[4], 2)
        XCTAssertEqual(packet[5], 6)
        XCTAssertEqual(Array(packet[6..<8]), [1, 0])
        XCTAssertEqual(Array(packet[12..<28]), id.bytes)
    }

    func testByeIsAHeaderAndNothingElse() {
        let packet = RelayGroup.byePacket(clientId: id)
        XCTAssertEqual(packet.count, 28)
        XCTAssertEqual(packet[5], 9)
    }

    // MARK: - Names

    /// 32 bytes, cut on a CHARACTER boundary. Truncating mid-codepoint would put a
    /// replacement character in every other member's list.
    func testNameFieldTruncatesOnACharacterBoundary() {
        let name = String(repeating: "é", count: 20) // 40 UTF-8 bytes
        let field = RelayGroup.encodeName(name)
        XCTAssertEqual(field.count, 32)
        let decoded = RelayGroup.decodeName(field[0..<32])
        XCTAssertEqual(decoded, String(repeating: "é", count: 16))
        XCTAssertFalse(decoded.unicodeScalars.contains("\u{FFFD}"), "no mangled codepoint")
    }

    func testNameFieldIsZeroPaddedAndDecodesBack() {
        let field = RelayGroup.encodeName("Ed")
        XCTAssertEqual(field.count, 32)
        XCTAssertEqual(Array(field[2..<32]), [UInt8](repeating: 0, count: 30))
        XCTAssertEqual(RelayGroup.decodeName(field[0..<32]), "Ed")
    }

    /// The server pads and truncates on raw bytes and a member can put anything in its
    /// hello, so reading a name back must never fail — only ever produce something.
    func testNameFieldDecodeToleratesRubbish() {
        var field = [UInt8](repeating: 0xFF, count: 32)
        field[31] = 0
        XCTAssertFalse(RelayGroup.decodeName(field[0..<32]).isEmpty)
    }

    // MARK: - Roster

    private func rosterPayload(_ entries: [(RelayClientId, String, Bool)],
                               listFlags: UInt8, withMemberFlags: Bool = true) -> [UInt8] {
        var payload: [UInt8] = [UInt8(entries.count)]
        for (id, name, ticksUs) in entries {
            payload.append(contentsOf: id.bytes)
            payload.append(contentsOf: RelayGroup.encodeName(name))
            if withMemberFlags { payload.append(ticksUs ? 1 : 0) }
        }
        payload.append(listFlags)
        return payload
    }

    func testRosterParsesMembersAndTheirTickFlags() throws {
        let a = RelayClientId(bytes: Array(repeating: 0x01, count: 16))!
        let b = RelayClientId(bytes: Array(repeating: 0x02, count: 16))!
        let payload = rosterPayload([(a, "Ed", true), (b, "Chris", false)], listFlags: 1)
        let roster = try XCTUnwrap(RelayGroup.readRoster(payload[...]))
        XCTAssertEqual(roster.members.map(\.id), [a, b])
        XCTAssertEqual(roster.members.map(\.name), ["Ed", "Chris"])
        XCTAssertEqual(roster.members.map(\.ticksUs), [true, false])
        XCTAssertTrue(roster.pairedWithOrdinary, "trailing flags bit 0")
    }

    func testRosterWithNobodyInItParses() throws {
        let roster = try XCTUnwrap(RelayGroup.readRoster([0, 0][...]))
        XCTAssertTrue(roster.members.isEmpty)
        XCTAssertFalse(roster.pairedWithOrdinary)
    }

    /// A server older than v2.9 sends 48-byte entries, with no per-member flags byte. The
    /// entry size has to come off the payload length or a mismatched pair silently never
    /// shows a list at all.
    func testRosterReadsPreV29EntriesWithoutFlags() throws {
        let a = RelayClientId(bytes: Array(repeating: 0x03, count: 16))!
        let payload = rosterPayload([(a, "Old server", false)], listFlags: 0,
                                    withMemberFlags: false)
        XCTAssertEqual(payload.count, 1 + 48 + 1)
        let roster = try XCTUnwrap(RelayGroup.readRoster(payload[...]))
        XCTAssertEqual(roster.members.map(\.name), ["Old server"])
        XCTAssertFalse(roster.members[0].ticksUs, "an old server never says — never guess yes")
    }

    /// The two entry sizes produce the same payload length only for different counts
    /// (49 x 48 == 48 x 49), and the count byte is right there, so resolving the size by
    /// length is unambiguous. Both of these have to come out right.
    func testRosterEntrySizeIsUnambiguousAtTheOverlappingCounts() throws {
        let ids = (0..<49).map { i -> RelayClientId in
            var bytes = [UInt8](repeating: 0, count: 16)
            bytes[0] = UInt8(i + 1)
            return RelayClientId(bytes: bytes)!
        }
        let new = rosterPayload(ids.map { ($0, "n", true) }, listFlags: 0)
        XCTAssertEqual(new.count, 1 + 49 * 49 + 1)
        XCTAssertEqual(try XCTUnwrap(RelayGroup.readRoster(new[...])).members.count, 49)
        XCTAssertTrue(try XCTUnwrap(RelayGroup.readRoster(new[...])).members.allSatisfy(\.ticksUs))

        let old = rosterPayload(ids.prefix(48).map { ($0, "n", false) }, listFlags: 0,
                                withMemberFlags: false)
        XCTAssertEqual(old.count, 1 + 48 * 48 + 1)
        XCTAssertEqual(try XCTUnwrap(RelayGroup.readRoster(old[...])).members.count, 48)
    }

    func testRosterTooShortForItsCountIsRejected() {
        var payload = rosterPayload([(RelayClientId(bytes: Array(repeating: 9, count: 16))!,
                                      "x", true)], listFlags: 0)
        payload[0] = 4 // claims four members, carries one
        XCTAssertNil(RelayGroup.readRoster(payload[...]))
        XCTAssertNil(RelayGroup.readRoster([][...]))
    }

    func testFullPayload() throws {
        let full = try XCTUnwrap(RelayGroup.readFull([64, 64][...]))
        XCTAssertEqual(full.count, 64)
        XCTAssertEqual(full.maximum, 64)
        XCTAssertNil(RelayGroup.readFull([1][...]))
    }

    // MARK: - Client id

    func testClientIdIsSixteenBytesNeverZeroAndRoundTripsThroughHex() throws {
        XCTAssertNil(RelayClientId(bytes: Array(repeating: 1, count: 15)))
        XCTAssertNil(RelayClientId(hex: "nothex"))
        XCTAssertNil(RelayClientId(hex: String(repeating: "0", count: 32)),
                     "all zero is the server's own id, never a member's")
        let fresh = RelayClientId.random()
        XCTAssertFalse(fresh.isZero)
        XCTAssertEqual(fresh.hex.count, 32)
        XCTAssertEqual(RelayClientId(hex: fresh.hex), fresh)
        XCTAssertEqual(RelayClientId(hex: fresh.hex.uppercased()), fresh)
    }

    /// Stand-in addresses must land in the reserved block, and the same id must always get
    /// the same one — everything this port keys by address (a volume, a name, a session)
    /// comes back with the person because of it.
    func testStandInAddressesAreReservedAndStable() {
        let client = RelayGroupClient(clientId: .random())
        let server = UDPEndpoint(host: "198.51.100.7", port: RemPacket.defaultPort)!
        client.setIdentity(name: "me", passwordFingerprint: tag)
        client.connect(to: server)

        let member = RelayClientId(bytes: Array(repeating: 0x5A, count: 16))!
        deliver(roster: [(member, "Ed", false)], from: server, to: client)
        let first = client.members.first?.endpoint
        XCTAssertNotNil(first)
        XCTAssertTrue(RelayGroupClient.isMemberAddress(first!.address))
        XCTAssertTrue(first!.addressString.hasPrefix("24"), "240.0.0.0/5: \(first!.addressString)")

        // Same person, a later roster: the same address.
        deliver(roster: [(member, "Ed", true)], from: server, to: client)
        XCTAssertEqual(client.members.first?.endpoint, first)
    }

    func testOrdinaryAddressesAreNotMemberAddresses() {
        XCTAssertFalse(RelayGroupClient.isMemberAddress(
            UDPEndpoint(host: "192.168.1.10", port: 1)!.address))
        XCTAssertFalse(RelayGroupClient.isMemberAddress(
            UDPEndpoint(host: "100.64.0.1", port: 1)!.address), "Tailscale space is real")
        XCTAssertTrue(RelayGroupClient.isMemberAddress(
            UDPEndpoint(host: "240.0.0.1", port: 1)!.address))
        XCTAssertTrue(RelayGroupClient.isMemberAddress(
            UDPEndpoint(host: "247.255.255.255", port: 1)!.address))
        XCTAssertFalse(RelayGroupClient.isMemberAddress(
            UDPEndpoint(host: "248.0.0.1", port: 1)!.address), "/5 ends at 247")
    }

    // MARK: - Helper

    func deliver(roster entries: [(RelayClientId, String, Bool)], listFlags: UInt8 = 0,
                 from server: UDPEndpoint, to client: RelayGroupClient) {
        // The server signs its own packets with an all-zero client id.
        let serverId = RelayClientId(bytes: Array(repeating: 0, count: 16))!
        var packet = [UInt8](RelayGroup.writeHeader(type: .lobbyRoster, streamId: 0,
                                                    sequence: 0, clientId: serverId))
        packet.append(contentsOf: rosterPayload(entries, listFlags: listFlags))
        _ = client.handleInbound(packet, length: packet.count, remote: server)
    }
}
