import Foundation
import os

/// One incoming stream's playout state: a ring buffer of 48 kHz interleaved stereo floats
/// plus arming / concealment / trim state. Producer is the network thread (`write`), consumer
/// is the audio render thread (`read`).
///
/// This is a deliberately simplified port of the Windows `SessionPlayout`:
///   * Same arming model — playback starts only once the buffer holds the target latency,
///     and re-arms after a sustained underrun, so startup and recovery are click-free.
///   * Same underrun concealment principle — the edges of a gap are faded over ~0.7 ms
///     instead of slamming to zero (the click lives in the edge, not the silence).
///   * Same click-trim — if the buffer creeps past target + margin (burst arrival, clock
///     drift), oldest audio is dropped back to just above target with a fade at the seam.
///   * NOT ported: the fixed-ratio drift resampler. At the latencies this receiver targets,
///     the trim + re-arm path bounds drift instead; a measured-rate resampler can follow in
///     a later version if sustained-drift trims prove audible in practice.
final class SessionPlayout {
    static let mixSampleRate = 48000
    static let mixChannels = 2

    let endpoint: UDPEndpoint
    let streamId: UInt16

    private let lock = OSAllocatedUnfairLock()
    private var ring: [Float]
    private var head = 0 // read position (frames)
    private var tail = 0 // write position (frames)
    private var count = 0 // buffered frames
    private let capacityFrames: Int

    private var armed = false
    private var targetFrames: Int
    private var consecutiveEmptyReads = 0
    private var fadeInPending = true
    private var lastSampleL: Float = 0
    private var lastSampleR: Float = 0

    /// Largest single write in frames — the codec's packet size as observed at the buffer.
    /// Floors the trim margin so the natural packet-arrival sawtooth never false-trims.
    private var largestWriteFrames = 0

    private(set) var underruns: Int64 = 0
    private(set) var trimFireCount: Int64 = 0
    private(set) var droppedFrames: Int64 = 0

    /// Wall-clock time of the last write — drives idle-session pruning.
    private(set) var lastWriteTime = Date()

    private static let concealFadeFrames = 32 // ~0.67 ms at 48 kHz
    private static let maxConsecutiveEmpties = 8

    init(endpoint: UDPEndpoint, streamId: UInt16, targetLatencyMs: Int, capacitySeconds: Double = 2.0) {
        self.endpoint = endpoint
        self.streamId = streamId
        self.capacityFrames = Int(capacitySeconds * Double(Self.mixSampleRate))
        self.ring = [Float](repeating: 0, count: capacityFrames * Self.mixChannels)
        self.targetFrames = max(1, targetLatencyMs * Self.mixSampleRate / 1000)
    }

    var bufferedMs: Int {
        lock.lock()
        defer { lock.unlock() }
        return count * 1000 / Self.mixSampleRate
    }

    /// Snapshot of the glitch counters under the buffer lock (1 Hz status UI).
    var glitchCounters: (underruns: Int64, trims: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (underruns, trimFireCount)
    }

    func setTargetLatencyMs(_ ms: Int, drainOnLower: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        let newTarget = max(1, ms * Self.mixSampleRate / 1000)
        if drainOnLower && newTarget < targetFrames && count > newTarget {
            dropOldestLocked(frames: count - newTarget)
            fadeInPending = true
        }
        targetFrames = newTarget
    }

