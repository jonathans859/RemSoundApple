import Foundation
import Security

/// A manually-entered peer (Tailscale IP, LAN IP, or relay hostname). Port defaults to the
/// canonical RemSound port; users never have to type one.
public struct ManualPeer: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var host: String
    public var port: UInt16

    public init(id: UUID = UUID(), host: String, port: UInt16 = RemPacket.defaultPort) {
        self.id = id
        self.host = host
        self.port = port
    }

    public var displayName: String {
        port == RemPacket.defaultPort ? host : "\(host):\(port)"
    }
}

/// The live persistent settings — what the app runs on right now. Plain values in
/// UserDefaults; the password in the Keychain. Named snapshots of the connection-relevant
/// subset live in `ProfileStore` (Profiles.swift).
public final class ReceiverSettings {
    private let defaults: UserDefaults
    private let keychainAccount = "profile-password"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var manualPeers: [ManualPeer] {
        get {
            guard let data = defaults.data(forKey: "manualPeers"),
                  let peers = try? JSONDecoder().decode([ManualPeer].self, from: data) else { return [] }
            return peers
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "manualPeers")
        }
    }

    /// Addresses (dotted-quad strings) of peers the user has ticked. Discovered peers are
    /// re-identified across launches by address — the Windows side rerolls its discovery
    /// InstanceId every start, so the address is the only stable key.
    public var selectedPeerAddresses: Set<String> {
        get { Set(defaults.stringArray(forKey: "selectedPeerAddresses") ?? []) }
        set { defaults.set(Array(newValue), forKey: "selectedPeerAddresses") }
    }

    public var targetLatencyMs: Int {
        get {
            let value = defaults.integer(forKey: "targetLatencyMs")
            return value == 0 ? 80 : min(500, max(5, value)) // Windows default: 80 ms
        }
        set { defaults.set(min(500, max(5, newValue)), forKey: "targetLatencyMs") }
    }

    public var volume: Float {
        get { defaults.object(forKey: "volume") == nil ? 1.0 : defaults.float(forKey: "volume") }
        set { defaults.set(newValue, forKey: "volume") }
    }

    public var cuesEnabled: Bool {
        get { defaults.object(forKey: "cuesEnabled") == nil ? true : defaults.bool(forKey: "cuesEnabled") }
        set { defaults.set(newValue, forKey: "cuesEnabled") }
    }

    /// The "Receive audio" playback toggle — persisted like the Windows checkbox. Default on.
    public var receiveEnabled: Bool {
        get { defaults.object(forKey: "receiveEnabled") == nil ? true : defaults.bool(forKey: "receiveEnabled") }
        set { defaults.set(newValue, forKey: "receiveEnabled") }
    }

    /// The "Send microphone" toggle — persisted since 2026-07-12 (the earlier
    /// "never persist send" rule is retired). Default off; absent key reads false.
    public var sendEnabled: Bool {
        get { defaults.bool(forKey: "sendEnabled") }
        set { defaults.set(newValue, forKey: "sendEnabled") }
    }

    /// iOS: hold the audio session exclusively (no `.mixWithOthers`) so playback — and the
    /// UDP socket under it — survives the screen locking. Default off = mix-friendly.
    public var exclusiveAudio: Bool {
        get { defaults.bool(forKey: "exclusiveAudio") }
        set { defaults.set(newValue, forKey: "exclusiveAudio") }
    }

    /// Stable id of the input the user picked for microphone sending (see
    /// `MicrophoneCapture.availableInputs`). Nil/empty = system default input.
    public var selectedMicrophoneId: String? {
        get {
            let value = defaults.string(forKey: "selectedMicrophoneId")
            return (value?.isEmpty ?? true) ? nil : value
        }
        set { defaults.set(newValue ?? "", forKey: "selectedMicrophoneId") }
    }

    /// Mirror saved profiles through iCloud so the user's devices share one set
    /// (Profiles tab). Default off: turning it on moves profile passwords into the
    /// synchronizable keychain and publishes the profile list to the user's iCloud
    /// account, which is not something an app update should start doing by itself.
    /// Device-local state — which device syncs is a per-device choice.
    public var iCloudProfileSyncEnabled: Bool {
        get { defaults.bool(forKey: "iCloudProfileSyncEnabled") }
        set { defaults.set(newValue, forKey: "iCloudProfileSyncEnabled") }
    }

    /// Ids this device has published to iCloud at least once. Lets a pull tell a profile
    /// deleted on another device (was synced, now absent → delete locally) from one
    /// created here while offline (never synced, absent → keep and push). Without it,
    /// the first pull after creating a profile offline would silently eat it.
    var syncedProfileIds: Set<UUID> {
        get { Set((defaults.stringArray(forKey: "syncedProfileIds") ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString), forKey: "syncedProfileIds") }
    }

    /// What to apply at launch (Profiles tab). Stored as "" / "last" / a profile UUID
    /// string; anything unparseable reads as `.off`.
    public var startupProfile: StartupProfileChoice {
        get {
            switch defaults.string(forKey: "startupProfile") ?? "" {
            case "": return .off
            case "last": return .lastApplied
            case let raw: return UUID(uuidString: raw).map { .fixed($0) } ?? .off
            }
        }
        set {
            switch newValue {
            case .off: defaults.removeObject(forKey: "startupProfile")
            case .lastApplied: defaults.set("last", forKey: "startupProfile")
            case .fixed(let id): defaults.set(id.uuidString, forKey: "startupProfile")
            }
        }
    }

    /// The profile most recently applied (by hand or at launch) — feeds the
    /// `.lastApplied` startup mode. A stale id (profile since deleted) is harmless:
    /// `ProfileStore.applyStartupProfile` looks it up and no-ops on a miss.
    public var lastAppliedProfileId: UUID? {
        get { defaults.string(forKey: "lastAppliedProfileId").flatMap(UUID.init(uuidString:)) }
        set {
            if let id = newValue {
                defaults.set(id.uuidString, forKey: "lastAppliedProfileId")
            } else {
                defaults.removeObject(forKey: "lastAppliedProfileId")
            }
        }
    }

    public var listenPort: UInt16 {
        get {
            let value = defaults.integer(forKey: "listenPort")
            return value == 0 ? RemPacket.defaultPort : UInt16(clamping: value)
        }
        set { defaults.set(Int(newValue), forKey: "listenPort") }
    }

    // MARK: - Password (Keychain)

    public var password: String {
        get { Keychain.read(account: keychainAccount) }
        set { Keychain.write(newValue, account: keychainAccount) }
    }
}

