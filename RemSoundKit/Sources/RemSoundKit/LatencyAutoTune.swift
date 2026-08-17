import Foundation

/// Continuous latency auto-tune — a port of the Windows receiver's "Continuous auto-tune
/// latency" (`MainForm.TickRoute`), which walks the playout target to whatever the link
/// currently needs instead of leaving it pinned wherever the user last set it.
///
/// Why this exists: the delay control is labelled "Maximum delay" but has always behaved as a
/// fixed arm target. On a jittery path that is the worst of both worlds — the buffer re-arms at
/// the same value that just failed, so it sits permanently at the edge (`SessionPlayout` arms
/// at `targetFrames` and disarms on a sustained underrun), while the trim margin lets the real
/// occupancy float far above the number on the slider anyway. Upstream solved this in 2026-05
/// and refined it in 2026-06; this mirrors the resulting algorithm rather than inventing one.
///
/// Deliberately NOT ported: the per-route (WASAPI/ASIO lane) split, which needs Windows' dual
/// render backends. This port has a single mixed output, so there is one tuner.
///
/// The tuner is pure: `tick` takes a snapshot of the observed state and returns a decision.
/// That keeps the algorithm testable without an audio device or a network — CI has neither.
struct LatencyAutoTune {
    // Constants mirrored verbatim from upstream. Changing any of them makes this port behave
    // differently from the Windows receiver on the same link, so treat them as a contract.

    /// Floor for the measured render-callback period, so a first sample can't read as 0 ms.
    static let renderPeriodFloorMs = 2
    /// Headroom added on top of the observed jitter.
    static let safetyMarginMs = 5
    /// Don't move the target for less than this — stops the value twitching every tick.
    static let hysteresisMs = 5
    /// Ceiling on what the tuner may recommend on its own.
    static let recommendationCapMs = 200
    /// Raises are applied in full and immediately; lowering is rate-limited to this per tick,
    /// so recovering latency after a bad patch is gradual and inaudible.
    static let maxDecreasePerTickMs = 5
    /// How many of the most recent per-second samples the recommendation looks at.
    static let lookbackSeconds = 15
    /// How much history is retained (upstream keeps a minute and looks back over 15 s of it).
    static let historySeconds = 60
    /// Default seconds between ticks. Upstream's default and the value in use on Windows.
    static let defaultIntervalSec = 5

    /// One per-second observation. `arrivalGapMs` is the worst packet inter-arrival gap seen
    /// in that second; `renderGapMs` the worst render-callback period.
    struct Sample: Equatable {
        var arrivalGapMs: Int
        var renderGapMs: Int
    }

    enum Decision: Equatable {
        /// Nothing to do, with the reason — surfaced in diagnostics, and what the tests assert.
        case hold(reason: HoldReason)
        /// Move the target to this many ms.
        case retarget(ms: Int)
    }

    enum HoldReason: Equatable {
        case notEnoughHistory
        case underrunsSinceLastTick(Int64)
        case deferringToRecentChange
        case withinHysteresis(recommended: Int)
    }

    /// Everything the decision depends on, gathered by the caller.
    struct Input {
        var samples: [Sample]
        /// Frame duration of the active stream, rounded up. The codec floor is derived from it.
        var frameMs: Int
        var currentTargetMs: Int
        var minTargetMs: Int
        var maxTargetMs: Int
        /// New tune-blocking underruns since the previous tick. Device-gulp short reads must
        /// NOT be counted here — upstream found that gating on the undifferentiated total
        /// pinned the target high forever, because inaudible gulps made every tick skip.
        var tuneBlockingUnderrunDelta: Int64
        /// True while a user change or a fresh session is still inside its deferral window.
        var deferring: Bool
    }

    static func decide(_ input: Input) -> Decision {
        guard input.samples.count >= 2 else { return .hold(reason: .notEnoughHistory) }
        if input.deferring { return .hold(reason: .deferringToRecentChange) }
        if input.tuneBlockingUnderrunDelta > 0 {
            return .hold(reason: .underrunsSinceLastTick(input.tuneBlockingUnderrunDelta))
        }

        let window = input.samples.suffix(lookbackSeconds)
        // Second-highest, not the peak. A single transient — one bad second from an OS or
        // driver hiccup that never recurs — used to drive the whole recommendation upstream
        // (a lone 1046 ms gap drove the buffer to the 200 ms cap and shed a burst of trims).
        // Requiring the jitter to show up in two separate seconds filters that out while still
        // honouring sustained jitter at full speed.
        let observedGap = secondHighest(window.map(\.arrivalGapMs), floor: 0)
        let observedRender = secondHighest(window.map(\.renderGapMs), floor: renderPeriodFloorMs)

        // The codec floor: a target below one packet cannot work, since the buffer is fed a
        // whole frame at a time. 1.5x leaves room for the arrival sawtooth.
        let codecFloor = Int((1.5 * Double(input.frameMs)).rounded(.up))
        let jitterBased = observedGap + observedRender + safetyMarginMs
        let recommended = max(codecFloor, jitterBased)
        let capped = min(recommended, recommendationCapMs)

        let current = input.currentTargetMs
        // Raise in one step — the buffer is already failing, waiting costs audio. Lower slowly.
        let target = capped > current ? capped : max(capped, current - maxDecreasePerTickMs)
        let clamped = min(max(target, input.minTargetMs), input.maxTargetMs)
        if abs(clamped - current) < hysteresisMs {
            return .hold(reason: .withinHysteresis(recommended: capped))
        }
        return .retarget(ms: clamped)
    }

    /// Second-largest value, falling back to the largest when there is only one, and never
    /// below `floor`. Matches upstream's inline peak/second tracking.
    private static func secondHighest(_ values: [Int], floor: Int) -> Int {
        var peak = floor
        var second = floor
        for value in values {
            if value > peak {
                second = peak
                peak = value
            } else if value > second {
                second = value
            }
        }
        return values.count >= 2 ? second : peak
    }
}