    /// Producer side: append interleaved stereo floats (network thread).
    func write(_ samples: [Float], frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        lastWriteTime = Date()
        largestWriteFrames = max(largestWriteFrames, frames)

        var toWrite = frames
        if count + toWrite > capacityFrames {
            // Overflow — drop oldest so fresh audio wins (matches the ring's DropOldest).
            let overflow = count + toWrite - capacityFrames
            dropOldestLocked(frames: overflow)
            fadeInPending = true
        }
        if toWrite > capacityFrames { toWrite = capacityFrames }

        var src = 0
        var remaining = toWrite
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - tail)
            let dst = tail * Self.mixChannels
            for i in 0..<(chunk * Self.mixChannels) {
                ring[dst + i] = samples[src + i]
            }
            src += chunk * Self.mixChannels
            tail = (tail + chunk) % capacityFrames
            remaining -= chunk
        }
        count += toWrite

        // Click-trim: buffer crept past target + margin (burst arrival or sender clock
        // running fast). Margin and drop-to point mirror the Windows defaults (smoothness
        // knob = 3): the margin clears the packet-arrival sawtooth with a wide jitter pad,
        // and the trim keeps a cushion ABOVE target rather than cutting to bare target.
        // VPN/WAN delivery (Tailscale) is stall-then-burst — trimming the late backlog all
        // the way to target discards exactly the audio that would have covered the next
        // stall; the Windows source records that failure as "20 underruns/sec for the rest
        // of the session". The seam still gets a fade-in on the next read.
        let msFrames = Self.mixSampleRate / 1000
        let margin = max(largestWriteFrames * 4 + 4 * msFrames, 15 * msFrames) + 8 * msFrames
        if armed && count > targetFrames + margin {
            let keepFrames = targetFrames + largestWriteFrames * 2 + 5 * msFrames
            if count > keepFrames {
                dropOldestLocked(frames: count - keepFrames)
                trimFireCount += 1
                fadeInPending = true
            }
        }
    }

    private func dropOldestLocked(frames: Int) {
        let n = min(frames, count)
        head = (head + n) % capacityFrames
        count -= n
        droppedFrames += Int64(n)
    }

    // Per-session render scratch. Fades must shape only THIS session's contribution, so the
    // pop + fade happens here before summing into the shared mix buffer. Render-thread only.
    private var renderScratch = [Float](repeating: 0, count: 4096 * mixChannels)

    /// Consumer side: mix-add up to `frames` stereo frames into `output` (render thread).
    /// Output must hold `frames * 2` floats; existing content is summed into, not replaced.
    func readAdd(into output: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock()
        defer { lock.unlock() }

        if renderScratch.count < frames * Self.mixChannels {
            renderScratch = [Float](repeating: 0, count: frames * Self.mixChannels)
        }
        for i in 0..<(frames * Self.mixChannels) { renderScratch[i] = 0 }

        if !armed {
            if count >= targetFrames {
                armed = true
                consecutiveEmptyReads = 0
                fadeInPending = true
            } else {
                return // silence until armed
            }
        }

        let available = min(count, frames)
        if available == 0 {
            // Full underrun. Fade the tail edge of the previous audio into the silence so
            // the gap edge is smooth, then count and (eventually) disarm.
            underruns += 1
            consecutiveEmptyReads += 1
            if consecutiveEmptyReads <= Self.maxConsecutiveEmpties {
                renderScratch.withUnsafeMutableBufferPointer { scratch in
                    applyFadeOutEdge(into: scratch.baseAddress!, frames: frames)
                }
                addScratch(into: output, frames: frames)
            }
            if consecutiveEmptyReads >= Self.maxConsecutiveEmpties {
                armed = false // re-arm at target; concealment must not run forever
            }
            return
        }

        if consecutiveEmptyReads > 0 {
            fadeInPending = true
            consecutiveEmptyReads = 0
        }

        var produced = 0
        var remaining = available
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - head)
            let src = head * Self.mixChannels
            let dst = produced * Self.mixChannels
            for i in 0..<(chunk * Self.mixChannels) {
                renderScratch[dst + i] = ring[src + i]
            }
            head = (head + chunk) % capacityFrames
            produced += chunk
            remaining -= chunk
        }
        count -= available

        renderScratch.withUnsafeMutableBufferPointer { scratch in
            let base = scratch.baseAddress!
            if fadeInPending {
                applyFadeIn(output: base, frames: min(Self.concealFadeFrames, available))
                fadeInPending = false
            }

            let lastFrame = (available - 1) * Self.mixChannels
            lastSampleL = base[lastFrame]
            lastSampleR = base[lastFrame + 1]

            if available < frames {
                // Partial read — smooth the boundary into the trailing silence, and fade
                // the resume edge back in. Without the fade-in the next callback restarts
                // at full amplitude against the faded-to-zero gap — an audible tick on
                // every jitter hiccup (the full-empty path already gets this via
                // consecutiveEmptyReads; the partial path did not).
                underruns += 1
                applyFadeOutEdge(into: base + available * Self.mixChannels, frames: frames - available)
                fadeInPending = true
            }
        }
        addScratch(into: output, frames: frames)
    }

    private func addScratch(into output: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<(frames * Self.mixChannels) {
            output[i] += renderScratch[i]
        }
    }

    /// Short cosine ramp from the last real samples down to zero at the start of a gap.
    private func applyFadeOutEdge(into output: UnsafeMutablePointer<Float>, frames: Int) {
        let fade = min(Self.concealFadeFrames, frames)
        if fade <= 0 || (lastSampleL == 0 && lastSampleR == 0) { return }
        for i in 0..<fade {
            let g = 0.5 * (1 + cos(Float.pi * Float(i + 1) / Float(fade)))
            output[i * Self.mixChannels] += lastSampleL * g
            output[i * Self.mixChannels + 1] += lastSampleR * g
        }
        lastSampleL = 0
        lastSampleR = 0
    }

    /// Matching ramp up when audio resumes after an arm / gap / trim seam.
    private func applyFadeIn(output: UnsafeMutablePointer<Float>, frames: Int) {
        if frames <= 0 { return }
        for i in 0..<frames {
            let g = 0.5 * (1 - cos(Float.pi * Float(i + 1) / Float(frames)))
            output[i * Self.mixChannels] *= g
            output[i * Self.mixChannels + 1] *= g
        }
    }
}
