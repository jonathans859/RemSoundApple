import CommonCrypto
import CryptoKit
import Foundation

/// How a peer's encryption lines up with ours, derived from the password fingerprint it
/// advertises in its format packets. Mirrors `RemSound.Core.PeerSecurityStatus`.
public enum PeerSecurityStatus: Sendable {
    /// No fingerprint seen yet (or we have no password set) — nothing to report.
    case unknown
    /// Their password fingerprint matches ours: audio will decrypt, the link is secure.
    case secure
    /// They advertised a fingerprint, but it differs from ours — different passwords.
    case passwordMismatch
    /// No fingerprint at all — an older, pre-encryption Windows build that needs updating.
    case peerNeedsUpdate
}

/// Cryptographic helpers mirroring `RemSound.Core.RemSoundCrypto`. The parameters are part of
/// the wire contract and MUST match the Windows app exactly: PBKDF2-HMAC-SHA256, 100 000
/// iterations, fixed salts, AES-256-GCM with packet layout `nonce(12) || tag(16) || ciphertext`.
public enum RemSoundCrypto {
    public static let keyBytes = 32
    public static let fingerprintBytes = 8
    public static let nonceBytes = 12
    public static let tagBytes = 16
    /// nonce + tag — what encryption adds on top of the plaintext length.
    public static let encryptionOverheadBytes = 28

    private static let pbkdf2Iterations: UInt32 = 100_000
    private static let keySalt = Array("RemSound.v1.audio-key".utf8)
    private static let fingerprintSalt = Array("RemSound.v1.fingerprint".utf8)

    /// Derive the 256-bit AES key for a password. Slow on purpose (~100 ms) — run once per
    /// password change, never per packet.
    public static func deriveKey(password: String) -> [UInt8] {
        pbkdf2(password: password, salt: keySalt, outputBytes: keyBytes)
    }

    /// Short, non-reversible id for a password. Peers compare fingerprints to learn they
    /// share a password without revealing it.
    public static func fingerprint(password: String) -> [UInt8] {
        pbkdf2(password: password, salt: fingerprintSalt, outputBytes: fingerprintBytes)
    }

    private static func pbkdf2(password: String, salt: [UInt8], outputBytes: Int) -> [UInt8] {
        let passwordLength = password.utf8.count
        // Keep the buffer non-empty so the pointer is never NULL — the Windows side treats a
        // null/empty password as "" and we must derive the same bytes for it.
        var passwordBytes = Array(password.utf8)
        if passwordBytes.isEmpty { passwordBytes = [0] }
        var output = [UInt8](repeating: 0, count: outputBytes)
        let status = passwordBytes.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) },
                passwordLength,
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                pbkdf2Iterations,
                &output,
                outputBytes)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return output
    }

    /// Constant-time fingerprint comparison.
    public static func fingerprintsEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// Rebuilds a `SymmetricKey` only when the raw key bytes actually change (cheap comparison
/// on the common no-change path). Shared by `AudioEncryptor` / `AudioDecryptor`; each owner
/// uses its cache from a single thread.
struct SymmetricKeyCache {
    private(set) var key: SymmetricKey?
    private var keyBytesCached: [UInt8]?

    /// True when the key was actually rebuilt, so callers that hang state off the cipher
    /// (the send-side nonce sequence) know to reset it.
    @discardableResult
    mutating func ensure(_ keyBytes: [UInt8]?) -> Bool {
        if keyBytesCached == keyBytes { return false }
        keyBytesCached = keyBytes
        key = keyBytes.map { SymmetricKey(data: $0) }
        return true
    }
}

/// Nonce source for one encryptor: a random 48-bit prefix drawn when the cipher is built,
/// then a 48-bit little-endian counter — mirroring the Windows `RemSoundCrypto.NonceSequence`
/// (their 2026-07-26 audit). Uniqueness WITHIN an instance is arithmetic rather than
/// probabilistic; ACROSS instances (every launch and key rebuild restarts the counter at 0
/// under the same long-lived audio key) the random prefix keeps the ranges apart. That is the
/// point: 2^48 packets is unreachable, whereas a 96-bit random nonce's birthday bound is
/// something a heavy multi-day sender can actually approach.
///
/// Free on both budgets — the nonce is still the same 12 bytes on the wire, and this replaces
/// a CSPRNG draw per packet with a copy and an increment. Not thread-safe: one per encryptor,
/// same ownership rule as the key itself.
struct NonceSequence {
    private static let prefixBytes = 6
    private var prefix = [UInt8](repeating: 0, count: NonceSequence.prefixBytes)
    private var counter: UInt64 = 0

