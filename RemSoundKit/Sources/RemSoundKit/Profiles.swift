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
    /// Whether the delay is retuned continuously (see `LatencyAutoTune`). Part of the
    /// snapshot because it changes the meaning of `targetLatencyMs`: with it on, the stored
    /// delay is a starting point the tuner moves, not a value the profile pins.
    public var autoTuneLatencyEnabled: Bool

    public init(id: UUID = UUID(), name: String, manualPeers: [ManualPeer],
                selectedPeerAddresses: [String], receiveEnabled: Bool, sendEnabled: Bool,
                selectedMicrophoneId: String?, targetLatencyMs: Int,
                autoTuneLatencyEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.manualPeers = manualPeers
        self.selectedPeerAddresses = selectedPeerAddresses
        self.receiveEnabled = receiveEnabled
        self.sendEnabled = sendEnabled
        self.selectedMicrophoneId = selectedMicrophoneId
        self.targetLatencyMs = targetLatencyMs
        self.autoTuneLatencyEnabled = autoTuneLatencyEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, manualPeers, selectedPeerAddresses, receiveEnabled, sendEnabled
        case selectedMicrophoneId, targetLatencyMs, autoTuneLatencyEnabled
    }

    /// Hand-written so a field added later cannot destroy the user's profiles. Both decode
    /// paths — the local JSON blob in UserDefaults and each per-profile iCloud key — use
    /// `try?` and treat a throw as "no profiles", so a synthesised decoder meeting JSON
    /// written by an older build would silently wipe the list rather than fail loudly. Every
    /// field added from here on must be decoded with a default, for the same reason.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        manualPeers = try container.decodeIfPresent([ManualPeer].self, forKey: .manualPeers) ?? []
        selectedPeerAddresses = try container.decodeIfPresent([String].self, forKey: .selectedPeerAddresses) ?? []
        receiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .receiveEnabled) ?? true
        sendEnabled = try container.decodeIfPresent(Bool.self, forKey: .sendEnabled) ?? false
        selectedMicrophoneId = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneId)
        targetLatencyMs = try container.decodeIfPresent(Int.self, forKey: .targetLatencyMs)
            ?? ReceiverSettings.defaultTargetLatencyMs
        autoTuneLatencyEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoTuneLatencyEnabled) ?? false
    }
}

/// What the app applies when it launches (the Profiles tab's "At launch" picker).
public enum StartupProfileChoice: Hashable, Sendable {
    /// Nothing applied — the app starts on the settings exactly as last left (default).
    case off
    /// Re-apply whichever profile was applied most recently.
    case lastApplied
    /// Always apply one specific profile.
    case fixed(UUID)
}

/// Persists the profile list as JSON in UserDefaults and each profile's password as its
/// own Keychain item, so passwords never sit in plain preferences.
///
/// When iCloud profile sync is on the local storage stays the source of truth for reads —
/// launch-time application (`applyStartupProfile`) must be synchronous and work offline —
/// and the key-value store is a mirror written through on every change. See `ProfileSync`.
public final class ProfileStore {
    private let defaults: UserDefaults
    private let settings: ReceiverSettings
    /// nil in tests that do not exercise sync, and on a device with sync switched off.
    private let syncStore: ProfileSyncStore?

    public init(defaults: UserDefaults = .standard, syncStore: ProfileSyncStore? = nil) {
        self.defaults = defaults
        self.settings = ReceiverSettings(defaults: defaults)
        self.syncStore = syncStore
    }

