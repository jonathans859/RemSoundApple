@testable import RemSoundKit
import XCTest

/// Pins the packet classifier. These counters are the only thing that distinguishes network
/// loss from network jitter in the field, so a miscount here would send a diagnosis the wrong
/// way — e.g. reporting reordering as loss, which points at sender-side redundancy when the
/// real fix is buffer depth.
final class ArrivalTrackerTests: XCTestCase {
    private func track(_ sequences: [UInt32], kernelTimed: Bool = false) -> StreamDiagnosticsSnapshot {
        let diagnostics = StreamDiagnostics()
        var tracker = ArrivalTracker()
        for (index, sequence) in sequences.enumerated() {
            // Kernel stamps are wall-clock nanoseconds; 20 ms apart mimics the real cadence.
            let kernelNs = kernelTimed ? UInt64(1_700_000_000_000_000_000 + index * 20_000_000) : 0
            tracker.record(sequence: sequence, kernelArrivalNs: kernelNs, into: diagnostics)
        }
        return diagnostics.snapshot()
    }

    func testConsecutiveSequencesReportNoLoss() {
        let stats = track([10, 11, 12, 13, 14])
        XCTAssertEqual(stats.audioPacketsReceived, 5)
        XCTAssertEqual(stats.packetsLost, 0)
        XCTAssertEqual(stats.packetsLate, 0)
        XCTAssertEqual(stats.packetsDuplicate, 0)
    }

    func testGapCountsTheMissingPacketsNotTheEvent() {
        // 11, 12 and 13 never arrived: three lost, one gap.
        let stats = track([10, 14])
        XCTAssertEqual(stats.packetsLost, 3)
        XCTAssertEqual(stats.resyncs, 0)
    }

    func testReorderedPacketCountsLateAndDoesNotBecomeLoss() {
        // 12 overtakes 11. Without holding lastSequence at the newer value, the following
        // in-order packet would be scored as a large forward gap.
        let stats = track([10, 12, 11, 13])
        XCTAssertEqual(stats.packetsLate, 1)
        XCTAssertEqual(stats.packetsLost, 1) // the 11 that 12 skipped
        XCTAssertEqual(stats.packetsDuplicate, 0)
    }

    func testDuplicateIsCountedSeparatelyFromLoss() {
        let stats = track([10, 11, 11, 12])
        XCTAssertEqual(stats.packetsDuplicate, 1)
        XCTAssertEqual(stats.packetsLost, 0)
    }

    func testImplausibleForwardJumpIsAResyncNotMillionsOfLostPackets() {
        let stats = track([10, 900_000])
        XCTAssertEqual(stats.resyncs, 1)
        XCTAssertEqual(stats.packetsLost, 0)
    }

    func testKernelStampsDriveTheGapWhenPresent() {
        // 20 ms apart on the kernel clock: nothing may land in the over-30 ms bin, however
        // long this thread actually took between calls.
        let stats = track([1, 2, 3, 4, 5], kernelTimed: true)
        XCTAssertTrue(stats.usingKernelTimestamps)
        XCTAssertEqual(stats.gapsOver30ms, 0)
        XCTAssertEqual(stats.gapsOver60ms, 0)
        XCTAssertEqual(stats.gapsOver100ms, 0)
    }

    func testTheTwoClocksAreNeverSubtractedFromEachOther() {
        // Kernel stamps are wall-clock, the fallback is monotonic uptime — differencing
        // across them would yield a garbage gap (decades, or a wrap). A packet arriving
        // without a stamp must therefore contribute no kernel-timed gap at all.
        let diagnostics = StreamDiagnostics()
        var tracker = ArrivalTracker()
        let base: UInt64 = 1_700_000_000_000_000_000
        tracker.record(sequence: 1, kernelArrivalNs: base, into: diagnostics)
        tracker.record(sequence: 2, kernelArrivalNs: 0, into: diagnostics)          // stamp missing
        tracker.record(sequence: 3, kernelArrivalNs: base + 40_000_000, into: diagnostics)
        let stats = diagnostics.snapshot()
        XCTAssertEqual(stats.audioPacketsReceived, 3)
        XCTAssertEqual(stats.gapsOver100ms, 0, "a clock switch must not manufacture a huge gap")
        XCTAssertEqual(stats.packetsLost, 0)
    }

    func testSequenceWrapAroundIsNotSeenAsLoss() {
        let stats = track([UInt32.max - 1, UInt32.max, 0, 1])
        XCTAssertEqual(stats.packetsLost, 0)
        XCTAssertEqual(stats.resyncs, 0)
        XCTAssertEqual(stats.packetsLate, 0)
    }
}

/// The TOC check is the whole point of the codec-mode line: inband FEC is a SILK feature, so
/// a CELT-only stream cannot carry redundancy regardless of the encoder's FEC flag.
final class OpusPacketModeTests: XCTestCase {
    private func mode(config: UInt8) -> OpusPacketMode {
        OpusPacketMode.fromTOC(config << 3)
    }

    func testSilkConfigurations() {
        XCTAssertEqual(mode(config: 0), .silk)
        XCTAssertEqual(mode(config: 11), .silk)
    }

    func testHybridConfigurations() {
        XCTAssertEqual(mode(config: 12), .hybrid)
        XCTAssertEqual(mode(config: 15), .hybrid)
    }

    func testCeltConfigurations() {
        XCTAssertEqual(mode(config: 16), .celt)
        XCTAssertEqual(mode(config: 31), .celt)
    }

    func testLowBitsOfTheTocDoNotAffectTheMode() {
        // Bit 2 is the stereo flag, bits 1-0 the frame count code — neither selects the mode.
        XCTAssertEqual(OpusPacketMode.fromTOC((31 << 3) | 0b111), .celt)
        XCTAssertEqual(OpusPacketMode.fromTOC((0 << 3) | 0b111), .silk)
    }
}
