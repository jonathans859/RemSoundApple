@testable import RemSoundKit
import XCTest

/// Send-path coverage: the format-payload writer against the existing reader, the
/// encryptor against the existing decryptor, and the full send engine loop in both codecs —
/// every packet the engine emits must parse, decrypt, and decode with the same receive-path
/// code that handles Windows senders.
final class SendPathTests: XCTestCase {
    // MARK: - Format payload writer

    func testFormatPayloadRoundTripWithFingerprint() {
        let format = AudioFormatInfo(
            sampleRate: 48_000, channels: 2, bitsPerSample: 16, encoding: 1,
            blockAlign: 4, averageBytesPerSecond: 192_000,
            codec: .opus, frameSamplesPerChannel: 480, lane: .mixed)
        let fingerprint: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

        let payload = RemPacket.writeFormatPayload(format, passwordFingerprint: fingerprint)
        // A fingerprinted payload carries the capture-latency field after it, so it is the
        // 46-byte shape. Readers take a MINIMUM length, which is why growing it is safe.
        XCTAssertEqual(payload.count, RemPacket.formatPayloadWithCaptureSize)

        let parsed = RemPacket.readFormat(ArraySlice([UInt8](payload)))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.format, format)
        XCTAssertEqual(parsed?.passwordFingerprint, fingerprint)
    }

    /// Our own capture latency rides in the format packet (upstream 2026-08-24) so the peer
    /// reports the real journey instead of substituting its own guess for a stage that
    /// happens here. uint16 of 0.1 ms ticks, immediately after the fingerprint.
    func testFormatPayloadCarriesTheCaptureLatency() {
        let format = AudioFormatInfo(
            sampleRate: 48_000, channels: 2, bitsPerSample: 16, encoding: 1,
            blockAlign: 4, averageBytesPerSecond: 192_000,
            codec: .opus, frameSamplesPerChannel: 480, lane: .mixed)
        let fingerprint: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

        let payload = [UInt8](RemPacket.writeFormatPayload(
            format, passwordFingerprint: fingerprint, captureLatencyMs: 12.3))
        XCTAssertEqual(payload.count, RemPacket.formatPayloadWithCaptureSize)
        let ticks = UInt16(payload[44]) | UInt16(payload[45]) << 8
        XCTAssertEqual(ticks, 123)

        // Without a fingerprint there is nowhere to put it — the field sits after one.
        let short = RemPacket.writeFormatPayload(format, passwordFingerprint: nil, captureLatencyMs: 12.3)
        XCTAssertEqual(short.count, RemPacket.formatPayloadExtendedSize)

        // Nothing open (or a device that will not say) is 0 on both sides, not a guess.
        let idle = [UInt8](RemPacket.writeFormatPayload(format, passwordFingerprint: fingerprint))
        XCTAssertEqual(UInt16(idle[44]) | UInt16(idle[45]) << 8, 0)
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
                XCTFail("unexpected packet type \(header.type)")
            }
        }
        XCTAssertGreaterThanOrEqual(formats, 1, "format must be announced before audio")
        XCTAssertEqual(audioPackets, 4)
        XCTAssertEqual(sent.first.flatMap { RemPacket.readHeader($0, length: $0.count)?.type }, .format)
    }

    // MARK: - PCM send path

    /// int24-LE is what PCM puts on the wire; the packer must be the exact inverse of the
    /// unpacker the receive path already uses, because the two ends of a call can be one of
    /// each implementation.
    func testPcmPackRoundTripsThroughInt24() {
        let source: [Float] = [0, 0.5, -0.5, 1, -1, 0.001, -0.001, 2, -2]
        var packed = [UInt8]()
        source.withUnsafeBufferPointer { buffer in
            PcmPack.floatToInt24LE(buffer.baseAddress!, count: source.count, into: &packed)
        }
        XCTAssertEqual(packed.count, source.count * 3)

        var unpacked = [Float]()
        PcmPack.int24LEToFloat(packed[...], into: &unpacked)
        for (index, value) in source.enumerated() {
            // Out-of-range input clamps to full scale rather than wrapping to the opposite
            // rail — a wrap would be an audible click on exactly the loudest sample.
            let clamped = min(max(value, -1), 1)
            XCTAssertEqual(unpacked[index], clamped, accuracy: 1.0 / 8_388_607.0,
                           "sample \(index) did not survive the round trip")
        }
    }

    /// The PCM twin of `testSendEngineEmitsDecodableStream`: every packet must parse,
    /// reassemble through the same `PcmFrameAssembler` a Windows sender's frames go through,
    /// decrypt, and unpack to the audio that went in.
    func testSendEngineEmitsDecodablePcmStream() {
        let engine = AudioSendEngine()
        let key = RemSoundCrypto.deriveKey(password: "test123")
        let fingerprint = RemSoundCrypto.fingerprint(password: "test123")
        let target = UDPEndpoint(address: 0x0100_007F, port: RemPacket.defaultPort)

        var sent: [[UInt8]] = []
        engine.transport = { data, _ in
            sent.append(data)
            return true
        }
        engine.setKeyMaterial(key: key, fingerprint: fingerprint)
        engine.setTargets([target])
        engine.setCodec(.pcm)
        engine.start()

        // One 10 ms capture buffer = four 2.5 ms PCM frames.
        let submitFrames = 480
        let pcmFrame = AudioSendEngine.pcmFrameSamplesPerChannel
        var samples = [Float](repeating: 0, count: submitFrames * 2)
        var expected: [Float] = []
        var phase = 0.0
        for i in 0..<submitFrames {
            let value = Float(sin(phase) * 0.8)
            samples[i * 2] = value
            samples[i * 2 + 1] = value
            expected.append(value)
            expected.append(value)
            phase += 2.0 * .pi * 440.0 / 48_000.0
        }
        samples.withUnsafeBufferPointer { buffer in
            engine.submit(buffer.baseAddress!, frameCount: submitFrames)
        }
        engine.stop()

        let decryptor = AudioDecryptor()
        decryptor.ensureKey(key)
        let assembler = PcmFrameAssembler()
        var formats = 0
        var audioPackets = 0
        var frames = 0
        var lastSequence: UInt32 = 0
        var lastFrameId: UInt32 = 0
        var decoded: [Float] = []
        var scratch = [Float]()

        for packet in sent {
            guard let header = RemPacket.readHeader(packet, length: packet.count) else {
                return XCTFail("send engine emitted an unparseable packet")
            }
            switch header.type {
            case .format:
                formats += 1
                let parsed = RemPacket.readFormat(packet[RemPacket.headerSize...])
                // The field values the Windows sender announces for PCM.
                XCTAssertEqual(parsed?.format.codec, .pcm)
                XCTAssertEqual(parsed?.format.sampleRate, 48_000)
                XCTAssertEqual(parsed?.format.channels, 2)
                XCTAssertEqual(parsed?.format.bitsPerSample, 24)
                XCTAssertEqual(parsed?.format.blockAlign, 6)
                XCTAssertEqual(parsed?.format.averageBytesPerSecond, 288_000)
                XCTAssertEqual(parsed?.format.frameSamplesPerChannel, pcmFrame)
                XCTAssertEqual(parsed?.passwordFingerprint, fingerprint)
            case .audio:
                audioPackets += 1
                XCTAssertEqual(header.sequence, lastSequence + 1, "audio sequence must be monotonic")
                lastSequence = header.sequence
                // At 2.5 ms the encrypted frame fits one datagram, which is the point of that
                // frame size: no part of a PCM frame can go missing on its own.
                XCTAssertLessThanOrEqual(
                    packet.count, RemPacket.headerSize + RemPacket.maxAudioPayloadBytes)
                guard let sub = RemPcmFrame.readSubHeader(packet[RemPacket.headerSize...]) else {
                    return XCTFail("PCM packet carried no usable sub-header")
                }
                XCTAssertEqual(sub.totalParts, 1)
                XCTAssertEqual(sub.partIndex, 0)
                XCTAssertEqual(sub.frameId, lastFrameId + 1, "frame ids must run consecutively")
                lastFrameId = sub.frameId

                let body = packet[(RemPacket.headerSize + RemPcmFrame.subHeaderSize)...]
                guard let assembled = assembler.assemble(
                    part: body, frameId: sub.frameId,
                    partIndex: sub.partIndex, totalParts: sub.totalParts)
                else {
                    return XCTFail("the receive-path assembler did not complete the frame")
                }
                guard let plain = decryptor.tryDecrypt(assembled[...]) else {
                    return XCTFail("PCM frame did not decrypt with the shared key")
                }
                XCTAssertEqual(plain.count, pcmFrame * 2 * 3)
                PcmPack.int24LEToFloat(plain[...], into: &scratch)
                decoded.append(contentsOf: scratch[0..<(pcmFrame * 2)])
                frames += 1
            default:
                XCTFail("unexpected packet type \(header.type)")
            }
        }

        XCTAssertGreaterThanOrEqual(formats, 1, "format must be announced before audio")
        XCTAssertEqual(sent.first.flatMap { RemPacket.readHeader($0, length: $0.count)?.type }, .format)
        XCTAssertEqual(frames, submitFrames / pcmFrame)
        XCTAssertEqual(audioPackets, frames, "one datagram per 2.5 ms frame")
        XCTAssertEqual(decoded.count, expected.count)
        for (index, value) in expected.enumerated() {
            XCTAssertEqual(decoded[index], value, accuracy: 1.0 / 8_388_607.0,
                           "sample \(index) came back changed")
        }
    }

    /// A codec change mid-stream must open a NEW stream, exactly like the Windows sender's
    /// `OnCodecChanged`: a receiver keys a session on (endpoint, streamId) plus the format it
    /// opened with, so reusing the id would be a format change inside a live session.
    func testCodecChangeRotatesTheStreamId() {
        let engine = AudioSendEngine()
        let key = RemSoundCrypto.deriveKey(password: "test123")
        var sent: [[UInt8]] = []
        engine.transport = { data, _ in
            sent.append(data)
            return true
        }
        engine.setKeyMaterial(key: key, fingerprint: RemSoundCrypto.fingerprint(password: "test123"))
        engine.setTargets([UDPEndpoint(address: 0x0100_007F, port: RemPacket.defaultPort)])
        engine.start()

        let frameCount = AudioSendEngine.opusFrameSamplesPerChannel
        let samples = [Float](repeating: 0.25, count: frameCount * 2)
        func submit() {
            samples.withUnsafeBufferPointer { buffer in
                engine.submit(buffer.baseAddress!, frameCount: frameCount)
            }
        }

        submit()
        let opusStream = sent.compactMap { RemPacket.readHeader($0, length: $0.count) }
            .first { $0.type == .format }?.streamId
        XCTAssertNotNil(opusStream)

        sent.removeAll()
        engine.setCodec(.pcm)
        submit()
        engine.stop()

        let headers = sent.compactMap { RemPacket.readHeader($0, length: $0.count) }
        let pcmStream = headers.first { $0.type == .format }?.streamId
        XCTAssertNotNil(pcmStream)
        XCTAssertNotEqual(pcmStream, opusStream, "the new codec must run on a new stream id")
        // Counters restart with the stream, so the receiver's loss maths starts clean too.
        XCTAssertEqual(headers.first { $0.type == .audio }?.sequence, 1)
        let format = sent.first { RemPacket.readHeader($0, length: $0.count)?.type == .format }
            .flatMap { RemPacket.readFormat($0[RemPacket.headerSize...]) }
        XCTAssertEqual(format?.format.codec, .pcm)
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
