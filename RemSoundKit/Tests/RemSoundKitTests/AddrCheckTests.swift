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

/// Carries a value from the socket's receive thread to the test thread. The wait/fulfil pair
/// is the ordering barrier; this box only satisfies the concurrency checker.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
