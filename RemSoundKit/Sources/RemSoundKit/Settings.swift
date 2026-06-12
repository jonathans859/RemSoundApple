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

/// Single-config persistent settings (the Apple receiver deliberately has no profile system
/// in v1). Plain values in UserDefaults; the password in the Keychain.
public final class ReceiverSettings {
    private let defaults: UserDefaults
    private let keychainService = "com.jonathan859.remsound"
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

    /// Stable id of the input the user picked for microphone sending (see
    /// `MicrophoneCapture.availableInputs`). Nil/empty = system default input.
    public var selectedMicrophoneId: String? {
        get {
            let value = defaults.string(forKey: "selectedMicrophoneId")
            return (value?.isEmpty ?? true) ? nil : value
        }
        set { defaults.set(newValue ?? "", forKey: "selectedMicrophoneId") }
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
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else { return "" }
            return value
        }
        set {
            let baseQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
            ]
            if newValue.isEmpty {
                SecItemDelete(baseQuery as CFDictionary)
                return
            }
            let data = Data(newValue.utf8)
            let status = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var addQuery = baseQuery
                addQuery[kSecValueData as String] = data
                // Available after first unlock so a reboot while locked (iOS) can still
                // bring the receiver up once the user unlocks.
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(addQuery as CFDictionary, nil)
            }
        }
    }
}
