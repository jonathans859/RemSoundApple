import CryptoKit
import Foundation

/// "I have ticked you, and I hold the password" — packet type 11, upstream `TickProof.cs`
/// (Windows 6.0, 2026-09-25). A peer that ticks somebody sends this to them every
/// `sendInterval`, whatever it sends or receives, so the other end's "Accept connections" can
/// act on a peer that only listens. Without it a phone listening with its mic off sends
/// nothing that proves the password — a format packet is the only other thing that does.
///
/// Wire layout (pinned by upstream's cross-port self-test): the ordinary 12-byte header, type
/// 11, stream id 0xFFFF, then 53 sealed bytes — `nonce(12) ‖ tag(16) ‖ ciphertext(25)`, sealed
/// with the SAME AES-256-GCM key the audio uses, under a random nonce. The 25 plaintext bytes:
/// format version (1, = 1), the sender's UTC time in Unix seconds (8, little-endian), and the
/// sender's discovery instance id (16, RFC 4122 byte order — the order its text form reads).
/// Older peers drop the unknown type, as they did 5 and 10.
enum TickProof {
    static let formatVersion: UInt8 = 1
    /// version(1) + unix-utc-seconds(8) + instance id(16).
    static let plainBytes = 25
    /// What goes on the wire after the header (= 53).
    static let sealedPayloadBytes = plainBytes + RemSoundCrypto.encryptionOverheadBytes
    static let sendInterval: TimeInterval = 5
    static let streamId: UInt16 = 0xFFFF

    struct Opened: Equatable {
        let instanceId: UUID
        let unixSeconds: Int64
        /// The first 8 nonce bytes, little-endian: random per seal, so they identify this one
        /// packet for the replay memory.
        let nonceId: UInt64
    }

    static func plaintext(instanceId: UUID, unixSeconds: Int64) -> [UInt8] {
        var plain: [UInt8] = [formatVersion]
        let time = UInt64(bitPattern: unixSeconds)
        for i in 0..<8 { plain.append(UInt8((time >> (8 * UInt64(i))) & 0xFF)) }
        withUnsafeBytes(of: instanceId.uuid) { plain.append(contentsOf: $0) }
        return plain
    }

    /// Seal any plaintext into the wire's `nonce ‖ tag ‖ ciphertext` order (CryptoKit's
    /// `combined` is nonce ‖ ciphertext ‖ tag, which is NOT it). Random nonce, as upstream.
    static func seal(key: [UInt8], plaintext: [UInt8]) -> [UInt8]? {
        guard key.count == RemSoundCrypto.keyBytes,
              let box = try? AES.GCM.seal(Data(plaintext), using: SymmetricKey(data: key))
        else { return nil }
        return [UInt8](box.nonce) + [UInt8](box.tag) + [UInt8](box.ciphertext)
    }

    static func buildPacket(key: [UInt8], instanceId: UUID, unixSeconds: Int64,
                            sequence: UInt32) -> [UInt8]? {
        guard let sealed = seal(key: key, plaintext: plaintext(instanceId: instanceId,
                                                               unixSeconds: unixSeconds))
        else { return nil }
        return [UInt8](RemPacket.writeHeader(type: .tickProof, streamId: streamId, sequence: sequence))
            + sealed
    }

    /// Open a sealed proof (the payload after the header). nil when the size is wrong, the
    /// tag fails — another password, or tampering — or the version is one we do not know.
    static func open(key: [UInt8], payload: ArraySlice<UInt8>) -> Opened? {
        let p = Array(payload)
        guard p.count == sealedPayloadBytes, key.count == RemSoundCrypto.keyBytes else { return nil }
        let nonceEnd = RemSoundCrypto.nonceBytes
        let tagEnd = RemSoundCrypto.encryptionOverheadBytes
        guard let nonce = try? AES.GCM.Nonce(data: Data(p[0..<nonceEnd])),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(p[tagEnd...]),
                                               tag: Data(p[nonceEnd..<tagEnd])),
              let opened = try? AES.GCM.open(box, using: SymmetricKey(data: key))
        else { return nil }
        let plain = [UInt8](opened)
        guard plain.count == plainBytes, plain[0] == formatVersion else { return nil }
        var time: UInt64 = 0
        for i in 0..<8 { time |= UInt64(plain[1 + i]) << (8 * UInt64(i)) }
        let b = Array(plain[9..<25])
        let id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                             b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        var nonceId: UInt64 = 0
        for i in 0..<8 { nonceId |= UInt64(p[i]) << (8 * UInt64(i)) }
        return Opened(instanceId: id, unixSeconds: Int64(bitPattern: time), nonceId: nonceId)
    }
}

/// Receiver-side gate for tick proofs (upstream `TickProofGuard`): opens with our key, bounds
/// staleness generously because peers' clocks are not synchronised, and never accepts the
/// same seal twice — so a captured proof, replayed from another address, proves nothing.
/// Main-actor use only (the controller owns it).
struct TickProofGuard {
    enum Outcome: Equatable {
        case accepted(UUID)
        /// Did not open with our key: that address uses another password (or is not RemSound).
        case notOurPassword
        case stale
        case replay
    }

    static let maxSkew: TimeInterval = 600
    private static let memoryCap = 4096
    private var seen: [UInt64: Date] = [:]

    mutating func check(key: [UInt8], payload: ArraySlice<UInt8>, now: Date) -> Outcome {
        guard let opened = TickProof.open(key: key, payload: payload) else { return .notOurPassword }
        let age = now.timeIntervalSince1970 - Double(opened.unixSeconds)
        guard abs(age) <= Self.maxSkew else { return .stale }
        guard seen[opened.nonceId] == nil else { return .replay }
        // One every few seconds per peer for as long as it has us ticked: prune anything that
        // could no longer pass the skew check anyway, and hard-cap against a flood.
        if seen.count >= Self.memoryCap {
            seen = seen.filter { now.timeIntervalSince($0.value) <= 2 * Self.maxSkew }
            if seen.count >= Self.memoryCap { seen.removeAll() }
        }
        seen[opened.nonceId] = now
        return .accepted(opened.instanceId)
    }
}
