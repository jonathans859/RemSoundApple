import Foundation

/// Hysteretic connect/disconnect cue state, one entry per selected peer — the Windows
/// receiver's rule (`MainForm.DetectAndAnnouncePeerHealthTransitions`, upstream 2026-05-31):
/// connected the moment audio arrives OR the heartbeat is solidly healthy, lost only when
/// audio has stopped AND the heartbeat has gone unreachable, everything in between HOLDING
/// the previous state.
///
/// Pulled out of `ReceiverController` so CI can pin it without audio or network, the same
/// way `LatencyAutoTune.decide` is pure. The property that needs pinning is the KEY: peers
/// are identified by their row id — the announced instance — and never by an address (issue
/// #8). A multi-homed peer's primary address is whichever of its paths discovery saw first
/// and has not expired, so an address key moves the moment a quiet LAN leg ages out from
/// under a live VPN stream: the old key leaves the observed set ("lost") and the new one is
/// unknown ("connected") on the same tick, firing both cues while audio never stopped.
struct PeerCueTracker {
    /// One selected peer as of this tick. `isConnected` and `isLost` are the two halves of
    /// the hysteresis rule and are deliberately not each other's negation — both false means
    /// "hold whatever we decided last time".
    struct Observation {
        let id: String
        let name: String
        let isConnected: Bool
        let isLost: Bool
    }

    /// The peers that changed state on this tick, by display name — what the cue sounds and
    /// the VoiceOver announcements are built from.
    struct Transitions: Equatable {
        var connected: [String] = []
        var lost: [String] = []

        var isEmpty: Bool { connected.isEmpty && lost.isEmpty }
    }

    private struct Entry {
        var connected: Bool
        var since: Date?
        /// Last known display name. Kept here because a peer that has vanished from
        /// discovery entirely is no longer in the peer list to be looked up when its "lost"
        /// cue fires — and because a rename mid-connection must announce the new name.
        var name: String
    }

    private var entries: [String: Entry] = [:]

    /// Feed this tick's selected peers; returns the transitions to announce. Peers absent
    /// from `observations` have gone entirely (deselected, or expired out of discovery):
    /// they report lost only if they were connected when last seen, so one that never
    /// connected — a connect-FAILED — stays quiet.
    mutating func update(_ observations: [Observation], now: Date = Date()) -> Transitions {
        var transitions = Transitions()
        var seen: Set<String> = []

        for observation in observations {
            seen.insert(observation.id)
            var entry = entries[observation.id]
                ?? Entry(connected: false, since: nil, name: observation.name)
            entry.name = observation.name
            if observation.isConnected && !entry.connected {
                transitions.connected.append(entry.name)
                entry.connected = true
                entry.since = now
            } else if observation.isLost && entry.connected {
                transitions.lost.append(entry.name)
                entry.connected = false
                entry.since = nil
            }
            // Anything else holds. A first sighting that is neither clearly connected nor
            // lost (peer selected but no audio or pong yet) seeds quietly.
            entries[observation.id] = entry
        }

        for (id, entry) in entries.filter({ !seen.contains($0.key) }) {
            if entry.connected { transitions.lost.append(entry.name) }
            entries.removeValue(forKey: id)
        }
        return transitions
    }

    /// When this peer's connection came up, for the details panel's "Connected for" line.
    /// Driven by the hysteretic transitions above rather than by the raw health, so a
    /// 2-second VPN stall — or a path change — does not restart the clock.
    func connectedSince(id: String) -> Date? {
        guard let entry = entries[id], entry.connected else { return nil }
        return entry.since
    }

    mutating func reset() { entries.removeAll() }
}
