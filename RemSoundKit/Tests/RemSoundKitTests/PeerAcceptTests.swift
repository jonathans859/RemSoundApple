@testable import RemSoundKit
import XCTest

/// Pins "Accept connections from other peers" (upstream `MainForm.AcceptConnections.cs`) —
/// above all the two rules upstream paid for: one question per person per run, and a
/// deliberate untick that nothing may undo.
final class PeerAcceptPolicyTests: XCTestCase {
    private let lan = PeerAcceptPolicy.networkKey(address: "192.168.1.50")
    private let member = PeerAcceptPolicy.memberKey(hex: "00112233445566778899aabbccddeeff")

    func testManualNeverActs() {
        var policy = PeerAcceptPolicy()
        XCTAssertEqual(policy.decide(key: lan, mode: .manual, promptOpen: false), .ignore)
        // And nothing was recorded, so switching to another mode later still acts.
        XCTAssertEqual(policy.decide(key: lan, mode: .automatic, promptOpen: false), .accept)
    }

    func testAutomaticAcceptsOnce() {
        var policy = PeerAcceptPolicy()
        XCTAssertEqual(policy.decide(key: member, mode: .automatic, promptOpen: false), .accept)
        XCTAssertEqual(policy.decide(key: member, mode: .automatic, promptOpen: false), .ignore)
    }

    /// Asked once per run, whichever way the answer went: the policy cannot tell a "no" from
    /// a "yes", and does not need to.
    func testPromptAsksOncePerPerson() {
        var policy = PeerAcceptPolicy()
        XCTAssertEqual(policy.decide(key: lan, mode: .prompt, promptOpen: false), .ask)
        XCTAssertEqual(policy.decide(key: lan, mode: .prompt, promptOpen: false), .ignore)
        XCTAssertEqual(policy.decide(key: member, mode: .prompt, promptOpen: false), .ask,
                       "somebody else is still asked about")
    }

    /// One question at a time — and the one put off is NOT marked as asked, which is what
    /// brings it back once the first is answered.
    func testAQuestionAlreadyOnScreenDefersTheNextWithoutForgettingIt() {
        var policy = PeerAcceptPolicy()
        XCTAssertEqual(policy.decide(key: lan, mode: .prompt, promptOpen: true), .ignore)
        XCTAssertEqual(policy.decide(key: lan, mode: .prompt, promptOpen: false), .ask)
    }

    /// Automatic mode puts up no question, so an open one does not hold it back.
    func testAutomaticIsNotHeldBackByAnOpenQuestion() {
        var policy = PeerAcceptPolicy()
        XCTAssertEqual(policy.decide(key: lan, mode: .automatic, promptOpen: true), .accept)
    }

    /// The upstream bug ("otherwise you can never disconnect", 2026-09-21): unticking somebody
    /// who still has you ticked leaves their audio arriving, which is exactly what sets this
    /// off — so in automatic mode they were ticked straight back. The untick must stick.
    func testAUserUntickSticksEvenInAutomaticMode() {
        var policy = PeerAcceptPolicy()
        XCTAssertEqual(policy.decide(key: lan, mode: .automatic, promptOpen: false), .accept)
        policy.userUnticked([lan])
        XCTAssertEqual(policy.decide(key: lan, mode: .automatic, promptOpen: false), .ignore)
        XCTAssertEqual(policy.decide(key: lan, mode: .prompt, promptOpen: false), .ignore)
    }

    /// Even somebody never asked about: an untick before they ever sent anything holds too.
    func testAnUntickBeforeAnyRequestStillHolds() {
        var policy = PeerAcceptPolicy()
        policy.userUnticked([member])
        XCTAssertEqual(policy.decide(key: member, mode: .automatic, promptOpen: false), .ignore)
    }

    /// Ticking them again is the user changing their mind, so the refusal goes. They were
    /// already asked about, so it is the user's tick that connects them, not a new question.
    func testTickingAgainLiftsTheRefusal() {
        var policy = PeerAcceptPolicy()
        policy.userUnticked([lan])
        policy.userTicked([lan])
        XCTAssertFalse(policy.refusedByUser.contains(lan))
        XCTAssertEqual(policy.decide(key: lan, mode: .automatic, promptOpen: false), .accept)
    }

