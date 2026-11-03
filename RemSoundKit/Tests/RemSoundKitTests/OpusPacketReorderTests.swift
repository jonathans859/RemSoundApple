@testable import RemSoundKit
import XCTest

final class OpusPacketReorderTests: XCTestCase {
    private func sequences(_ events: [OpusPacketReorderBuffer.Event]) -> [UInt32] {
        events.compactMap { if case let .packet(sequence, _, _) = $0 { return sequence }; return nil }
    }

    func testReorderedPacketsAreDecodedExactlyOnceAndInOrder() {
        var queue = OpusPacketReorderBuffer()
        var events: [OpusPacketReorderBuffer.Event] = []
        for (index, sequence) in [100, 102, 101, 103].enumerated() {
            events += queue.insert(sequence: UInt32(sequence), bytes: [1], nowNs: UInt64(index) * 1_000_000)
        }
        XCTAssertEqual(sequences(events), [100, 101, 102, 103])
        XCTAssertEqual(events.filter { if case .missing = $0 { return true }; return false }.count, 0)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testBufferedAndAlreadyPlayedDuplicatesCannotRewind() {
        var queue = OpusPacketReorderBuffer()
        _ = queue.insert(sequence: 1, bytes: [1], nowNs: 0)
        _ = queue.insert(sequence: 3, bytes: [3], nowNs: 0)
        XCTAssertEqual(queue.insert(sequence: 3, bytes: [3], nowNs: 1), [.ignored])
        XCTAssertEqual(queue.insert(sequence: 1, bytes: [1], nowNs: 2), [.ignored])
        XCTAssertEqual(sequences(queue.insert(sequence: 2, bytes: [2], nowNs: 3)), [2, 3])
        XCTAssertEqual(queue.nextSequence, 4)
    }

    func testDeadlineIsDrainedWithoutAnotherNetworkPacket() {
        var queue = OpusPacketReorderBuffer()
        _ = queue.insert(sequence: 100, bytes: [1], nowNs: 0)
        _ = queue.insert(sequence: 102, bytes: [2], nowNs: 1_000_000)
        XCTAssertTrue(queue.drain(nowNs: 60_000_000).isEmpty)
        XCTAssertEqual(queue.drain(nowNs: 61_000_000), [
            .missing(count: 1, nextPacket: [2]),
            .packet(sequence: 102, bytes: [2], reordered: true),
        ])
        XCTAssertEqual(queue.insert(sequence: 101, bytes: [1], nowNs: 62_000_000), [.ignored])
        XCTAssertEqual(sequences(queue.insert(sequence: 103, bytes: [3], nowNs: 63_000_000)), [103])
    }

    func testSequenceWrapIsOrdered() {
        var queue = OpusPacketReorderBuffer()
        var events = queue.insert(sequence: UInt32.max - 1, bytes: [1], nowNs: 0)
        events += queue.insert(sequence: 0, bytes: [3], nowNs: 1)
        events += queue.insert(sequence: UInt32.max, bytes: [2], nowNs: 2)
        XCTAssertEqual(sequences(events), [UInt32.max - 1, UInt32.max, 0])
    }

    func testLargeJumpDoesNotAllocateAnUnboundedQueueOrMissingRun() {
        var queue = OpusPacketReorderBuffer()
        _ = queue.insert(sequence: 1, bytes: [1], nowNs: 0)
        let events = queue.insert(sequence: 100_000, bytes: [2], nowNs: 1)
        XCTAssertEqual(events, [.resynchronized, .packet(sequence: 100_000, bytes: [2], reordered: false)])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testSustainedOneInFourReorderingHasNoLossOrExtraAudioSlots() {
        var queue = OpusPacketReorderBuffer()
        var output: [UInt32] = []
        var missing = 0
        for base in stride(from: 0, to: 24_000, by: 4) {
            for offset in [0, 2, 1, 3] {
                let events = queue.insert(sequence: UInt32(base + offset), bytes: [1],
                                          nowNs: UInt64(base) * 2_500_000)
                output += sequences(events)
                for event in events { if case let .missing(count, _) = event { missing += count } }
            }
        }
        XCTAssertEqual(output, (0..<24_000).map(UInt32.init))
        XCTAssertEqual(missing, 0)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testMultipleMissingPacketsReportedOnce() {
        var queue = OpusPacketReorderBuffer()
        _ = queue.insert(sequence: 10, bytes: [1], nowNs: 0)
        _ = queue.insert(sequence: 14, bytes: [2], nowNs: 1)
        let events = queue.drain(nowNs: 100_000_000)
        XCTAssertEqual(events.first, .missing(count: 3, nextPacket: [2]))
        XCTAssertEqual(sequences(events), [14])
        XCTAssertTrue(queue.drain(nowNs: 200_000_000).isEmpty)
    }

    func testCounterRestartFarBehindResynchronizesInsteadOfMuting() {
        var queue = OpusPacketReorderBuffer()
        _ = queue.insert(sequence: 50_000, bytes: [1], nowNs: 0)
        // A late packet stays ignored...
        XCTAssertEqual(queue.insert(sequence: 49_990, bytes: [9], nowNs: 1), [.ignored])
        // ...but a sender restarting its counter under the same streamId is followed.
        XCTAssertEqual(queue.insert(sequence: 0, bytes: [2], nowNs: 2),
                       [.resynchronized, .packet(sequence: 0, bytes: [2], reordered: false)])
        XCTAssertEqual(sequences(queue.insert(sequence: 1, bytes: [3], nowNs: 3)), [1])
    }

    func testHoldIsHalfThePlayoutTargetWithinBounds() {
        XCTAssertEqual(OpusPacketReorderBuffer.holdMilliseconds(targetLatencyMs: 5), 5)
        XCTAssertEqual(OpusPacketReorderBuffer.holdMilliseconds(targetLatencyMs: 30), 15)
        XCTAssertEqual(OpusPacketReorderBuffer.holdMilliseconds(targetLatencyMs: 80), 40)
        XCTAssertEqual(OpusPacketReorderBuffer.holdMilliseconds(targetLatencyMs: 500), 60)
    }
}

final class ReorderedOpusPipelineTests: XCTestCase {
    private let key = [UInt8](repeating: 7, count: 32)

    private func makePackets() throws -> [[UInt8]] {
        let encoder = try XCTUnwrap(OpusStreamEncoder(frameSizePerChannel: 120))
        let encryptor = AudioEncryptor()
        encryptor.ensureKey(key)
        return try (0..<4).map { packet in
            var pcm = [Float](repeating: 0, count: 240)
            for i in 0..<120 {
                let value = Float(sin(Double(packet * 120 + i) * 2 * .pi * 440 / 48_000)) * 0.2
                pcm[i*2] = value
                pcm[i*2+1] = value
            }
            let encoded = try pcm.withUnsafeBufferPointer { ptr in
                Array(try XCTUnwrap(encoder.encode(ptr.baseAddress!)))
            }
            return try XCTUnwrap(encryptor.tryEncrypt(encoded[...]))
        }
    }

    private func makeReceiver(targetLatencyMs: Int = 5) -> (StreamSession, SessionPlayout, StreamDiagnostics) {
        let decryptor = AudioDecryptor()
        decryptor.ensureKey(key)
        let endpoint = UDPEndpoint(host: "127.0.0.1", port: 47830)!
        let playout = SessionPlayout(endpoint: endpoint, streamId: 1, targetLatencyMs: targetLatencyMs)
        let format = AudioFormatInfo(sampleRate: 48_000, channels: 2, bitsPerSample: 16,
            encoding: 1, blockAlign: 4, averageBytesPerSecond: 192_000, codec: .opus,
            frameSamplesPerChannel: 120, lane: .mixed)
        let diagnostics = StreamDiagnostics()
        let session = StreamSession(endpoint: endpoint, streamId: 1, format: format,
            playout: playout, decryptor: decryptor, diagnostics: diagnostics)
        return (session, playout, diagnostics)
    }

    /// Real encryption, libopus encoder/decoder, and playout buffer. A reordered
    /// delivery must produce the SAME samples as in-order delivery, not just
    /// plausible packet counters. No sockets or audio devices are opened.
    func testRealOpusReorderingMatchesOrderedWaveformWithoutExtraAudio() throws {
        let packets = try makePackets()
        func receive(_ order: [Int]) -> (SessionPlayout, StreamDiagnostics) {
            let (session, playout, diagnostics) = makeReceiver()
            for i in order { session.handleAudioPayload(sequence: UInt32(100 + i), payload: packets[i][...]) }
            return (playout, diagnostics)
        }
        let (ordered, _) = receive([0,1,2,3])
        let (reordered, stats) = receive([0,2,1,3])
        XCTAssertEqual(ordered.bufferedMs, 10)
        XCTAssertEqual(reordered.bufferedMs, 10)
        var reference = [Float](repeating: 0, count: 960)
        var actual = reference
        reference.withUnsafeMutableBufferPointer { ordered.readAdd(into: $0.baseAddress!, frames: 480) }
        actual.withUnsafeMutableBufferPointer { reordered.readAdd(into: $0.baseAddress!, frames: 480) }
        XCTAssertTrue(reference.contains { abs($0) > 0.001 }, "The waveform comparison must not only compare silence")
        XCTAssertEqual(actual, reference)
        XCTAssertEqual(stats.snapshot().reorderDeadlineMisses, 0)
        XCTAssertEqual(stats.snapshot().decodeErrors, 0)
        XCTAssertEqual(stats.snapshot().reorderedPackets, 1)
    }

    func testRealOpusDuplicatesNeverAddAudioOrRewindTheDecoder() throws {
        let packets = try makePackets()
        let (session, playout, stats) = makeReceiver()
        for i in [0, 2, 2, 1, 0, 3, 3] {
            session.handleAudioPayload(sequence: UInt32(100 + i), payload: packets[i][...])
        }
        XCTAssertEqual(playout.bufferedMs, 10)
        XCTAssertEqual(stats.snapshot().staleOrDuplicatePackets, 3)
        XCTAssertEqual(stats.snapshot().decodeErrors, 0)
    }

    func testMissingCeltPacketIsConcealedOnceAndLateArrivalIsIgnored() throws {
        let packets = try makePackets()
        let (session, playout, stats) = makeReceiver()
        session.handleAudioPayload(sequence: 100, payload: packets[0][...])
        session.handleAudioPayload(sequence: 102, payload: packets[2][...])
        XCTAssertEqual(playout.bufferedMs, 2) // bufferedMs rounds down
        session.flushPendingOpus(nowNs: .max)
        XCTAssertEqual(playout.bufferedMs, 7)
        XCTAssertEqual(stats.snapshot().opusMode, .celt)
        XCTAssertEqual(stats.snapshot().reorderDeadlineMisses, 1)
        XCTAssertEqual(stats.snapshot().concealedPacketSlots, 1)
        session.handleAudioPayload(sequence: 101, payload: packets[1][...])
        session.flushPendingOpus(nowNs: .max)
        XCTAssertEqual(playout.bufferedMs, 7)
        session.handleAudioPayload(sequence: 103, payload: packets[3][...])
        XCTAssertEqual(playout.bufferedMs, 10)
        XCTAssertEqual(stats.snapshot().staleOrDuplicatePackets, 1)
        XCTAssertEqual(stats.snapshot().decodeErrors, 0)
    }

    func testLongGapBoundsRealOpusConcealmentToOneHundredMilliseconds() throws {
        let packets = try makePackets()
        let (session, playout, stats) = makeReceiver()
        session.handleAudioPayload(sequence: 100, payload: packets[0][...])
        session.handleAudioPayload(sequence: 202, payload: packets[1][...])
        session.flushPendingOpus(nowNs: .max)
        XCTAssertEqual(playout.bufferedMs, 105) // two real 2.5 ms packets + 100 ms PLC
        XCTAssertEqual(stats.snapshot().reorderDeadlineMisses, 101)
        XCTAssertEqual(stats.snapshot().concealedPacketSlots, 40)
        XCTAssertEqual(stats.snapshot().decoderResyncs, 1)
        XCTAssertEqual(stats.snapshot().decodeErrors, 0)
        // The concealment runs on the decoder that heard the real audio, so it continues
        // the signal; a decoder reset before concealing would only produce silence.
        var head = [Float](repeating: 0, count: 480)
        head.withUnsafeMutableBufferPointer { playout.readAdd(into: $0.baseAddress!, frames: 240) }
        XCTAssertTrue(head[240...].contains { abs($0) > 0.001 }, "First concealed slot must not be silence")
    }

    /// At the default 80 ms target the hold is 40 ms: a gap must still be waiting at 30 ms
    /// and released by 41 ms, leaving half the buffer as cushion for a real loss.
    func testHoldFollowsThePlayoutTarget() throws {
        let packets = try makePackets()
        let (session, playout, stats) = makeReceiver(targetLatencyMs: 80)
        let before = DispatchTime.now().uptimeNanoseconds
        session.handleAudioPayload(sequence: 100, payload: packets[0][...])
        session.handleAudioPayload(sequence: 102, payload: packets[2][...])
        let after = DispatchTime.now().uptimeNanoseconds
        session.flushPendingOpus(nowNs: before + 30_000_000)
        XCTAssertEqual(stats.snapshot().reorderDeadlineMisses, 0)
        XCTAssertEqual(playout.bufferedMs, 2)
        session.flushPendingOpus(nowNs: after + 41_000_000)
        XCTAssertEqual(stats.snapshot().reorderDeadlineMisses, 1)
        XCTAssertEqual(playout.bufferedMs, 7)
    }
}
