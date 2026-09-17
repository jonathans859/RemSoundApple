import Foundation

/// Keeps a selected peer's addresses eligible for a while after discovery last saw them
/// (issue #8). The allow-list is re-derived from `PeerDiscoveryService.currentPeers` on
/// every discovery change and every DNS retry, and `AudioReceiverEngine.setAllowedSenders`
/// closes every live session whose address has fallen out of it — so one rebuild landing in
/// a window where a peer that is demonstrably still streaming has momentarily aged out of
/// discovery tears its sessions down and makes the jitter buffer re-arm. Over a VPN that
/// window is not rare: broadcast does not cross the tunnel, so only the unicast
/// announcements carry, and missing six in a row past discovery's 8 s expiry is
/// unremarkable on a relayed path. Discovery liveness must not gate playback of audio that
/// is demonstrably arriving.
///
/// Deliberately NOT a second expiry policy inside discovery: the peer LIST should still go
/// quiet when a peer stops announcing (that is what it means), it is only the allow-list
/// that must not. Eligibility is intersected with the user's CURRENT selection on every
/// read, so deselecting a peer cuts it on the same tick, and the whole thing lives in
/// memory, so nothing survives a restart.
struct SelectionGrace {
    /// Comfortably longer than a burst of missed unicast announcements over a relayed path,
    /// short enough that a peer that really went away stops being allow-listed.
    static let defaultWindow: TimeInterval = 30

    struct Eligible: Equatable {
        let endpoint: UDPEndpoint
        /// Which peer the endpoint belongs to, so the engine's address grouping survives the
        /// peer dropping out of discovery too.
        let identity: String
    }

    private struct Entry {
        /// Any one of these still being selected keeps this endpoint eligible.
        let selectionKeys: Set<String>
        let identity: String
        var lastSeen: Date
    }

    private let window: TimeInterval
    private var entries: [UDPEndpoint: Entry] = [:]

    init(window: TimeInterval = SelectionGrace.defaultWindow) {
        self.window = window
    }

    /// Record that discovery (or a DNS resolution) has just shown this endpoint for a peer
    /// the user has selected.
    mutating func note(endpoint: UDPEndpoint, selectionKeys: Set<String>, identity: String,
                       now: Date = Date()) {
        entries[endpoint] = Entry(selectionKeys: selectionKeys, identity: identity, lastSeen: now)
    }

    /// Endpoints still inside the grace window whose peer is still selected. Prunes as it
    /// goes, so the table cannot grow without bound.
    mutating func eligible(selected: Set<String>, now: Date = Date()) -> [Eligible] {
        let cutoff = now.addingTimeInterval(-window)
        entries = entries.filter { $0.value.lastSeen >= cutoff }
        return entries
            .filter { !$0.value.selectionKeys.isDisjoint(with: selected) }
            .map { Eligible(endpoint: $0.key, identity: $0.value.identity) }
    }

    mutating func reset() { entries.removeAll() }
}
