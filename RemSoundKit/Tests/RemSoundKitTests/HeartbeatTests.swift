@testable import RemSoundKit
import XCTest

/// Pins the heartbeat's pong accounting. Most of it has been true since the first build; the
/// originator check became load-bearing when a server started relaying a whole group, where
/// every member's pong reaches every other member.
final class HeartbeatTests: XCTestCase {
    private let peer = UDPEndpoint(host: "192.0.2.50", port: RemPacket.defaultPort)!

    private func pongPayload(originatorTickMs: Int64) -> ArraySlice<UInt8> {
        [UInt8](RemPacket.writeHeartbeatPayload(kind: .pong, originatorTickMs: originatorTickMs))[...]
    }

    /// A pong echoes our own timestamp back, so the round trip needs no clock sync.
    func testPongAnsweringOurPingGivesAHealthyPeerAndARoundTrip() throws {
        let heartbeat = HeartbeatService()
        var pings: [[UInt8]] = []
        heartbeat.sendTransport = { data, _ in
            pings.append(data)
            return true
        }
        heartbeat.setTrackedPeers([peer])
        heartbeat.sendPingsForTesting()

        let ping = try XCTUnwrap(pings.first)
        let sent = try XCTUnwrap(RemPacket.readHeartbeat(ping[RemPacket.headerSize..<ping.count]))
        XCTAssertEqual(sent.kind, .ping)

        heartbeat.handleHeartbeatPayload(pongPayload(originatorTickMs: sent.originatorTickMs),
                                         remote: peer)
        let health = try XCTUnwrap(heartbeat.allPeerHealth().first)
        XCTAssertEqual(health.state, .healthy)
        XCTAssertNotNil(health.rttMs)
    }

    /// Through a server, a member's pong is fanned out to the whole group carrying the clock
    /// of whoever pinged — so a pong that answers somebody else's ping arrives here routinely.
    /// Crediting it would compute a round trip from a stranger's clock and, worse, hold a peer
    /// "healthy" on traffic that says nothing about whether it can hear us.
    func testPongAnsweringSomebodyElsesPingIsIgnored() throws {
        let heartbeat = HeartbeatService()
        var pings: [[UInt8]] = []
        heartbeat.sendTransport = { data, _ in
            pings.append(data)
            return true
        }
        heartbeat.setTrackedPeers([peer])
        heartbeat.sendPingsForTesting()
        let ping = try XCTUnwrap(pings.first)
        let sent = try XCTUnwrap(RemPacket.readHeartbeat(ping[RemPacket.headerSize..<ping.count]))

        heartbeat.handleHeartbeatPayload(pongPayload(originatorTickMs: sent.originatorTickMs &+ 9_999),
                                         remote: peer)
        let health = try XCTUnwrap(heartbeat.allPeerHealth().first)
        XCTAssertEqual(health.state, .unknown, "not one of our pings — nothing is known yet")
        XCTAssertNil(health.rttMs)
    }

    /// A ping is answered wherever it came from, so a ping relayed through a server is
    /// answered back down the same path. The reply must be a pong carrying the *originator's*
    /// timestamp verbatim, or the other end can never match it to its own ping.
    func testAPingIsAnsweredWithThePongTheOriginatorCanMatch() throws {
        let heartbeat = HeartbeatService()
        var replies: [(packet: [UInt8], to: UDPEndpoint)] = []
        heartbeat.sendTransport = { data, to in
            replies.append((data, to))
            return true
        }
        let theirTick: Int64 = 1_234_567
        let payload = [UInt8](RemPacket.writeHeartbeatPayload(kind: .ping,
                                                              originatorTickMs: theirTick))
        heartbeat.handleHeartbeatPayload(payload[...], remote: peer)

        let reply = try XCTUnwrap(replies.first)
        XCTAssertEqual(reply.to, peer)
        let header = try XCTUnwrap(RemPacket.readHeader(reply.packet, length: reply.packet.count))
        XCTAssertEqual(header.type, .heartbeat)
        XCTAssertEqual(header.streamId, 0xFFFF, "the heartbeat marker, same as the Windows sender")
        let echoed = try XCTUnwrap(
            RemPacket.readHeartbeat(reply.packet[RemPacket.headerSize..<reply.packet.count]))
        XCTAssertEqual(echoed.kind, .pong)
        XCTAssertEqual(echoed.originatorTickMs, theirTick)
    }
}
