@testable import RemSoundKit
import XCTest

/// Pins the relay address-proof echo (upstream `TYPE_ADDR_CHECK` = 10, server-v2.5,
/// 2026-07-27). The relay cookies every newly seen client address and only marks it VERIFIED
/// once the same packet comes back from it; while the relay runs watch-only nothing breaks,
/// but once it flips `--require-addr-check` an endpoint that never echoes has all forwarded
/// traffic withheld. This runs over real loopback UDP because the echo has to leave the SAME
/// socket audio arrives on — the property that actually matters is not testable in isolation.
final class AddrCheckTests: XCTestCase {
    func testEngineEchoesAddrCheckBackToItsSource() throws {
        let enginePort: UInt16 = 47931
        let engine = AudioReceiverEngine()
        try engine.start(port: enginePort)
        defer { engine.stop() }

        let echoed = XCTestExpectation(description: "AddrCheck echoed back")
        let received = UncheckedBox<[UInt8]>([])
        let probe = UDPSocket(onPacket: { buffer, length, _, _ in
            received.value = Array(buffer[0..<length])
            echoed.fulfill()
        })
        try probe.start(port: 0)
        defer { probe.stop() }

        // 12-byte header (type 10) + the relay's 16-byte random cookie.
        var challenge = [UInt8](RemPacket.writeHeader(type: .audio, streamId: 1, sequence: 0))
        challenge[5] = 10
        let cookie: [UInt8] = (0..<16).map { UInt8($0 &* 7 &+ 1) }
        challenge.append(contentsOf: cookie)

        let target = try XCTUnwrap(UDPEndpoint(host: "127.0.0.1", port: enginePort))
        XCTAssertTrue(probe.send(challenge, to: target))

        wait(for: [echoed], timeout: 5)
        // Verbatim: the relay compares the bytes after the header against the cookie it issued.
        XCTAssertEqual(received.value, challenge)
    }

    /// The echo must not depend on the relay being in the selected-peers allow-list — the
    /// challenge comes from the relay itself, which the user need not have selected.
    func testAddrCheckIsEchoedEvenWhenTheAllowListBlocksEveryone() throws {
        let enginePort: UInt16 = 47932
        let engine = AudioReceiverEngine()
        engine.setAllowedSenders(Set<UInt32>())
        try engine.start(port: enginePort)
        defer { engine.stop() }

        let echoed = XCTestExpectation(description: "AddrCheck echoed back despite allow-list")
        let probe = UDPSocket(onPacket: { _, _, _, _ in echoed.fulfill() })
        try probe.start(port: 0)
        defer { probe.stop() }

        var challenge = [UInt8](RemPacket.writeHeader(type: .audio, streamId: 1, sequence: 0))
        challenge[5] = 10
        challenge.append(contentsOf: [UInt8](repeating: 0x5A, count: 16))

        let target = try XCTUnwrap(UDPEndpoint(host: "127.0.0.1", port: enginePort))
        XCTAssertTrue(probe.send(challenge, to: target))
        wait(for: [echoed], timeout: 5)
    }
}

/// The echo gate (upstream `AddrCheckEchoGate`, 6.0): answer only addresses we are talking to,
/// at most once a second each. Answering anyone let one forged packet bounce between two
/// RemSound devices for ever.
final class AddrCheckEchoGateTests: XCTestCase {
    private func challenge(_ fill: UInt8) -> [UInt8] {
        var packet = [UInt8](RemPacket.writeHeader(type: .audio, streamId: 1, sequence: 0))
        packet[5] = 10
        packet.append(contentsOf: [UInt8](repeating: fill, count: 16))
        return packet
    }

    private func run(port: UInt16, echoTargets: Set<UInt32>?, sends: Int,
                     expectEchoes: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let engine = AudioReceiverEngine()
        engine.setAddressCheckEchoTargets(echoTargets)
        try engine.start(port: port)
        defer { engine.stop() }

        let echoes = UncheckedBox(0)
        let probe = UDPSocket(onPacket: { _, _, _, _ in echoes.value += 1 })
        try probe.start(port: 0)
        defer { probe.stop() }

        let target = try XCTUnwrap(UDPEndpoint(host: "127.0.0.1", port: port))
        for i in 0..<sends { XCTAssertTrue(probe.send(challenge(UInt8(i)), to: target)) }
        // Loopback answers in well under a millisecond; a fixed wait also lets an echo that
        // should NOT happen show up, which waiting for an expectation would cut short.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(echoes.value, expectEchoes, file: file, line: line)
    }

    private var loopback: UInt32 { UDPEndpoint(host: "127.0.0.1", port: 1)!.address }

    func testAnAddressWeTalkToIsAnswered() throws {
        try run(port: 47933, echoTargets: [loopback], sends: 1, expectEchoes: 1)
    }

    func testAnAddressWeDoNotTalkToIsNotAnswered() throws {
        try run(port: 47934, echoTargets: [], sends: 1, expectEchoes: 0)
    }

    /// The loop-breaker even between two copies that DO talk to each other: a burst gets one
    /// answer, not one per packet.
    func testABurstFromOneAddressGetsOneAnswerASecond() throws {
        try run(port: 47935, echoTargets: [loopback], sends: 5, expectEchoes: 1)
    }
}

/// Carries a value from the socket's receive thread to the test thread. The wait/fulfil pair
/// is the ordering barrier; this box only satisfies the concurrency checker.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
