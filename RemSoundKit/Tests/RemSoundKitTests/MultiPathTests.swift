@testable import RemSoundKit
import XCTest

/// Pins the three multi-homed-peer rules from issue #8 — a peer reachable at a LAN address
/// and a VPN address at the same time. None of them can misfire on a plain Wi-Fi LAN, which
/// is why they stayed invisible until someone ran RemSound over Tailscale on a hotspot.
final class PeerCueTrackerTests: XCTestCase {
    private func observation(_ id: String, _ name: String, connected: Bool, lost: Bool = false)
        -> PeerCueTracker.Observation {
        PeerCueTracker.Observation(id: id, name: name, isConnected: connected, isLost: lost)
    }

    func testConnectAndLostAnnounceOnce() {
        var tracker = PeerCueTracker()
        XCTAssertEqual(tracker.update([observation("d-1", "Studio PC", connected: true)]).connected,
                       ["Studio PC"])
        // Still connected on the next tick: no repeat cue.
        XCTAssertTrue(tracker.update([observation("d-1", "Studio PC", connected: true)]).isEmpty)
        XCTAssertEqual(tracker.update([observation("d-1", "Studio PC", connected: false, lost: true)]).lost,
                       ["Studio PC"])
    }

    /// The hysteresis itself: neither clearly connected nor clearly lost holds the last
    /// decision, so a two-second Wi-Fi/VPN stall stays silent.
    func testNeitherConnectedNorLostHoldsState() {
        var tracker = PeerCueTracker()
        _ = tracker.update([observation("d-1", "Studio PC", connected: true)])
        XCTAssertTrue(tracker.update([observation("d-1", "Studio PC", connected: false)]).isEmpty)
        XCTAssertNotNil(tracker.connectedSince(id: "d-1"), "still counts as connected")
    }

    /// The bug: cue state used to be keyed on the peer's primary address, which is whichever
    /// of its paths discovery saw first and has not expired. A quiet LAN leg ageing out from
    /// under a live VPN stream moved the key, so the old one reported lost and the new one
    /// reported connected on the SAME tick — both cues, both announcements, while audio never
    /// stopped. The row id does not move.
    func testPathChangeUnderALivePeerIsSilent() {
        var tracker = PeerCueTracker()
        _ = tracker.update([observation("d-1", "Studio PC", connected: true)])
        // Same peer, same row id; its LAN address has just aged out of discovery and the VPN
        // address is now its primary. Nothing about the connection changed.
        let transitions = tracker.update([observation("d-1", "Studio PC", connected: true)])
        XCTAssertTrue(transitions.isEmpty, "a path change is not a disconnect")
    }

    /// The clock behind the details panel's "Connected for" line must survive a path change
    /// too — it hangs off these transitions, not off the raw health.
    func testConnectedSinceSurvivesAPathChange() {
        var tracker = PeerCueTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = tracker.update([observation("d-1", "Studio PC", connected: true)], now: start)
        _ = tracker.update([observation("d-1", "Studio PC", connected: true)],
                           now: start.addingTimeInterval(60))
        XCTAssertEqual(tracker.connectedSince(id: "d-1"), start)
    }

    func testVanishedPeerReportsLostOnlyIfItHadConnected() {
        var tracker = PeerCueTracker()
        _ = tracker.update([observation("d-1", "Studio PC", connected: true),
                            observation("d-2", "Laptop", connected: false)])
        XCTAssertEqual(tracker.update([]).lost, ["Studio PC"],
                       "a peer that never connected stays quiet")
    }

    /// A vanished peer is no longer in the peer list, so the name has to come from the
    /// tracker or the announcement degrades to a raw address.
    func testLostAnnouncementUsesTheLastKnownName() {
        var tracker = PeerCueTracker()
        _ = tracker.update([observation("d-1", "Studio PC", connected: true)])
        _ = tracker.update([observation("d-1", "Mac mini", connected: true)]) // renamed
        XCTAssertEqual(tracker.update([]).lost, ["Mac mini"])
    }
}

final class SelectionGraceTests: XCTestCase {
    private let lan = UDPEndpoint(host: "192.168.1.50", port: 47830)!
    private let vpn = UDPEndpoint(host: "100.64.0.3", port: 47830)!

