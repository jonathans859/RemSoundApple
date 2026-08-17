import Foundation
import os

/// Which internal mode the sender's Opus encoder is running in, decoded from a packet's
/// TOC byte. This matters for loss resilience: **inband FEC (LBRR) is a SILK feature**, so a
/// CELT-only stream carries no redundancy no matter what `OPUS_SET_INBAND_FEC` was set to on
/// the encoder — and `RESTRICTED_LOWDELAY` (what both this port and the Windows sender ask
/// for) forces CELT-only, as does any high bitrate. Reported so that question is answered by
/// observation instead of by reading encoder flags that may be inert.
public enum OpusPacketMode: Sendable {
    case unknown
    case silk
    case hybrid
    case celt

    /// RFC 6716 §3.1: the TOC byte's top 5 bits are the configuration number.
    /// 0–11 SILK-only, 12–15 hybrid, 16–31 CELT-only.
    static func fromTOC(_ toc: UInt8) -> OpusPacketMode {
        switch Int(toc >> 3) {
        case ..<12: return .silk
        case ..<16: return .hybrid
        default: return .celt
        }
    }

    /// Plain sentence for the status panel — VoiceOver reads this verbatim.
    public var displayDescription: String {
        switch self {
        case .unknown: return "unknown"
        case .silk: return "SILK, so inband error correction is possible"
        case .hybrid: return "hybrid, so inband error correction is possible"
        case .celt: return "CELT only, so inband error correction is unavailable"
        }
    }
}

/// Cumulative packet-level counters, snapshotted for the UI.
public struct StreamDiagnosticsSnapshot: Sendable {
    public var audioPacketsReceived: Int64 = 0
    /// Sum of forward sequence gaps — packets the sender emitted that never arrived
    /// (or arrived so late they were counted lost first, and then again as `late`).
    public var packetsLost: Int64 = 0
    /// Arrived with a sequence older than one already seen: network reordering.
    public var packetsLate: Int64 = 0
    /// Same sequence seen twice.
    public var packetsDuplicate: Int64 = 0
    /// Forward jump too large to be plausible loss — sender restart, not a gap.
    public var resyncs: Int64 = 0
    /// Payload that failed AES-GCM open: wrong password, or a corrupted/truncated datagram.
    public var decryptFailures: Int64 = 0
    /// Inter-arrival gaps binned by size. These size the jitter buffer directly: a buffer
    /// smaller than the observed gap cannot survive it.
    public var gapsOver30ms: Int64 = 0
    public var gapsOver60ms: Int64 = 0
    public var gapsOver100ms: Int64 = 0
    public var opusMode: OpusPacketMode = .unknown
    /// Whether the gap figures came from the kernel's delivery timestamp rather than from
    /// the receive thread. Surfaced because the two measure different things, and a silent
    /// fallback would make a capture look like network jitter when it is app throttling.
    public var usingKernelTimestamps = false

    public init() {}
}

/// Engine-wide packet-level telemetry, written from the network receive thread by every
/// `StreamSession` and read from the main actor by the status panel.
///
/// Deliberately aggregate rather than per-session: sessions are created, superseded and
/// pruned constantly (streamId rotation, idle timeout), so per-session counters would need
/// the same retire-into-a-total bookkeeping `PlayoutMixer` does for its glitch counts. One
/// long-lived object that outlives every session avoids that entirely.
///
/// This is measurement only — nothing here feeds back into decode or playout behaviour.
public final class StreamDiagnostics {
    private let lock = OSAllocatedUnfairLock()
    private var stats = StreamDiagnosticsSnapshot()
    /// Largest inter-arrival gap since the last `drainPeakGapMs()`. Peak, not a running
    /// total, so the reader takes it and resets rather than diffing.
    private var peakGapMs = 0

    public init() {}

