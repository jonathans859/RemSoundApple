import Foundation

/// What happens when somebody else ticks us — the Windows app's "Accept connections from other
/// peers" (upstream `PeerAcceptMode`, Preferences → General, 2026-09-20). Raw values match
/// upstream's and are what `ReceiverSettings` stores, so they must stay put.
public enum PeerAcceptMode: Int, CaseIterable, Identifiable, Sendable {
    /// Ask, naming who it is, and do nothing until the answer comes. The default, as upstream.
    case prompt = 0
    /// Tick them back the moment they tick us.
    case automatic = 1
    /// Nothing happens until the user ticks them. How RemSound always worked before this.
    case manual = 2

    public var id: Int { rawValue }

    /// Upstream's three rows, shortened (user, 2026-10-09: less verbose).
    public var displayName: String {
        switch self {
        case .prompt: return "Ask each time"
        case .automatic: return "Automatically"
        case .manual: return "Manually"
        }
    }
}

/// The bookkeeping behind `PeerAcceptMode`, kept pure so CI can pin the two rules upstream
/// paid for (`MainForm.AcceptConnections.cs`):
///
/// 1. **Asked once per run, whichever way the answer went.** The point of asking once is not
///    asking again — and a person left sending would otherwise be a question every ten seconds.
/// 2. **A deliberate untick sticks for the run.** Unticking somebody who still has us ticked
///    does not stop their audio arriving, and audio from somebody unticked is exactly what sets
///    this off — so without the refusal, automatic mode ticks them straight back and the user
///    can never let anyone go ("otherwise you can never disconnect", Ed, 2026-09-21). It holds
///    until the user ticks them again, or the next launch.
///
/// Run-scoped on purpose: nothing here is persisted.
struct PeerAcceptPolicy {
    enum Decision: Equatable {
        /// Nothing to do: manual mode, already asked, refused by the user, or a question is
        /// already on screen (in which case it comes back next time round).
        case ignore
        /// Tick them back now (automatic mode).
        case accept
        /// Put the question to the user.
        case ask
    }

    private(set) var asked: Set<String> = []
    private(set) var refusedByUser: Set<String> = []

    /// Somebody on a network, by the address their audio arrives from.
    static func networkKey(address: String) -> String { "peer:\(address)" }
    /// Somebody on a server, by their client id — which is all a member has.
    static func memberKey(hex: String) -> String { "server:\(hex)" }
    /// The phone or older app the server has paired with us, by the server's address.
    static func pairKey(server: String) -> String { "server-pair:\(server)" }

    /// `promptOpen`: a question is already on screen. One at a time — a room of people
    /// arriving at once must not stack questions on each other — so the later ones are NOT
    /// marked as asked, which is what brings them back on the next pass.
    mutating func decide(key: String, mode: PeerAcceptMode, promptOpen: Bool) -> Decision {
        guard mode != .manual,
              !refusedByUser.contains(key),
              !asked.contains(key) else { return .ignore }
        if mode == .prompt && promptOpen { return .ignore }
        asked.insert(key)
        return mode == .automatic ? .accept : .ask
    }

    /// The user unticked these. Nothing in this policy may tick them back this run.
    mutating func userUnticked(_ keys: [String]) {
        refusedByUser.formUnion(keys)
    }

    /// The user ticked these: they have changed their mind, so the refusal goes.
    mutating func userTicked(_ keys: [String]) {
        refusedByUser.subtract(keys)
    }
}