    init() { reset() }

    /// Fresh prefix, counter back to zero — called whenever the cipher key is rebuilt, so a
    /// new key never inherits an old counter and an old key never sees a repeated nonce.
    mutating func reset() {
        for i in 0..<Self.prefixBytes { prefix[i] = UInt8.random(in: 0...255) }
        counter = 0
    }

    /// prefix(6) ‖ counter(6, little-endian). The counter's top 16 bits are never used;
    /// 2^48 packets at our rates is tens of thousands of years, so it cannot wrap in practice.
    mutating func next() -> [UInt8] {
        var nonce = prefix
        let c = counter
        counter &+= 1
        for i in 0..<(RemSoundCrypto.nonceBytes - Self.prefixBytes) {
            nonce.append(UInt8((c >> (8 * UInt64(i))) & 0xFF))
        }
        return nonce
    }
}

/// Encrypts outgoing audio payloads — the send-side mirror of `AudioDecryptor`, matching the
/// Windows `SenderLane` cipher. Packet layout is the wire contract's
/// `nonce(12) || tag(16) || ciphertext`; CryptoKit's `combined` representation is
/// nonce || ciphertext || tag, so the pieces are emitted explicitly. Used exclusively on the
/// capture/encode thread.
public final class AudioEncryptor {
    private var keyCache = SymmetricKeyCache()
    private var nonces = NonceSequence()

    public init() {}

    public var hasKey: Bool { keyCache.key != nil }

    /// Rebuild the cipher key if the raw key bytes changed, restarting the nonce sequence
    /// with it (see `NonceSequence.reset`).
    public func ensureKey(_ keyBytes: [UInt8]?) {
        if keyCache.ensure(keyBytes) { nonces.reset() }
    }

    /// Encrypt a plaintext into the `nonce(12) || tag(16) || ciphertext` wire layout.
    /// Nil when no key is set (no password — mandatory encryption means nothing is sent)
    /// or on a CryptoKit failure. The nonce is counter-based, not CryptoKit's per-call
    /// random one — same 12 bytes on the wire, and the receiver just reads it off the packet.
    public func tryEncrypt(_ plaintext: ArraySlice<UInt8>) -> [UInt8]? {
        guard let key = keyCache.key else { return nil }
        guard
            let nonce = try? AES.GCM.Nonce(data: Data(nonces.next())),
            let box = try? AES.GCM.seal(Data(plaintext), using: key, nonce: nonce)
        else { return nil }
        var packet = [UInt8]()
        packet.reserveCapacity(plaintext.count + RemSoundCrypto.encryptionOverheadBytes)
        packet.append(contentsOf: box.nonce)
        packet.append(contentsOf: box.tag)
        packet.append(contentsOf: box.ciphertext)
        return packet
    }
}

/// Decrypts incoming audio payloads with the key derived from the configured password.
/// Mirrors the Windows `AudioDecryptor`: one instance shared by all stream sessions, used
/// exclusively on the network receive thread. Returns nil on auth failure (wrong password /
/// tampered packet) — the caller drops the packet, producing silence, never garbage.
public final class AudioDecryptor {
    private var keyCache = SymmetricKeyCache()

    public init() {}

    public var hasKey: Bool { keyCache.key != nil }

    /// Rebuild the cipher key if the raw key bytes changed.
    public func ensureKey(_ keyBytes: [UInt8]?) {
        keyCache.ensure(keyBytes)
    }

    /// Decrypt a `nonce(12) || tag(16) || ciphertext` packet. Nil on failure or no key.
    public func tryDecrypt(_ packet: ArraySlice<UInt8>) -> [UInt8]? {
        guard let key = keyCache.key else { return nil }
        let p = Array(packet)
        guard p.count >= RemSoundCrypto.encryptionOverheadBytes else { return nil }
        let nonceData = Data(p[0..<RemSoundCrypto.nonceBytes])
        let tag = Data(p[RemSoundCrypto.nonceBytes..<RemSoundCrypto.encryptionOverheadBytes])
        let ciphertext = Data(p[RemSoundCrypto.encryptionOverheadBytes...])
        guard
            let nonce = try? AES.GCM.Nonce(data: nonceData),
            let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
            let plaintext = try? AES.GCM.open(box, using: key)
        else { return nil }
        return [UInt8](plaintext)
    }
}
