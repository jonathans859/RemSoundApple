@testable import RemSoundKit
import XCTest

/// Pins the ported Windows auto-tune algorithm. The constants and the shape of the decision
/// are a cross-implementation contract: if these drift, the two receivers settle at different
/// latencies on the same link, which is exactly the kind of divergence that is invisible until
/// someone compares them side by side.
final class LatencyAutoTuneTests: XCTestCase {
    private func input(
        gaps: [Int],
        renderGaps: [Int]? = nil,
        frameMs: Int = 20,
        current: Int = 30,
        underrunDelta: Int64 = 0,
        deferring: Bool = false
    ) -> LatencyAutoTune.Input {
        let renders = renderGaps ?? Array(repeating: 5, count: gaps.count)
        let samples = zip(gaps, renders).map {
            LatencyAutoTune.Sample(arrivalGapMs: $0.0, renderGapMs: $0.1)
        }
        return .init(
            samples: samples,
            frameMs: frameMs,
            currentTargetMs: current,
            minTargetMs: ReceiverSettings.minTargetLatencyMs,
            maxTargetMs: ReceiverSettings.maxTargetLatencyMs,
            tuneBlockingUnderrunDelta: underrunDelta,
            deferring: deferring)
    }

    func testNeedsAtLeastTwoSamples() {
        XCTAssertEqual(LatencyAutoTune.decide(input(gaps: [200])), .hold(reason: .notEnoughHistory))
    }

    func testTuneBlockingUnderrunsBlockAnyMove() {
        // The buffer just proved it is too thin; upstream refuses to act on a stale window.
        let decision = LatencyAutoTune.decide(input(gaps: [10, 10, 10], current: 200, underrunDelta: 4))
        XCTAssertEqual(decision, .hold(reason: .underrunsSinceLastTick(4)))
    }

    func testDeviceGulpsDoNotBlockLowering() {
        // Device-gulp short reads never reach the tuner (the caller passes only the
        // tune-blocking delta), so a quiet link still walks the target down.
        let decision = LatencyAutoTune.decide(input(gaps: [10, 10, 10], current: 200, underrunDelta: 0))
        XCTAssertEqual(decision, .retarget(ms: 195))
    }

    func testDefersToARecentUserChange() {
        let decision = LatencyAutoTune.decide(input(gaps: [300, 300], deferring: true))
        XCTAssertEqual(decision, .hold(reason: .deferringToRecentChange))
    }

    func testLoneSpikeIsIgnoredViaSecondHighest() {
        // One catastrophic second among calm ones must not drive the recommendation — this is
        // the upstream fix where a single 1046 ms gap drove the buffer to the cap.
        let decision = LatencyAutoTune.decide(input(gaps: [10, 10, 1046, 10, 10], current: 30))
        // Second-highest gap is 10 → 10 + 5 render + 5 safety = 20, below the 30 ms codec
        // floor for 20 ms frames, so it holds rather than chasing the spike.
        XCTAssertEqual(decision, .hold(reason: .withinHysteresis(recommended: 30)))
    }

    func testSustainedJitterRaisesImmediatelyAndInFull() {
        // Jitter present in two or more seconds counts at full strength, and a raise is not
        // rate-limited: the buffer is already failing.
        let decision = LatencyAutoTune.decide(input(gaps: [120, 120, 10], current: 30))
        XCTAssertEqual(decision, .retarget(ms: 130)) // 120 + 5 render + 5 safety
    }

    func testLoweringIsRateLimitedToFiveMsPerTick() {
        let decision = LatencyAutoTune.decide(input(gaps: [10, 10], current: 100))
        XCTAssertEqual(decision, .retarget(ms: 95))
    }

    func testRecommendationIsCappedAtTwoHundredMs() {
        let decision = LatencyAutoTune.decide(input(gaps: [900, 900], current: 30))
        XCTAssertEqual(decision, .retarget(ms: LatencyAutoTune.recommendationCapMs))
    }

    func testCodecFloorKeepsTheTargetAboveOnePacket() {
        // 20 ms frames → floor 30 ms. A perfectly calm link must not walk below it, because
        // the buffer is fed a whole frame at a time.
        var current = 60
        for _ in 0..<20 {
            guard case .retarget(let ms) = LatencyAutoTune.decide(input(gaps: [0, 0], current: current)) else { break }
            current = ms
        }
        XCTAssertEqual(current, 30)
    }

    func testHysteresisStopsSubFiveMsTwitching() {
        // Recommended 30 vs current 32 is a 2 ms move — not worth touching the buffer for.
        let decision = LatencyAutoTune.decide(input(gaps: [0, 0], current: 32))
        XCTAssertEqual(decision, .hold(reason: .withinHysteresis(recommended: 30)))
    }

    func testRenderCallbackGapIsAddedSoASlowDeviceIsNotReadAsNetworkJitter() {
        let quiet = LatencyAutoTune.decide(input(gaps: [40, 40], renderGaps: [5, 5], current: 30))
        let chunky = LatencyAutoTune.decide(input(gaps: [40, 40], renderGaps: [25, 25], current: 30))
        XCTAssertEqual(quiet, .retarget(ms: 50))
        XCTAssertEqual(chunky, .retarget(ms: 70))
    }

    func testOnlyTheMostRecentLookbackWindowCounts() {
        // Old distress must age out: 20 calm seconds after a bad patch should lower, not hold.
        let gaps = [400, 400] + Array(repeating: 5, count: LatencyAutoTune.lookbackSeconds)
        let decision = LatencyAutoTune.decide(input(gaps: gaps, current: 120))
        XCTAssertEqual(decision, .retarget(ms: 115))
    }
}
