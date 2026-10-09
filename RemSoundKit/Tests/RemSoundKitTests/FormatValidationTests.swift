@testable import RemSoundKit
import XCTest

/// Pins the fail-closed format check (upstream audit finding R4, `AudioFormatInfo.IsUsable`)
/// and that what Windows 6.0/6.1 added to the wire stays harmless here: codec 3, the flags
/// byte at format offset 33, the ten-byte heartbeat, and packet types 11 and 12.
final class FormatValidationTests: XCTestCase {
    private let sender = UDPEndpoint(host: "192.168.1.50", port: 41000)!

    private func format(rate: Int = 48_000, channels: Int = 2, codec: AudioTransportCodec = .opus,
                        frame: Int = 480) -> AudioFormatInfo {
        AudioFormatInfo(sampleRate: rate, channels: channels, bitsPerSample: 16, encoding: 1,
                        blockAlign: 4, averageBytesPerSecond: 192_000, codec: codec,
                        frameSamplesPerChannel: frame, lane: .mixed)
    }

    private func packet(_ payload: [UInt8], type: RemPacketType = .format) -> [UInt8] {
        [UInt8](RemPacket.writeHeader(type: type, streamId: 5, sequence: 0)) + payload
    }

    private func payload(of format: AudioFormatInfo) -> [UInt8] {
        [UInt8](RemPacket.writeFormatPayload(format, passwordFingerprint: nil))
    }

    func testWhatEveryRemSoundSendsIsUsable() {
        XCTAssertNil(format().unusableReason)
        XCTAssertNil(format(codec: .pcm, frame: 120).unusableReason)
        XCTAssertNil(format(codec: .pcm, frame: 233).unusableReason) // Windows' 6.0 standard PCM frame
        XCTAssertNil(format(channels: 1, frame: 2880).unusableReason)
        XCTAssertNil(format(rate: 44_100, codec: .pcm).unusableReason)
    }

    func testValuesNoRemSoundSendsAreRefused() {
        XCTAssertNotNil(format(channels: 0).unusableReason, "zero channels divides by zero")
        XCTAssertNotNil(format(channels: 6).unusableReason)
        XCTAssertNotNil(format(rate: 0).unusableReason)
        XCTAssertNotNil(format(frame: 0).unusableReason)
        XCTAssertNotNil(format(frame: 1_000_000).unusableReason, "sizes the decode scratch")
        XCTAssertNotNil(format(rate: 44_100, codec: .opus).unusableReason, "libopus has no 44.1 kHz")
    }

    func testAnUnusableFormatOpensNoSession() {
        let engine = AudioReceiverEngine()
        engine.handlePacketForTesting(packet(payload(of: format(channels: 0))), from: sender)
        XCTAssertTrue(engine.liveSessionsForTesting.isEmpty)
        engine.handlePacketForTesting(packet(payload(of: format())), from: sender)
        XCTAssertEqual(engine.liveSessionsForTesting.count, 1, "and a good one still does")
    }

    /// Codec 3 is Windows 6.0's Jamulus-style custom-mode Opus. It used to read back as PCM
    /// here, which would have played it as raw noise.
    func testCodecThreeIsNotAFormatWeRead() {
        var bytes = payload(of: format())
        bytes[24] = 3
        XCTAssertNil(RemPacket.readFormat(bytes[...]))

        let engine = AudioReceiverEngine()
        engine.handlePacketForTesting(packet(bytes), from: sender)
        XCTAssertTrue(engine.liveSessionsForTesting.isEmpty)
    }

    /// Windows 6.0 puts capability flags at format offset 33 (a reserved byte before). They
    /// must change nothing about how we read the rest.
    func testTheFlagsByteAtOffsetThirtyThreeIsIgnored() {
        var bytes = payload(of: format())
        bytes[33] = 1
        XCTAssertEqual(RemPacket.readFormat(bytes[...])?.format, format())
    }

    /// Windows 6.0 heartbeats carry a tenth byte (flags) while it can take Jamulus-style
    /// frames. Readers take a minimum length, so it is ignored — a peer must not turn
    /// "unreachable" because its pings grew.
    func testATenByteHeartbeatStillReads() {
        let bytes = [UInt8](RemPacket.writeHeartbeatPayload(kind: .ping, originatorTickMs: 42)) + [1]
        let parsed = RemPacket.readHeartbeat(bytes[...])
        XCTAssertEqual(parsed?.kind, .ping)
        XCTAssertEqual(parsed?.originatorTickMs, 42)
    }

    /// The metronome (12) and the server-only types (13-15) are types this port does not know;
    /// an unknown type must be dropped at the header, never misread as something else. (Tick
    /// proofs, 11, are read — `TickProofTests`.)
    func testNewPacketTypesAreDroppedAtTheHeader() {
        for type: UInt8 in [12, 13, 14, 15] {
            var bytes = [UInt8](RemPacket.writeHeader(type: .format, streamId: 0xFFFF, sequence: 0))
            bytes[5] = type
            bytes += [UInt8](repeating: 0, count: 53)
            XCTAssertNil(RemPacket.readHeader(bytes, length: bytes.count), "type \(type)")
        }
    }
}
