import Darwin
@testable import RemSoundKit
import XCTest

/// The CMSG_* helpers are function-like C macros that Swift cannot import, so the control
/// message parsing in `UDPSocket` is hand-written pointer arithmetic. Getting it wrong would
/// not crash — it would quietly return 0 or a nonsense timestamp, and the arrival-gap figures
/// would go back to measuring the receive thread without anyone noticing. Hence these.
final class KernelTimestampTests: XCTestCase {
    /// Build a control buffer exactly as the kernel would for one SCM_TIMESTAMP.
    private func makeControl(level: Int32, type: Int32, tv: timeval,
                             declaredLen: Int? = nil) -> [UInt8] {
        let headerSize = 12 // align32(sizeof(cmsghdr)) on Darwin: 4 + 4 + 4
        var bytes = [UInt8](repeating: 0, count: headerSize + MemoryLayout<timeval>.size)
        var header = cmsghdr()
        header.cmsg_len = socklen_t(declaredLen ?? (headerSize + MemoryLayout<timeval>.size))
        header.cmsg_level = level
        header.cmsg_type = type
        withUnsafeBytes(of: header) { src in
            for i in 0..<min(MemoryLayout<cmsghdr>.size, headerSize) { bytes[i] = src[i] }
        }
        withUnsafeBytes(of: tv) { src in
            for i in 0..<MemoryLayout<timeval>.size { bytes[headerSize + i] = src[i] }
        }
        return bytes
    }

    private func parse(_ control: [UInt8], len: Int? = nil) -> UInt64 {
        control.withUnsafeBytes { raw in
            UDPSocket.kernelArrivalNs(control: raw.baseAddress!, controlLen: len ?? control.count)
        }
    }

    func testCmsghdrIsTwelveBytesSoTheDataOffsetIsRight() {
        // The payload offset is align32(sizeof(cmsghdr)). If this ever stops being 12 the
        // hand-rolled offset silently reads the wrong bytes.
        XCTAssertEqual(MemoryLayout<cmsghdr>.size, 12)
    }

    func testTimestampIsDecodedToNanoseconds() {
        let tv = timeval(tv_sec: 1_700_000_000, tv_usec: 250_000)
        let ns = parse(makeControl(level: SOL_SOCKET, type: SCM_TIMESTAMP, tv: tv))
        XCTAssertEqual(ns, 1_700_000_000_250_000_000)
    }

    func testMicrosecondsContributeToTheGap() {
        let a = parse(makeControl(level: SOL_SOCKET, type: SCM_TIMESTAMP,
                                  tv: timeval(tv_sec: 100, tv_usec: 0)))
        let b = parse(makeControl(level: SOL_SOCKET, type: SCM_TIMESTAMP,
                                  tv: timeval(tv_sec: 100, tv_usec: 20_000)))
        XCTAssertEqual((b - a) / 1_000_000, 20, "20 ms apart must read as a 20 ms gap")
    }

    func testWrongLevelOrTypeIsIgnored() {
        let tv = timeval(tv_sec: 1_700_000_000, tv_usec: 0)
        XCTAssertEqual(parse(makeControl(level: IPPROTO_IP, type: SCM_TIMESTAMP, tv: tv)), 0)
        XCTAssertEqual(parse(makeControl(level: SOL_SOCKET, type: SCM_RIGHTS, tv: tv)), 0)
    }

    func testTruncatedControlBufferIsRejected() {
        let tv = timeval(tv_sec: 1_700_000_000, tv_usec: 0)
        let control = makeControl(level: SOL_SOCKET, type: SCM_TIMESTAMP, tv: tv)
        // The kernel reports how much it actually wrote; short of a full timeval, refuse.
        XCTAssertEqual(parse(control, len: 12), 0)
        XCTAssertEqual(parse(control, len: 0), 0)
    }

    func testHeaderClaimingLessThanItNeedsIsRejected() {
        let tv = timeval(tv_sec: 1_700_000_000, tv_usec: 0)
        let control = makeControl(level: SOL_SOCKET, type: SCM_TIMESTAMP, tv: tv, declaredLen: 13)
        XCTAssertEqual(parse(control), 0)
    }

    func testZeroTimestampReadsAsUnavailable() {
        // A zero return is the caller's "no kernel stamp" signal, so an all-zero control block
        // must not come back as a valid time at the epoch.
        let control = makeControl(level: SOL_SOCKET, type: SCM_TIMESTAMP,
                                  tv: timeval(tv_sec: 0, tv_usec: 0))
        XCTAssertEqual(parse(control), 0)
    }
}