    func testKeysForDifferentKindsOfPersonNeverCollide() {
        let keys = [PeerAcceptPolicy.networkKey(address: "10.0.0.1"),
                    PeerAcceptPolicy.memberKey(hex: "10.0.0.1"),
                    PeerAcceptPolicy.pairKey(server: "10.0.0.1")]
        XCTAssertEqual(Set(keys).count, 3)
    }

    /// Raw values are upstream's and are what is stored: reordering the cases must not move a
    /// stored choice.
    func testModeRawValuesMatchUpstream() {
        XCTAssertEqual(PeerAcceptMode.prompt.rawValue, 0)
        XCTAssertEqual(PeerAcceptMode.automatic.rawValue, 1)
        XCTAssertEqual(PeerAcceptMode.manual.rawValue, 2)
        XCTAssertEqual(PeerAcceptMode.allCases.first, .prompt, "the default leads the list")
    }
}

/// The receive-side signal: somebody we have not ticked sending us a format packet.
final class UnselectedSenderTests: XCTestCase {
    private let stranger = UDPEndpoint(host: "192.168.1.77", port: 41000)!
    private let friend = UDPEndpoint(host: "192.168.1.50", port: 41000)!
    private let ours: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    private let theirs: [UInt8] = [8, 7, 6, 5, 4, 3, 2, 1]

    private func formatPacket(fingerprint: [UInt8]?) -> [UInt8] {
        let format = AudioFormatInfo(
            sampleRate: 48_000, channels: 2, bitsPerSample: 16, encoding: 1,
            blockAlign: 4, averageBytesPerSecond: 192_000, codec: .opus,
            frameSamplesPerChannel: 480, lane: .mixed)
        var packet = [UInt8](RemPacket.writeHeader(type: .format, streamId: 3, sequence: 0))
        packet.append(contentsOf: RemPacket.writeFormatPayload(format, passwordFingerprint: fingerprint))
        return packet
    }

    private func engine(heard: @escaping (UDPEndpoint, Bool) -> Void) -> AudioReceiverEngine {
        let engine = AudioReceiverEngine()
        engine.setKeyMaterial(key: [UInt8](repeating: 9, count: 32), fingerprint: ours)
        engine.setAllowedSenders([friend.address])
        engine.onUnselectedSenderHeard = heard
        return engine
    }

    func testAnUnselectedSenderOnOurPasswordIsReportedOnce() {
        var reports: [(UDPEndpoint, Bool)] = []
        let engine = engine { reports.append(($0, $1)) }
        // Format packets repeat every 250 ms; a sender left running must not be a question
        // four times a second.
        for _ in 0..<5 {
            engine.handlePacketForTesting(formatPacket(fingerprint: ours), from: stranger)
        }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.0, stranger)
        XCTAssertEqual(reports.first?.1, true)
        XCTAssertTrue(engine.liveSessionsForTesting.isEmpty, "reporting them is not playing them")
    }

    func testADifferentPasswordIsReportedAsSuch() {
        var reports: [Bool] = []
        let engine = engine { reports.append($1) }
        engine.handlePacketForTesting(formatPacket(fingerprint: theirs), from: stranger)
        XCTAssertEqual(reports, [false])
    }

    /// A sender too old to put a fingerprint in its format packet cannot be shown to share
    /// our password, so it is never offered either.
    func testNoFingerprintCountsAsADifferentPassword() {
        var reports: [Bool] = []
        let engine = engine { reports.append($1) }
        engine.handlePacketForTesting(formatPacket(fingerprint: nil), from: stranger)
        XCTAssertEqual(reports, [false])
    }

    func testATickedSenderIsNotReported() {
        var reports = 0
        let engine = engine { _, _ in reports += 1 }
        engine.handlePacketForTesting(formatPacket(fingerprint: ours), from: friend)
        XCTAssertEqual(reports, 0)
    }

    /// With receiving off nothing is played from anybody, so nobody is offered either —
    /// upstream's gate sits in the same place.
    func testNothingIsReportedWhileReceivingIsOff() {
        var reports = 0
        let engine = engine { _, _ in reports += 1 }
        engine.setPlaybackEnabled(false)
        engine.handlePacketForTesting(formatPacket(fingerprint: ours), from: stranger)
        XCTAssertEqual(reports, 0)
    }
}
