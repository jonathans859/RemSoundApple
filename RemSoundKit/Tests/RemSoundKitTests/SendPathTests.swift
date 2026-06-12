@testable import RemSoundKit
import XCTest

/// Send-path coverage: the format-payload writer against the existing reader, the
/// encryptor against the existing decryptor, and the full send engine loop — every packet
/// the engine emits must parse, decrypt, and Opus-decode with the same receive-path code
/// that handles Windows senders.
final class SendPathTests: XCTestCase {
    // MARK: - Format payload writer

    func testFormatPayloadRoundTripWithFingerprint() {
        let format = AudioFormatInfo(
            sampleRate: 48_000, channels: 2, bitsPerSample: 16, encoding: 1,
            blockAlign: 4, averageBytesPerSecond: 192_000,
            codec: .opus, frameSamplesPerChannel: 480, lane: .mixed)
        let fingerprint: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

        let payload = RemPacket.writeFormatPayload(format, passwordFingerprint: fingerprint)
        XCTAssertEqual(payload.count, RemPacket.formatPayloadWithFingerprintSize)

        let parsed = RemPacket.readFormat(ArraySlice([UInt8](payload)))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.format, format)
        XCTAssertEqual(parsed?.passwordFingerprint, fingerprint)
    }

    func testFormatPayloadWithoutFingerprintIsExtendedSize() {
        let format = AudioFormatInfo(
            sampleRate: 48_000, channels: 2, bitsPerSample: 24, encoding: 1,
            blockAlign: 6, averageBytesPerSecond: 288_000,
            codec: .pcm, frameSamplesPerChannel: 240, lane: .wasapiLane)

        let payload = RemPacket.writeFormatPayload(format, passwordFingerprint: nil)
        XCTAssertEqual(payload.count, RemPacket.formatPayloadExtendedSize)

        let parsed = RemPacket.readFormat(ArraySlice([UInt8](payload)))
        XCTAssertEqual(parsed?.format, format)
        XCTAssertNil(parsed?.passwordFingerprint)
    }

    // MARK: - Encryptor ↔ decryptor

    func testEncryptDecryptRoundTrip() {
        let key = RemSoundCrypto.deriveKey(password: "test123")
        let encryptor = AudioEncryptor()
        let decryptor = AudioDecryptor()
        encryptor.ensureKey(key)
        decryptor.ensureKey(key)

        let plaintext: [UInt8] = Array(0..<200).map { UInt8($0 % 256) }
        guard let packet = encryptor.tryEncrypt(ArraySlice(plaintext)) else {
            return XCTFail("encrypt failed")
        }
        XCTAssertEqual(packet.count, plaintext.count + RemSoundCrypto.encryptionOverheadBytes)
        XCTAssertEqual(decryptor.tryDecrypt(ArraySlice(packet)), plaintext)
    }

    func testDecryptRejectsWrongPasswordAndTampering() {
        let encryptor = AudioEncryptor()
        encryptor.ensureKey(RemSoundCrypto.deriveKey(password: "right"))
        let packet = encryptor.tryEncrypt(ArraySlice([UInt8]([9, 9, 9, 9])))!

        let wrongKey = AudioDecryptor()
        wrongKey.ensureKey(RemSoundCrypto.deriveKey(password: "wrong"))
        XCTAssertNil(wrongKey.tryDecrypt(ArraySlice(packet)))

        var tampered = packet
        tampered[tampered.count - 1] ^= 0xFF
        let rightKey = AudioDecryptor()
        rightKey.ensureKey(RemSoundCrypto.deriveKey(password: "right"))
        XCTAssertNil(rightKey.tryDecrypt(ArraySlice(tampered)))
    }

    func testEncryptorWithoutKeySendsNothing() {
        let encryptor = AudioEncryptor()
        XCTAssertNil(encryptor.tryEncrypt(ArraySlice([UInt8]([1, 2, 3]))))
    }

    // MARK: - Send engine end to end

    func testSendEngineEmitsDecodableStream() {
        let engine = AudioSendEngine()
        let key = RemSoundCrypto.deriveKey(password: "test123")
        let fingerprint = RemSoundCrypto.fingerprint(password: "test123")
        let target = UDPEndpoint(address: 0x0100_007F, port: RemPacket.defaultPort)

        var sent: [[UInt8]] = []
        engine.transport = { data, endpoint in
            XCTAssertEqual(endpoint, target)
            sent.append(data)
            return true
        }
        engine.setKeyMaterial(key: key, fingerprint: fingerprint)
        engine.setTargets([target])
        engine.start()
        XCTAssertTrue(engine.isSending)

        // 4 × 480 frames of a 440 Hz tone → four 10 ms Opus frames + one format announce.
        let frameCount = AudioSendEngine.opusFrameSamplesPerChannel
        var samples = [Float](repeating: 0, count: frameCount * 2)
        var phase = 0.0
        for _ in 0..<4 {
            for i in 0..<frameCount {
                let value = Float(sin(phase))
                samples[i * 2] = value
                samples[i * 2 + 1] = value
                phase += 2.0 * .pi * 440.0 / 48_000.0
            }
            samples.withUnsafeBufferPointer { buffer in
                engine.submit(buffer.baseAddress!, frameCount: frameCount)
            }
        }
        engine.stop()

        var formats = 0
        var audioPackets = 0
        var lastSequence: UInt32 = 0
        let decryptor = AudioDecryptor()
        decryptor.ensureKey(key)
        let decoder = OpusStreamDecoder(sampleRate: 48_000, channels: 2)!
        var pcm = [Int16]()

        for packet in sent {
            guard let header = RemPacket.readHeader(packet, length: packet.count) else {
                return XCTFail("send engine emitted an unparseable packet")
            }
            XCTAssertNotEqual(header.streamId, 0)
            switch header.type {
            case .format:
                formats += 1
                let parsed = RemPacket.readFormat(packet[RemPacket.headerSize...])
                XCTAssertEqual(parsed?.format.codec, .opus)
                XCTAssertEqual(parsed?.format.sampleRate, 48_000)
                XCTAssertEqual(parsed?.format.channels, 2)
                XCTAssertEqual(parsed?.format.frameSamplesPerChannel, frameCount)
                XCTAssertEqual(parsed?.passwordFingerprint, fingerprint)
            case .audio:
                audioPackets += 1
                XCTAssertEqual(header.sequence, lastSequence + 1, "audio sequence must be monotonic")
                lastSequence = header.sequence
                guard let opusBytes = decryptor.tryDecrypt(packet[RemPacket.headerSize...]) else {
                    return XCTFail("audio packet did not decrypt with the shared key")
                }
                let decoded = decoder.decode(opusBytes, frameSize: frameCount, fec: false, into: &pcm)
                XCTAssertEqual(decoded, frameCount)
            default:
                XCTFail("unexpected packet type \(header.rawType)")
            }
        }
        XCTAssertGreaterThanOrEqual(formats, 1, "format must be announced before audio")
        XCTAssertEqual(audioPackets, 4)
        XCTAssertEqual(sent.first.flatMap { RemPacket.readHeader($0, length: $0.count)?.type }, .format)
    }

    func testSendEngineIsSilentWithoutPassword() {
        let engine = AudioSendEngine()
        var sentCount = 0
        engine.transport = { _, _ in
            sentCount += 1
            return true
        }
        engine.setTargets([UDPEndpoint(address: 0x0100_007F, port: RemPacket.defaultPort)])
        engine.start() // no key material — mandatory encryption means nothing leaves

        let frameCount = AudioSendEngine.opusFrameSamplesPerChannel
        let samples = [Float](repeating: 0.5, count: frameCount * 2)
        samples.withUnsafeBufferPointer { buffer in
            engine.submit(buffer.baseAddress!, frameCount: frameCount)
        }
        engine.stop()
        XCTAssertEqual(sentCount, 0)
        XCTAssertFalse(engine.isSending)
    }
}