    func testAnAddressStaysEligibleAfterDiscoveryStopsSeeingIt() {
        var grace = SelectionGrace(window: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        grace.note(endpoint: lan, selectionKeys: ["192.168.1.50", "100.64.0.3"],
                   identity: "d-1", now: start)
        let selected: Set<String> = ["192.168.1.50", "100.64.0.3"]
        // Discovery's own expiry is 8 s; the stream is still arriving.
        XCTAssertEqual(grace.eligible(selected: selected, now: start.addingTimeInterval(20)),
                       [SelectionGrace.Eligible(endpoint: lan, identity: "d-1")])
        XCTAssertTrue(grace.eligible(selected: selected, now: start.addingTimeInterval(31)).isEmpty,
                      "a peer that really went away stops being allow-listed")
    }

    func testDeselectingCutsItImmediatelyDespiteTheWindow() {
        var grace = SelectionGrace(window: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        grace.note(endpoint: vpn, selectionKeys: ["100.64.0.3"], identity: "d-1", now: start)
        XCTAssertTrue(grace.eligible(selected: [], now: start.addingTimeInterval(1)).isEmpty)
    }

    /// Selection is held per peer, not per address (pitfall 7), so one still-selected address
    /// of a multi-homed peer keeps every remembered path of that peer eligible.
    func testAnyStillSelectedAddressOfThePeerKeepsItsOtherPaths() {
        var grace = SelectionGrace(window: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        let keys: Set<String> = ["192.168.1.50", "100.64.0.3"]
        grace.note(endpoint: lan, selectionKeys: keys, identity: "d-1", now: start)
        grace.note(endpoint: vpn, selectionKeys: keys, identity: "d-1", now: start)
        let eligible = grace.eligible(selected: ["100.64.0.3"], now: start.addingTimeInterval(10))
        XCTAssertEqual(Set(eligible.map(\.endpoint)), [lan, vpn])
    }
}

/// The receive-side duplicate guard: one peer sending one lane to two of our addresses must
/// open ONE session, or the same audio is decoded twice and summed against itself at two path
/// delays — comb filtering that sounds like a bad link rather than like an echo.
final class MultiPathSessionTests: XCTestCase {
    private let lan = UDPEndpoint(host: "192.168.1.50", port: 41000)!
    private let vpn = UDPEndpoint(host: "100.64.0.3", port: 41000)!

    private func formatPacket(streamId: UInt16, lane: RenderRoute = .mixed,
                              frameSamples: Int = 480) -> [UInt8] {
        let format = AudioFormatInfo(
            sampleRate: 48_000, channels: 2, bitsPerSample: 16, encoding: 1,
            blockAlign: 4, averageBytesPerSecond: 192_000, codec: .opus,
            frameSamplesPerChannel: frameSamples, lane: lane)
        var packet = [UInt8](RemPacket.writeHeader(type: .format, streamId: streamId, sequence: 0))
        packet.append(contentsOf: RemPacket.writeFormatPayload(format, passwordFingerprint: nil))
        return packet
    }

    func testOnePeerOnTwoPathsOpensOneSession() {
        let engine = AudioReceiverEngine()
        engine.setPeerAddressGroups([lan.address: "d-1", vpn.address: "d-1"])

        engine.handlePacketForTesting(formatPacket(streamId: 7), from: lan)
        engine.handlePacketForTesting(formatPacket(streamId: 7), from: vpn)

        XCTAssertEqual(engine.liveSessionsForTesting.count, 1,
                       "the same lane over two paths is one stream")
        XCTAssertEqual(engine.liveSessionsForTesting.first?.endpoint, lan,
                       "the path already delivering keeps the lane")
    }

    /// Two genuinely different senders must still both play — the guard keys on peer
    /// identity, not on "some other address is already streaming".
    func testTwoDifferentSendersBothPlay() {
        let engine = AudioReceiverEngine()
        engine.setPeerAddressGroups([lan.address: "d-1", vpn.address: "d-2"])

        engine.handlePacketForTesting(formatPacket(streamId: 7), from: lan)
        engine.handlePacketForTesting(formatPacket(streamId: 9), from: vpn)

        XCTAssertEqual(engine.liveSessionsForTesting.count, 2)
    }

    /// With no grouping pushed, every address stands alone — the pre-#8 behaviour, so nothing
    /// changes for a caller that never pushes one.
    func testUngroupedAddressesEachOpenTheirOwnSession() {
        let engine = AudioReceiverEngine()
        engine.handlePacketForTesting(formatPacket(streamId: 7), from: lan)
        engine.handlePacketForTesting(formatPacket(streamId: 7), from: vpn)
        XCTAssertEqual(engine.liveSessionsForTesting.count, 2)
    }

    /// BothIndependent mode really does send two concurrent lanes per peer, so the dedup has
    /// to stay per-lane.
    func testTwoLanesFromOnePeerCoexist() {
        let engine = AudioReceiverEngine()
        engine.setPeerAddressGroups([lan.address: "d-1"])

        engine.handlePacketForTesting(formatPacket(streamId: 7, lane: .wasapiLane), from: lan)
        engine.handlePacketForTesting(formatPacket(streamId: 8, lane: .asioLane), from: lan)

        XCTAssertEqual(engine.liveSessionsForTesting.count, 2)
        XCTAssertEqual(Set(engine.liveSessionsForTesting.map(\.lane)), [.wasapiLane, .asioLane])
    }

    /// The sender rerolls streamId on codec changes and engine restarts; the old session must
    /// go immediately — that is the same path renumbering, not a handover.
    func testStreamIdRotationOnOnePathSupersedesImmediately() {
        let engine = AudioReceiverEngine()
        engine.setPeerAddressGroups([lan.address: "d-1"])

        engine.handlePacketForTesting(formatPacket(streamId: 7), from: lan)
        engine.handlePacketForTesting(formatPacket(streamId: 8, frameSamples: 960), from: lan)

        XCTAssertEqual(engine.liveSessionsForTesting.count, 1)
        XCTAssertEqual(engine.liveSessionsForTesting.first?.streamId, 8)
    }

    /// A genuine failover still works: once the path holding the lane has been silent for
    /// `pathHandoverSilence`, the peer's other path takes it over.
    func testTheOtherPathTakesOverOnceTheActiveOneGoesSilent() {
        let engine = AudioReceiverEngine()
        engine.setPeerAddressGroups([lan.address: "d-1", vpn.address: "d-1"])

        engine.handlePacketForTesting(formatPacket(streamId: 7), from: lan)
        engine.handlePacketForTesting(formatPacket(streamId: 7), from: vpn)
        XCTAssertEqual(engine.liveSessionsForTesting.first?.endpoint, lan)

        // No audio was ever written to the LAN session; wait out the handover window. The
        // sender re-announces its format every 250 ms, so the next one lands right here.
        Thread.sleep(forTimeInterval: AudioReceiverEngine.pathHandoverSilence + 0.3)
        engine.handlePacketForTesting(formatPacket(streamId: 7), from: vpn)

        XCTAssertEqual(engine.liveSessionsForTesting.count, 1, "handover replaces, never adds")
        XCTAssertEqual(engine.liveSessionsForTesting.first?.endpoint, vpn)
    }
}
