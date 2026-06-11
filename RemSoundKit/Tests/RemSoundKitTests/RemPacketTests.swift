@testable import RemSoundKit
import XCTest

final class RemPacketTests: XCTestCase {
    func testHeaderRoundtrip() {
        let data = RemPacket.writeHeader(type: .heartbeat, streamId: 0xFFFF, sequence: 123_456_789)
        XCTAssertEqual(data.count, RemPacket.headerSize)
        let header = RemPacket.readHeader([UInt8](data), length: data.count)
        XCTAssertNotNil(header)
        XCTAssertEqual(header?.type, .heartbeat)
        XCTAssertEqual(header?.streamId, 0xFFFF)
        XCTAssertEqual(header?.sequence, 123_456_789)
    }

    func testHeaderWireBytesMatchWindowsLayout() {
        // 'RMND' magic, version 1, type Audio=2, streamId 0x0102 LE, sequence 0x01020304 LE.
        let data = RemPacket.writeHeader(type: .audio, streamId: 0x0102, sequence: 0x0102_0304)
        XCTAssertEqual([UInt8](data), [
            0x52, 0x4D, 0x4E, 0x44, // R M N D
            0x01, 0x02,
            0x02, 0x01,
            0x04, 0x03, 0x02, 0x01,
        ])
    }

    func testHeaderRejectsBadMagicAndVersion() {
        var good = [UInt8](RemPacket.writeHeader(type: .audio, streamId: 1, sequence: 1))
        XCTAssertNotNil(RemPacket.readHeader(good, length: good.count))
        var badMagic = good
        badMagic[0] = 0x00
        XCTAssertNil(RemPacket.readHeader(badMagic, length: badMagic.count))
        good[4] = 2 // wire version 2 (relay lobby protocol) must be rejected by this receiver
        XCTAssertNil(RemPacket.readHeader(good, length: good.count))
        XCTAssertNil(RemPacket.readHeader([0x52, 0x4D], length: 2))
    }

    func testStreamIdZeroCoercesToOne() {
        var bytes = [UInt8](RemPacket.writeHeader(type: .audio, streamId: 5, sequence: 0))
        bytes[6] = 0
        bytes[7] = 0
        XCTAssertEqual(RemPacket.readHeader(bytes, length: bytes.count)?.streamId, 1)
    }

    private func makeFormatPayload(size: Int) -> [UInt8] {
        func le32(_ value: Int32) -> [UInt8] {
            let v = UInt32(bitPattern: value)
            return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        var payload: [UInt8] = []
        payload += le32(48000) // sampleRate
        payload += le32(2)     // channels
        payload += le32(24)    // bitsPerSample
        payload += le32(1)     // encoding (PCM)
        payload += le32(6)     // blockAlign
        payload += le32(288_000) // averageBytesPerSecond
        payload += le32(2)     // codec (Opus)
        payload += le32(480)   // frameSamplesPerChannel (10 ms at 48 kHz)
        if size >= RemPacket.formatPayloadExtendedSize {
            payload += [1, 0, 0, 0] // lane WasapiLane + reserved
        }
        if size >= RemPacket.formatPayloadWithFingerprintSize {
            payload += [1, 2, 3, 4, 5, 6, 7, 8]
        }
        return payload
    }

    func testFormatPayloadLegacy32Bytes() {
        let result = RemPacket.readFormat(makeFormatPayload(size: 32)[...])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format.sampleRate, 48000)
        XCTAssertEqual(result?.format.channels, 2)
        XCTAssertEqual(result?.format.codec, .opus)
        XCTAssertEqual(result?.format.frameSamplesPerChannel, 480)
        XCTAssertEqual(result?.format.lane, .mixed) // legacy defaults to Mixed
        XCTAssertNil(result?.passwordFingerprint)   // pre-encryption sender
    }

    func testFormatPayloadExtended36Bytes() {
        let result = RemPacket.readFormat(makeFormatPayload(size: 36)[...])
        XCTAssertEqual(result?.format.lane, .wasapiLane)
        XCTAssertNil(result?.passwordFingerprint)
    }

    func testFormatPayloadWithFingerprint44Bytes() {
        let result = RemPacket.readFormat(makeFormatPayload(size: 44)[...])
        XCTAssertEqual(result?.format.lane, .wasapiLane)
        XCTAssertEqual(result?.passwordFingerprint, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testFormatPayloadUnknownLaneClampsToMixed() {
        var payload = makeFormatPayload(size: 36)
        payload[32] = 99 // future lane value
        XCTAssertEqual(RemPacket.readFormat(payload[...])?.format.lane, .mixed)
    }

    func testFormatPayloadTooShortRejected() {
        XCTAssertNil(RemPacket.readFormat(makeFormatPayload(size: 32)[0..<31]))
    }

    func testHeartbeatPayloadRoundtrip() {
        let data = RemPacket.writeHeartbeatPayload(kind: .pong, originatorTickMs: 9_876_543_210)
        XCTAssertEqual(data.count, RemPacket.heartbeatPayloadSize)
        let parsed = RemPacket.readHeartbeat([UInt8](data)[...])
        XCTAssertEqual(parsed?.kind, .pong)
        XCTAssertEqual(parsed?.originatorTickMs, 9_876_543_210)
    }

    func testPcmSubHeader() {
        let bytes: [UInt8] = [0x39, 0x30, 0x00, 0x00, 0x01, 0x02] // frameId 12345, part 1/2
        let parsed = RemPcmFrame.readSubHeader(bytes[...])
        XCTAssertEqual(parsed?.frameId, 12345)
        XCTAssertEqual(parsed?.partIndex, 1)
        XCTAssertEqual(parsed?.totalParts, 2)
        // partIndex >= totalParts is malformed
        XCTAssertNil(RemPcmFrame.readSubHeader([0, 0, 0, 0, 2, 2][...]))
        XCTAssertNil(RemPcmFrame.readSubHeader([0, 0, 0, 0, 0, 0][...]))
    }

    func testDiscoveryMessageUsesWindowsJsonKeys() throws {
        let message = DiscoveryMessage(
            InstanceId: UUID(), Name: "Test", AudioPort: 47830, CanSend: false, CanReceive: true)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        // System.Text.Json on the Windows side matches case-sensitively; these exact keys
        // are the wire contract.
        XCTAssertEqual(Set(json.keys), ["InstanceId", "Name", "AudioPort", "CanSend", "CanReceive"])
        XCTAssertEqual(json["AudioPort"] as? Int, 47830)
        XCTAssertEqual(json["CanReceive"] as? Bool, true)
    }
}
