import Foundation

/// The subset of `NSUbiquitousKeyValueStore` the profile sync needs. Injectable so the
/// merge logic is testable without an iCloud account — CI has none, and the real store
/// silently no-ops when the user is signed out.
public protocol ProfileSyncStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    func removeObject(forKey key: String)
    /// Every key currently in the store, including ones this device never wrote.
    var allKeys: [String] { get }
    @discardableResult func synchronize() -> Bool
}

#if canImport(Darwin)
extension NSUbiquitousKeyValueStore: ProfileSyncStore {
    public var allKeys: [String] { Array(dictionaryRepresentation.keys) }
}
#endif

/// Mirrors saved profiles through iCloud's key-value store.
///
/// **One key per profile** (`profile-<uuid>`), never one key holding the whole array.
/// The key-value store resolves conflicts last-writer-wins *per key*: with per-profile
/// keys, editing "Home" on the Mac and "Travel" on the iPhone both survive, where a
/// single array key would silently drop one of the two edits.
///
/// Passwords are deliberately absent from everything written here — iCloud KVS is not
/// end-to-end encrypted. Profile passwords ride iCloud Keychain instead (see `Keychain`),
/// which is.
enum ProfileSync {
    static let keyPrefix = "profile-"

    static func key(for id: UUID) -> String { "\(keyPrefix)\(id.uuidString)" }

    /// The result of reconciling what iCloud holds with what this device holds.
    struct MergeResult: Equatable {
        /// The profile list the device should now show.
        var profiles: [ReceiverProfile]
        /// Profiles present locally but never published — the caller pushes these.
        var toPush: [ReceiverProfile]
        /// Ids that were deleted on another device; the caller drops their Keychain items.
        var deleted: [UUID]
    }

    /// Reconcile remote and local profile sets.
    ///
    /// - Content: remote wins for any profile present in both. The store is the shared
    ///   truth, and a local edit reaches it through `push` before any pull can race it.
    /// - Additions: a profile only remote is adopted; a profile only local is kept and
    ///   pushed **unless** this device already published it, in which case its absence is
    ///   a real delete from another device (that is what `syncedIds` distinguishes).
    /// - Order: existing local order is preserved — a sync must not reshuffle the list
    ///   under a VoiceOver user mid-scroll. Newly arrived profiles are appended by name
    ///   so every device ends up agreeing on where they land.
    static func merge(local: [ReceiverProfile],
                      remote: [ReceiverProfile],
                      syncedIds: Set<UUID>) -> MergeResult {
        let remoteById = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [ReceiverProfile] = []
        var toPush: [ReceiverProfile] = []
        var deleted: [UUID] = []

        for profile in local {
            if let fromRemote = remoteById[profile.id] {
                result.append(fromRemote)
            } else if syncedIds.contains(profile.id) {
                deleted.append(profile.id)
            } else {
                result.append(profile)
                toPush.append(profile)
            }
        }

        let known = Set(local.map(\.id))
        let arrived = remote
            .filter { !known.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        result.append(contentsOf: arrived)

        return MergeResult(profiles: result, toPush: toPush, deleted: deleted)
    }

    /// Decode every profile the store holds. Unreadable entries are skipped rather than
    /// failing the whole pull — one profile written by a future version with an added
    /// field must not block the others from syncing.
    static func readRemote(from store: ProfileSyncStore) -> [ReceiverProfile] {
        store.allKeys
            .filter { $0.hasPrefix(keyPrefix) }
            .compactMap { key in
                guard let data = store.data(forKey: key) else { return nil }
                return try? JSONDecoder().decode(ReceiverProfile.self, from: data)
            }
    }

    /// Publish profiles. Deliberately additive: it never removes remote keys it does not
    /// recognise, so a device that has not pulled yet — a fresh install, or one signed
    /// into iCloud after the fact — cannot wipe the other devices' profiles by pushing
    /// its own short list. Deletions travel through `remove` only, on explicit user action.
    static func push(_ profiles: [ReceiverProfile], to store: ProfileSyncStore) {
        for profile in profiles {
            guard let data = try? JSONEncoder().encode(profile) else { continue }
            store.set(data, forKey: key(for: profile.id))
        }
        store.synchronize()
    }

    static func remove(id: UUID, from store: ProfileSyncStore) {
        store.removeObject(forKey: key(for: id))
        store.synchronize()
    }
}
