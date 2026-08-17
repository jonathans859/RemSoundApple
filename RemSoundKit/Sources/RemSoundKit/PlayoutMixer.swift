import Foundation
import os

/// Multi-source mix bus, mirroring the Windows `PlayoutEngine`: one `SessionPlayout` per
/// active stream, all summed at render time, then volume / mute / soft limiter. The render
/// callback (`render`) runs on the audio thread; session add/remove takes a short lock and
/// swaps an immutable snapshot array the render thread iterates.
public final class PlayoutMixer {
    // Soft-limiter: below the threshold samples pass untouched; above it a tanh knee
    // compresses the excess so summation peaks asymptote to ±1 instead of hard-clipping.
    private static let limiterThreshold: Float = 0.9
    private static let limiterKnee: Float = 1.0 - limiterThreshold

    private let lock = NSLock()
    private var sessions: [SessionKey: SessionPlayout] = [:]
    private var snapshot: [SessionPlayout] = []

    /// 0…1 linear volume, applied post-mix. Atomic enough for a float on the render thread.
    public var volume: Float = 1.0
    public var isMuted = false

    /// Target latency in ms applied to every (current and future) session buffer.
    public private(set) var targetLatencyMs = 80

    private struct SessionKey: Hashable {
        let endpoint: UDPEndpoint
        let streamId: UInt16
    }

    public init() {}

    public func setTargetLatencyMs(_ ms: Int, drainOnLower: Bool = true) {
        lock.lock()
        targetLatencyMs = ReceiverSettings.clampLatency(ms)
        let all = snapshot
        lock.unlock()
        for session in all {
            session.setTargetLatencyMs(targetLatencyMs, drainOnLower: drainOnLower)
        }
    }

    func getOrCreateSession(endpoint: UDPEndpoint, streamId: UInt16) -> SessionPlayout {
        lock.lock()
        defer { lock.unlock() }
        let key = SessionKey(endpoint: endpoint, streamId: streamId)
        if let existing = sessions[key] { return existing }
        let playout = SessionPlayout(endpoint: endpoint, streamId: streamId, targetLatencyMs: targetLatencyMs)
        sessions[key] = playout
        snapshot = Array(sessions.values)
        return playout
    }

    func removeSession(endpoint: UDPEndpoint, streamId: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        if let removed = sessions.removeValue(forKey: SessionKey(endpoint: endpoint, streamId: streamId)) {
            retireCounters(of: removed)
        }
        snapshot = Array(sessions.values)
    }

    func removeAllSessions() {
        lock.lock()
        defer { lock.unlock() }
        for session in sessions.values { retireCounters(of: session) }
        sessions.removeAll()
        snapshot = []
    }

    // Glitch counters of removed sessions are folded into these so the cumulative totals
    // the status UI diffs against never run backwards when a stream ends or is superseded.
    private var retiredUnderruns: Int64 = 0
    private var retiredTrimFires: Int64 = 0
    private var retiredTuneBlocking: Int64 = 0
    private var retiredDeviceGulp: Int64 = 0

    private func retireCounters(of session: SessionPlayout) {
        let counters = session.glitchCounters
        retiredUnderruns += counters.underruns
        retiredTrimFires += counters.trims
        retiredTuneBlocking += counters.tuneBlocking
        retiredDeviceGulp += counters.deviceGulp
    }

    /// Cumulative underrun / click-trim counts across all sessions, past and present.
    /// `tuneBlocking` and `deviceGulp` partition the short reads by cause — the auto-tune
    /// gates on the first and must ignore the second (see `SessionPlayout`).
    public var glitchTotals: (underruns: Int64, trims: Int64, tuneBlocking: Int64, deviceGulp: Int64) {
        lock.lock()
        let all = snapshot
        var underruns = retiredUnderruns
        var trims = retiredTrimFires
        var tuneBlocking = retiredTuneBlocking
        var deviceGulp = retiredDeviceGulp
        lock.unlock()
        for session in all {
            let counters = session.glitchCounters
            underruns += counters.underruns
            trims += counters.trims
            tuneBlocking += counters.tuneBlocking
            deviceGulp += counters.deviceGulp
        }
        return (underruns, trims, tuneBlocking, deviceGulp)
    }

    // Render-callback period, measured rather than assumed. The auto-tune adds the observed
    // callback gap to the network gap, so a chunky or late-scheduled output device cannot be
    // mistaken for network jitter. Peak since the last drain, in ms.
    private var peakRenderGapMs = 0
    private var lastRenderNs: UInt64 = 0

    /// Read and reset the peak render-callback interval. Main-actor side, once per tick.
    public func drainPeakRenderGapMs() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let peak = peakRenderGapMs
        peakRenderGapMs = 0
        return peak
    }

    /// Called at the top of `render` on the audio thread. Uses the same lock the snapshot
    /// read below takes, so this adds no extra synchronisation to the callback.
    private func noteRenderCallback() {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if lastRenderNs != 0 {
            let gapMs = Int((nowNs &- lastRenderNs) / 1_000_000)
            if gapMs > peakRenderGapMs { peakRenderGapMs = gapMs }
        }
        lastRenderNs = nowNs
        lock.unlock()
    }

    public var activeSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    /// Worst-case buffered duration across sessions, for the status UI.
    public var currentBufferMs: Int {
        lock.lock()
        let all = snapshot
        lock.unlock()
        return all.map(\.bufferedMs).max() ?? 0
    }

    /// Render `frames` stereo frames of mixed audio into `output` (interleaved float32).
    /// Called from the audio render thread.
    public func render(into output: UnsafeMutablePointer<Float>, frames: Int) {
        noteRenderCallback()
        let sampleCount = frames * SessionPlayout.mixChannels
        for i in 0..<sampleCount { output[i] = 0 }

        lock.lock()
        let all = snapshot
        lock.unlock()
        // No active sessions: the bus is already silence from the zero-fill above, so skip
        // both the mix and the per-sample gain/limiter loop. This runs on the render thread
        // ~200×/s (and around the clock — the engine never stops), so avoiding a full pass
        // over known-zero output every callback is worth the early return.
        if all.isEmpty { return }
        for session in all {
            session.readAdd(into: output, frames: frames)
        }

        if isMuted {
            for i in 0..<sampleCount { output[i] = 0 }
            return
        }

        let gain = volume
        for i in 0..<sampleCount {
            var sample = output[i] * gain
            let magnitude = abs(sample)
            if magnitude > Self.limiterThreshold {
                let excess = (magnitude - Self.limiterThreshold) / Self.limiterKnee
                let limited = Self.limiterThreshold + Self.limiterKnee * tanhf(excess)
                sample = sample < 0 ? -limited : limited
            }
            output[i] = sample
        }
    }
}