    /// The mirror to write to, or nil when the user has sync switched off.
    private var activeSyncStore: ProfileSyncStore? {
        settings.iCloudProfileSyncEnabled ? syncStore : nil
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
            guard let store = activeSyncStore else { return }
            ProfileSync.push(newValue, to: store)
            settings.syncedProfileIds = settings.syncedProfileIds.union(newValue.map(\.id))
        }
    }

    public func password(forProfile id: UUID) -> String {
        Keychain.read(account: Self.passwordAccount(id))
    }

    /// While sync is on the item is written to the synchronizable keychain, so it reaches
    /// the user's other devices end-to-end encrypted instead of riding in the profile JSON.
    /// An empty password stores an empty item — saving a profile must never be able to
    /// *remove* one, or a device that has not received the password yet would delete it
    /// for every other device (see `Keychain.delete`). Removal is `removePassword`.
    public func setPassword(_ password: String, forProfile id: UUID) {
        Keychain.write(password, account: Self.passwordAccount(id),
                       synchronizable: settings.iCloudProfileSyncEnabled)
    }

    /// Drop a profile's password everywhere — the deletion travels through iCloud Keychain,
    /// so this belongs to the delete path alone.
    public func removePassword(forProfile id: UUID) {
        Keychain.delete(account: Self.passwordAccount(id))
    }

    private static func passwordAccount(_ id: UUID) -> String {
        "profile-password-\(id.uuidString)"
    }

    // MARK: - iCloud sync

    /// Pull whatever iCloud holds and reconcile it with the local list, returning the
    /// merged profiles (nil when sync is off or nothing changed, so callers can skip a
    /// pointless UI update). Deleted profiles take their Keychain items with them.
    @discardableResult
    public func mergeFromCloud() -> [ReceiverProfile]? {
        guard let store = activeSyncStore else { return nil }
        let local = profiles
        let result = ProfileSync.merge(local: local,
                                       remote: ProfileSync.readRemote(from: store),
                                       syncedIds: settings.syncedProfileIds)
        for id in result.deleted {
            removePassword(forProfile: id)
        }
        if !result.toPush.isEmpty {
            ProfileSync.push(result.toPush, to: store)
        }
        settings.syncedProfileIds = Set(result.profiles.map(\.id))
        guard result.profiles != local else { return nil }
        defaults.set(try? JSONEncoder().encode(result.profiles), forKey: "profiles")
        return result.profiles
    }

    /// Drop a profile from the mirror too — the one path that removes a remote key, so a
    /// device that has not pulled yet can never wipe the shared list by pushing.
    public func removeFromCloud(id: UUID) {
        guard let store = activeSyncStore else { return }
        ProfileSync.remove(id: id, from: store)
        settings.syncedProfileIds.remove(id)
    }

    /// Handle the sync toggle flipping. Turning it on moves every profile password into
    /// the synchronizable keychain and publishes the current list; turning it off copies
    /// the passwords back to this device and stops writing, leaving both the profile JSON
    /// and the shared Keychain items in iCloud for the user's other devices — opting out
    /// here must never reach in and delete what those devices are running on.
    public func setSyncEnabled(_ enabled: Bool) {
        guard enabled != settings.iCloudProfileSyncEnabled else { return }
        settings.iCloudProfileSyncEnabled = enabled
        for profile in profiles {
            Keychain.setSynchronizable(enabled, account: Self.passwordAccount(profile.id))
        }
        if enabled {
            guard let store = syncStore else { return }
            // Adopt what is already up there before publishing, so switching sync on
            // with an existing set on another device merges instead of racing.
            _ = mergeFromCloud()
            ProfileSync.push(profiles, to: store)
            settings.syncedProfileIds = Set(profiles.map(\.id))
        } else {
            settings.syncedProfileIds = []
        }
    }

    /// Launch-time profile application: rewrites the persisted live settings in place,
    /// BEFORE `ReceiverController` reads them, so no property observers or engines are
    /// involved (applying through the controller's didSets during startup re-enters
    /// `start()`). Every profile field has a persisted setting behind it, so the rewrite
    /// covers the whole profile — send included.
    public func applyStartupProfile(to settings: ReceiverSettings) {
        let profileId: UUID?
        switch settings.startupProfile {
        case .off: return
        case .lastApplied: profileId = settings.lastAppliedProfileId
        case .fixed(let id): profileId = id
        }
        guard let profileId,
              let profile = profiles.first(where: { $0.id == profileId }) else { return }
        settings.manualPeers = profile.manualPeers
        settings.selectedPeerAddresses = Set(profile.selectedPeerAddresses)
        settings.receiveEnabled = profile.receiveEnabled
        settings.sendEnabled = profile.sendEnabled
        settings.selectedMicrophoneId = profile.selectedMicrophoneId
        settings.targetLatencyMs = profile.targetLatencyMs
        settings.autoTuneLatencyEnabled = profile.autoTuneLatencyEnabled
        settings.password = password(forProfile: profileId)
        settings.lastAppliedProfileId = profileId
    }
}
