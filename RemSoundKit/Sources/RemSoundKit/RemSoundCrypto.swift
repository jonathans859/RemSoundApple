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

/// Encrypts outgoing audio payloads — the send-side mirror of `AudioDecryptor`, matching the
/// Windows `SenderLane` cipher. Packet layout is the wire contract's
/// `nonce(12) || tag(16) || ciphertext`; CryptoKit's `combined` representation is
/// nonce || ciphertext || tag, so the pieces are emitted explicitly. Used exclusively on the
/// capture/encode thread.
public final class AudioEncryptor {
    private var key: SymmetricKey?
    private var keyBytesCached: [UInt8]?

    public init() {}

    public var hasKey: Bool { key != nil }

    /// Rebuild the cipher key if the raw key bytes changed. Cheap comparison on the
    /// common no-change path.
    public func ensureKey(_ keyBytes: [UInt8]?) {
        if keyBytesCached == keyBytes { return }
        keyBytesCached = keyBytes
        key = keyBytes.map { SymmetricKey(data: $0) }
    }

    /// Encrypt a plaintext into the `nonce(12) || tag(16) || ciphertext` wire layout.
    /// Nil when no key is set (no password — mandatory encryption means nothing is sent)
    /// or on a CryptoKit failure.
    public func tryEncrypt(_ plaintext: ArraySlice<UInt8>) -> [UInt8]? {
        guard let key else { return nil }
        guard let box = try? AES.GCM.seal(Data(plaintext), using: key) else { return nil }
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
    private var key: SymmetricKey?
    private var keyBytesCached: [UInt8]?

    public init() {}

    public var hasKey: Bool { key != nil }

    /// Rebuild the cipher key if the raw key bytes changed. Cheap comparison on the
    /// common no-change path.
    public func ensureKey(_ keyBytes: [UInt8]?) {
        if keyBytesCached == keyBytes { return }
        keyBytesCached = keyBytes
        key = keyBytes.map { SymmetricKey(data: $0) }
    }

    /// Decrypt a `nonce(12) || tag(16) || ciphertext` packet. Nil on failure or no key.
    public func tryDecrypt(_ packet: ArraySlice<UInt8>) -> [UInt8]? {
        guard let key else { return nil }
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