    public func snapshot() -> StreamDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Read and reset the peak inter-arrival gap. The status panel calls this once per
    /// refresh tick and keeps its own sliding window of the results.
    public func drainPeakGapMs() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let peak = peakGapMs
        peakGapMs = 0
        return peak
    }

    public func reset() {
        lock.lock()
        stats = StreamDiagnosticsSnapshot()
        peakGapMs = 0
        lock.unlock()
    }

    // MARK: - Network thread

    func recordArrival(gapMs: Int?, kernelTimed: Bool = false) {
        lock.lock()
        stats.audioPacketsReceived &+= 1
        stats.usingKernelTimestamps = kernelTimed
        if let gapMs {
            if gapMs > peakGapMs { peakGapMs = gapMs }
            if gapMs > 100 {
                stats.gapsOver100ms &+= 1
                stats.gapsOver60ms &+= 1
                stats.gapsOver30ms &+= 1
            } else if gapMs > 60 {
                stats.gapsOver60ms &+= 1
                stats.gapsOver30ms &+= 1
            } else if gapMs > 30 {
                stats.gapsOver30ms &+= 1
            }
        }
        lock.unlock()
    }

    func recordLost(_ count: Int) {
        lock.lock()
        stats.packetsLost &+= Int64(count)
        lock.unlock()
    }

    func recordLate() {
        lock.lock()
        stats.packetsLate &+= 1
        lock.unlock()
    }

    func recordDuplicate() {
        lock.lock()
        stats.packetsDuplicate &+= 1
        lock.unlock()
    }

    func recordResync() {
        lock.lock()
        stats.resyncs &+= 1
        lock.unlock()
    }

    func recordDecryptFailure() {
        lock.lock()
        stats.decryptFailures &+= 1
        lock.unlock()
    }

    func recordOpusTOC(_ toc: UInt8) {
        let mode = OpusPacketMode.fromTOC(toc)
        lock.lock()
        stats.opusMode = mode
        lock.unlock()
    }
}

/// Per-session arrival bookkeeping: classifies each packet's sequence against the previous
/// one and measures the wall gap between arrivals. Network-thread only (the receive socket
/// runs one blocking-recv thread), so no locking here — only the shared `StreamDiagnostics`
/// sink is synchronised.
struct ArrivalTracker {
    /// Forward jumps beyond this are treated as a sender restart, not as lost packets —
    /// without it, a streamId reuse or counter reset would report millions of "lost".
    private static let maxPlausibleGap: UInt32 = 500

    private var lastSequence: UInt32?
    private var lastLocalNs: UInt64 = 0
    private var lastKernelNs: UInt64 = 0

    /// Measure the inter-arrival gap, preferring the kernel's timestamp.
    ///
    /// The local clock times when *this thread got round to* the packet. Under iOS
    /// background throttling the receive thread is descheduled while datagrams queue in the
    /// socket buffer, so a burst of on-time packets reads as one huge gap — which is exactly
    /// what drove the latency auto-tune to its ceiling for no benefit. The kernel stamp is
    /// taken on delivery and is immune to that.
    ///
    /// The two clocks are never mixed: kernel stamps are wall-clock, the local one is
    /// monotonic, so subtracting across them would be meaningless. A packet without a kernel
    /// stamp yields no gap rather than a bogus one, and resets the kernel baseline.
    mutating func record(sequence: UInt32, kernelArrivalNs: UInt64, into diagnostics: StreamDiagnostics) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let gapMs: Int?
        if kernelArrivalNs != 0 {
            gapMs = lastKernelNs == 0 ? nil : Int((kernelArrivalNs &- lastKernelNs) / 1_000_000)
            lastKernelNs = kernelArrivalNs
        } else {
            gapMs = lastLocalNs == 0 ? nil : Int((nowNs &- lastLocalNs) / 1_000_000)
            lastKernelNs = 0
        }
        lastLocalNs = nowNs
        diagnostics.recordArrival(gapMs: gapMs, kernelTimed: kernelArrivalNs != 0)

        guard let last = lastSequence else {
            lastSequence = sequence
            return
        }

        // Unsigned wrap is intentional — sequence is a uint32 counter that rolls over.
        let delta = sequence &- last
        switch delta {
        case 0:
            diagnostics.recordDuplicate()
        case 1:
            lastSequence = sequence // in order
        case 2...Self.maxPlausibleGap:
            diagnostics.recordLost(Int(delta) - 1)
            lastSequence = sequence
        default:
            if delta > UInt32.max / 2 {
                // Sequence went backwards: a reordered packet overtaken by a newer one.
                // Keep `lastSequence` at the newer value so the next in-order packet is
                // not then counted as a huge gap.
                diagnostics.recordLate()
            } else {
                diagnostics.recordResync()
                lastSequence = sequence
            }
        }
    }
}
