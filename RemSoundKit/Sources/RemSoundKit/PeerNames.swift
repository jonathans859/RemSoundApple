import Foundation

/// The user's book of friendly peer names — "Andre's desktop" instead of "ANDRE-DESKTOP".
///
/// Mirrors the Windows app's named-peers book (`NamedPeer` / `MainForm.ApplyFriendlyName`):
/// device-local, shared by every profile, and keyed by the peer's *identity* rather than by
/// its address, so a name outlives a DHCP lease, a restart of the peer, or its arriving over
/// Tailscale today and the LAN tomorrow. Deliberately NOT part of a profile — upstream keeps
/// the book machine-wide, and a name is about the device you read it on.
///
/// Pure value type so the naming rules are testable without a controller or UserDefaults;
/// `ReceiverSettings.peerNames` persists `storage`.
public struct PeerNameBook: Equatable, Sendable {
    /// Keys are normalised (lower-cased) — the Windows book is a case-insensitive dictionary,
    /// and a machine that announces "ANDRE-PC" once and "andre-pc" later must keep its name.
    private var names: [String: String]

    public init(_ names: [String: String] = [:]) {
        self.names = names.reduce(into: [String: String]()) { $0[Self.normalise($1.key)] = $1.value }
    }

    /// The persisted form — normalised keys to friendly names.
    public var storage: [String: String] { names }

    /// The name the peer announces for itself, or nil when it never announced one: a peer
    /// added by address announces nothing until discovery matches it, and a discovery row
    /// whose name is just its address is the same case.
    public static func machineName(announced: String, addressString: String) -> String? {
        let trimmed = announced.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != addressString else { return nil }
        return trimmed
    }

    /// The key a name is stored under — the machine name when there is one, else the address
    /// or typed host (upstream's `PeerIdentityKey`). Keying on the machine name is exactly
    /// what makes the name survive the peer moving to another address.
    public static func identityKey(machineName: String?, fallback: String) -> String {
        machineName ?? fallback
    }

    public func name(for key: String) -> String? {
        let value = names[Self.normalise(key)]
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Store a name, or clear it with nil/blank (upstream's Clear button and its empty-box
    /// equivalent). Returns whether anything actually changed, so callers can skip the
    /// persist-and-refresh round trip.
    @discardableResult
    public mutating func set(_ name: String?, for key: String) -> Bool {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespaces)
        let normalised = Self.normalise(key)
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        guard names[normalised] != newValue else { return false }
        if let newValue {
            names[normalised] = newValue
        } else {
            names.removeValue(forKey: normalised)
        }
        return true
    }

    private static func normalise(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