/// Minimal Keychain string storage shared by the live settings and the profile store —
/// one generic-password item per account under the app's single service.
///
/// Items come in two flavours, and a given account can only be one at a time:
///
/// - **device-local** (the default): the legacy file keychain on macOS, never leaves the
///   device. The live password and, while profile sync is off, profile passwords.
/// - **synchronizable** (`kSecAttrSynchronizable`): carried between the user's devices by
///   iCloud Keychain, end-to-end encrypted — Apple cannot read it. This is what lets
///   profile passwords sync while the profile JSON in the key-value store stays
///   password-free (iCloud KVS is *not* end-to-end encrypted, so a password must never
///   go in there).
///
/// The two are distinct items even with the same service + account, so every query says
/// which one it means, and `setSynchronizable` moves an account between them.
enum Keychain {
    private static let service = "com.jonathan859.remsound"

    /// The attributes identifying one item. `synchronizable == nil` means "either kind",
    /// which is only valid for lookups, never for adds.
    private static func baseQuery(account: String, synchronizable: Bool?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        switch synchronizable {
        case .some(true):
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
            // Synchronizable items only exist in the data-protection keychain. On macOS
            // that is opt-in; on iOS it is the only keychain and the key is harmless.
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        case .some(false):
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        case .none:
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return query
    }

    /// Reads an account regardless of which keychain flavour holds it. macOS keeps
    /// device-local items in the legacy keychain and synchronizable ones in the
    /// data-protection keychain, and no single query spans both, so this tries each.
    static func read(account: String) -> String {
        for synchronizable in [nil, true] as [Bool?] {
            var query = baseQuery(account: account, synchronizable: synchronizable)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        return ""
    }

    /// An empty value deletes the item — in both flavours, so a stale copy left behind by
    /// a sync toggle can never resurrect a deleted profile's password.
    static func write(_ value: String, account: String, synchronizable: Bool = false) {
        if value.isEmpty {
            SecItemDelete(baseQuery(account: account, synchronizable: true) as CFDictionary)
            SecItemDelete(baseQuery(account: account, synchronizable: false) as CFDictionary)
            return
        }
        let query = baseQuery(account: account, synchronizable: synchronizable)
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Available after first unlock so a reboot while locked (iOS) can still
            // bring the receiver up once the user unlocks. Compatible with
            // synchronizable items — only the `…ThisDeviceOnly` classes are not.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Move an account between the device-local and iCloud-synchronizable keychains,
    /// preserving its value. Used when the profile-sync toggle flips: existing profile
    /// passwords have to follow, or sync would arrive on the other device with blanks.
    /// A no-op when the account has no value.
    static func setSynchronizable(_ on: Bool, account: String) {
        let value = read(account: account)
        guard !value.isEmpty else { return }
        SecItemDelete(baseQuery(account: account, synchronizable: !on) as CFDictionary)
        write(value, account: account, synchronizable: on)
    }
}
