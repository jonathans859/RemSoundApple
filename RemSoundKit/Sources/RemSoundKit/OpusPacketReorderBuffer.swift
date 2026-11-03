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

    let waitNs: UInt64
    let capacity: Int
    private(set) var nextSequence: UInt32?
    private var pending: [UInt32: Packet] = [:]
    var pendingCount: Int { pending.count }

    init(waitMilliseconds: Int = 60, capacity: Int = 512) {
        precondition(waitMilliseconds >= 0 && capacity > 0)
        waitNs = UInt64(waitMilliseconds) * 1_000_000
        self.capacity = capacity
    }

    mutating func insert(sequence: UInt32, bytes: [UInt8], nowNs: UInt64) -> [Event] {
        if nextSequence == nil { nextSequence = sequence }
        let distance = sequence &- nextSequence!
        // Already played/concealed packets must NEVER rewind the decoder.
        if distance >= 0x8000_0000 || pending[sequence] != nil { return [.ignored] }
        var events: [Event] = []
        if distance > UInt32(capacity) {
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
