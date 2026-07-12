import Foundation

/// A named snapshot of the connection-relevant configuration — a lightweight take on the
/// Windows client's profiles. Deliberately covers only what changes between setups: the
/// remembered peers, which of them are enabled, the receive/send toggles, the microphone,
/// and the maximum delay. The profile's password belongs to the snapshot too, but lives in
/// the Keychain (one item per profile id, see `ProfileStore`) — never in this Codable
/// struct, which is persisted as plain JSON.
public struct ReceiverProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var manualPeers: [ManualPeer]
    public var selectedPeerAddresses: [String]
    public var receiveEnabled: Bool
    public var sendEnabled: Bool
    /// Stable input id; nil = system default (matches `ReceiverSettings.selectedMicrophoneId`).
    public var selectedMicrophoneId: String?
    public var targetLatencyMs: Int

    public init(id: UUID = UUID(), name: String, manualPeers: [ManualPeer],
                selectedPeerAddresses: [String], receiveEnabled: Bool, sendEnabled: Bool,
                selectedMicrophoneId: String?, targetLatencyMs: Int) {
        self.id = id
        self.name = name
        self.manualPeers = manualPeers
        self.selectedPeerAddresses = selectedPeerAddresses
        self.receiveEnabled = receiveEnabled
        self.sendEnabled = sendEnabled
        self.selectedMicrophoneId = selectedMicrophoneId
        self.targetLatencyMs = targetLatencyMs
    }
}

/// Persists the profile list as JSON in UserDefaults and each profile's password as its
/// own Keychain item, so passwords never sit in plain preferences.
public final class ProfileStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var profiles: [ReceiverProfile] {
        get {
            guard let data = defaults.data(forKey: "profiles"),
                  let profiles = try? JSONDecoder().decode([ReceiverProfile].self, from: data)
            else { return [] }
            return profiles
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "profiles")
        }
    }

    public func password(forProfile id: UUID) -> String {
        Keychain.read(account: Self.passwordAccount(id))
    }

    /// An empty password removes the Keychain item (also the cleanup path on delete).
    public func setPassword(_ password: String, forProfile id: UUID) {
        Keychain.write(password, account: Self.passwordAccount(id))
    }

    private static func passwordAccount(_ id: UUID) -> String {
        "profile-password-\(id.uuidString)"
    }
}
