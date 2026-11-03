import Foundation

/// Bounded compressed-packet queue, BEFORE the stateful Opus decoder. Arrival
/// order is not decode order. All calls are serialized by StreamSession.
struct OpusPacketReorderBuffer {
    enum Event: Equatable {
        case packet(sequence: UInt32, bytes: [UInt8], reordered: Bool)
        case missing(count: Int, nextPacket: [UInt8])
        case ignored
        case resynchronized
    }

    private struct Packet {
        let bytes: [UInt8]
        let arrivedNs: UInt64
        let wasAhead: Bool
    }

    /// How long a gap is held for a late packet. StreamSession re-derives it from the
    /// playout target before every call (see `holdMilliseconds`), so a gap can never
    /// outwait the audio already buffered ahead of it.
    var waitNs: UInt64
    let capacity: Int
    private(set) var nextSequence: UInt32?
    private var pending: [UInt32: Packet] = [:]
    var pendingCount: Int { pending.count }

    /// Hold for a missing packet: half the playout target, 5...60 ms. The other half stays
    /// buffered as cushion, so a packet that is really lost costs concealment, not an
    /// underrun on top of it (a fixed 60 ms hold drained the default 80 ms buffer).
    static func holdMilliseconds(targetLatencyMs: Int) -> Int {
        min(60, max(5, targetLatencyMs / 2))
    }

    init(waitMilliseconds: Int = 60, capacity: Int = 512) {
        precondition(waitMilliseconds >= 0 && capacity > 0)
        waitNs = UInt64(waitMilliseconds) * 1_000_000
        self.capacity = capacity
    }

    mutating func insert(sequence: UInt32, bytes: [UInt8], nowNs: UInt64) -> [Event] {
        if nextSequence == nil { nextSequence = sequence }
        let distance = sequence &- nextSequence!
        var events: [Event] = []
        if distance >= 0x8000_0000 {
            // Behind the play position. A few hundred slots is a late or duplicate packet:
            // already played/concealed packets must NEVER rewind the decoder. Further back
            // than the queue could ever hold is a sender whose counter restarted under the
            // same streamId; ignoring it would mute that sender until the new counter
            // caught up with the old one.
            guard nextSequence! &- sequence > UInt32(capacity) else { return [.ignored] }
            pending.removeAll(keepingCapacity: true)
            nextSequence = sequence
            events.append(.resynchronized)
        } else if pending[sequence] != nil {
            return [.ignored]
        } else if distance > UInt32(capacity) {
            // Bounded recovery from a sender counter jump: never allocate or
            // synthesize seconds/minutes of audio for an arbitrary sequence.
            pending.removeAll(keepingCapacity: true)
            nextSequence = sequence
            events.append(.resynchronized)
        }
        pending[sequence] = Packet(bytes: bytes, arrivedNs: nowNs,
                                   wasAhead: sequence != nextSequence)
        events += drain(nowNs: nowNs)
        return events
    }

    mutating func drain(nowNs: UInt64) -> [Event] {
        var events: [Event] = []
        while let expected = nextSequence, !pending.isEmpty {
            if let packet = pending.removeValue(forKey: expected) {
                events.append(.packet(sequence: expected, bytes: packet.bytes, reordered: packet.wasAhead))
                nextSequence = expected &+ 1
                continue
            }
            let oldest = pending.values.map(\.arrivedNs).min()!
            let age = nowNs >= oldest ? nowNs - oldest : 0
            guard age >= waitNs || pending.count >= capacity else { break }
            let nearest = pending.keys.min { ($0 &- expected) < ($1 &- expected) }!
            let missing = Int(nearest &- expected)
            events.append(.missing(count: missing, nextPacket: pending[nearest]!.bytes))
            nextSequence = nearest
        }
        return events
    }
}
