import Foundation

/// The relay's **group framing** — header version 2 — and the four packet types only a
/// server and its members exchange (hello / roster / full / bye).
///
/// A RemSound server (the thing the code and this protocol still call a relay) used to carry
/// exactly one pair: the first two devices to reach it got in and a third heard nothing.
/// From server-v2.9 everyone using one server with the same password is one *group*, each
/// member a person of their own. The wire problem that forced new framing: every RemSound
/// implementation keys a peer by its address, and through a server everybody arrives from
/// the server's address, so each packet has to say whose it is. Group framing is the
/// ordinary 12-byte header with its version byte set to 2, then the sender's 16-byte client
/// id, then the ordinary payload untouched:
///
///     0  4  magic 'RMND'
///     4  1  version 2
///     5  1  type (Format 1, Audio 2, Heartbeat 4, Control 5, Hello 6, Roster 7, Full 8, Bye 9)
///     6  2  streamId, LE
///     8  4  sequence, LE
///     12 16 client id — the sender's; all zeros when the server itself sent it
///     28 .. the ordinary payload
///
/// Nothing here is required to keep working against a server: `RemPacket.readHeader` drops
/// every version-2 packet, which is exactly what a pre-groups client does, and the server
/// still hands such a client one of its two ordinary pair slots. This is what lets us be one
/// of several people on a server instead of one of two.
///
/// Spec: `server/RELAY-GROUPS.md` and `IPHONE-CHANGES.md` in the upstream drop (Ednunp,
/// 2026-09-20); the server itself is `server/remsound-relay.py`, and the Windows client side
/// is `src/RemSound.Core/RelayGroupClient.cs`.
public enum RelayGroup {
    /// The header version byte the server reads as group framing.
    public static let version: UInt8 = 2
    public static let clientIdSize = 16
    /// The ordinary 12-byte header plus the client id.
    public static let headerSize = RemPacket.headerSize + clientIdSize
    /// Display-name field: UTF-8, zero-padded, cut to this many bytes.
    public static let nameFieldSize = 32
    /// The group tag is the 8-byte password fingerprint — the same bytes a Format payload
    /// already carries in the clear at offset 36, so it tells the server nothing new.
    public static let groupTagSize = RemPacket.passwordFingerprintSize
    /// The most people one hello can name as ticked, matching the server's own cap.
    public static let maxTickedIds = 64
    /// One roster entry: client id, name, and that member's own flags byte.
    public static let rosterEntrySize = clientIdSize + nameFieldSize + 1
    /// A roster entry from a server older than v2.9, which did not say who had ticked you.
    public static let rosterEntrySizeWithoutFlags = clientIdSize + nameFieldSize
    /// Trailing list-flags bit 0: we also hold one of the server's ordinary pair slots, with
    /// a partner (a phone or an older app) on the other end of it.
    public static let listFlagPairedWithOrdinary: UInt8 = 0x01
    /// Per-member flags bit 0: **that member has ticked us**. Nothing else can tell a person
    /// the difference between "not set up yet" and "something is wrong".
    public static let memberFlagTicksUs: UInt8 = 0x01
    /// How often we say hello while connected, and the server's own roster cadence.
    public static let helloInterval: TimeInterval = 2
    /// The server sends a roster every second; this long without one and the group is cold.
    public static let rosterAliveFor: TimeInterval = 5
    /// A goodbye goes this many times, this far apart (upstream v6.2 `ByeCopies` /
    /// `ByeRepeatMs`): one lost on the way kept the next copy of us out for the server's
    /// five-second rebind silence, and left us listed until its idle timeout.
    public static let byeCopies = 3
    public static let byeRepeatInterval: TimeInterval = 0.1

    // MARK: - Header

    public struct Header {
        public let type: RemPacketType
        public let streamId: UInt16
        public let sequence: UInt32
        public let clientId: RelayClientId

        /// What the same packet's ordinary 12-byte header says, for a caller that goes on to
        /// treat the payload as if it had arrived directly from that member.
        public var asOrdinary: RemPacket.Header {
            RemPacket.Header(type: type, streamId: streamId, sequence: sequence)
        }
    }

    /// Parses a group header. nil for anything that is not group-framed (short, bad magic,
    /// version != 2) or carries a type we do not know — the caller drops it, matching the
    /// silent-drop dispatch everywhere else in this port.
    public static func readHeader(_ packet: [UInt8], length: Int) -> Header? {
        guard length >= headerSize, packet.count >= headerSize else { return nil }
        let m = UInt32(packet[0]) | UInt32(packet[1]) << 8 | UInt32(packet[2]) << 16 | UInt32(packet[3]) << 24
        guard m == RemPacket.magic, packet[4] == version else { return nil }
        guard let type = RemPacketType(rawValue: packet[5]) else { return nil }
        var streamId = UInt16(packet[6]) | UInt16(packet[7]) << 8
        if streamId == 0 { streamId = 1 }
        let sequence = UInt32(packet[8]) | UInt32(packet[9]) << 8
            | UInt32(packet[10]) << 16 | UInt32(packet[11]) << 24
        guard let id = RelayClientId(bytes: Array(packet[RemPacket.headerSize..<headerSize])) else { return nil }
        return Header(type: type, streamId: streamId, sequence: sequence, clientId: id)
    }

    public static func writeHeader(
        type: RemPacketType, streamId: UInt16, sequence: UInt32, clientId: RelayClientId
    ) -> Data {
        var data = RemPacket.writeHeader(type: type, streamId: streamId, sequence: sequence)
        data[4] = version
        data.append(contentsOf: clientId.bytes)
        return data
    }

    /// Put an ordinary packet into group framing: the same header with version 2, our client
    /// id, then the payload untouched. 16 bytes larger — which is why an uncompressed frame
    /// has to be sized to still fit one datagram (ours is 2.5 ms / 120 samples, far under).
    public static func wrap(_ packet: [UInt8], clientId: RelayClientId) -> [UInt8]? {
        guard packet.count >= RemPacket.headerSize else { return nil }
        var wrapped = [UInt8]()
        wrapped.reserveCapacity(packet.count + clientIdSize)
        wrapped.append(contentsOf: packet[0..<RemPacket.headerSize])
        wrapped[4] = version
        wrapped.append(contentsOf: clientId.bytes)
        wrapped.append(contentsOf: packet[RemPacket.headerSize...])
        return wrapped
    }

    // MARK: - Hello (type 6)

    /// Our hello's payload: name, the group tag, then the people we have ticked — a count and
    /// that many client ids.
    ///
    /// The tick list is what decides who hears us. **Leaving it off entirely** (a 40-byte
    /// payload) means "everyone in my group", which is what every pre-groups app sends and why
    /// nothing in the field breaks; a count of 0 means "nobody yet". We always send a list,
    /// even when it is empty, because we always know exactly who the user has ticked.
    public static func helloPayload(name: String, groupTag: [UInt8], ticked: [RelayClientId]) -> Data {
        var data = Data(capacity: nameFieldSize + groupTagSize + 1 + ticked.count * clientIdSize)
        data.append(contentsOf: encodeName(name))
        data.append(contentsOf: groupTag.count == groupTagSize
            ? groupTag : [UInt8](repeating: 0, count: groupTagSize))
        let capped = ticked.prefix(maxTickedIds)
        data.append(UInt8(capped.count))
        for id in capped { data.append(contentsOf: id.bytes) }
        return data
    }

    public static func helloPacket(
        clientId: RelayClientId, name: String, groupTag: [UInt8], ticked: [RelayClientId]
    ) -> [UInt8] {
        var packet = writeHeader(type: .lobbyHello, streamId: 0, sequence: 0, clientId: clientId)
        packet.append(helloPayload(name: name, groupTag: groupTag, ticked: ticked))
        return [UInt8](packet)
    }

    /// Leaving: the others see us go at once instead of after the server's idle timeout.
    public static func byePacket(clientId: RelayClientId) -> [UInt8] {
        [UInt8](writeHeader(type: .lobbyBye, streamId: 0, sequence: 0, clientId: clientId))
    }

    // MARK: - Roster (type 7)

    public struct RosterEntry: Hashable, Sendable {
        public let id: RelayClientId
        public let name: String
        /// This member has ticked us. Sound only flows when both have, so this is the
        /// difference between "waiting for them" and "it is broken".
        public let ticksUs: Bool
    }

    public struct Roster: Sendable {
        public let members: [RosterEntry]
        /// We also hold one of the server's ordinary pair slots, with a partner on it.
        public let pairedWithOrdinary: Bool
    }

    /// Reads a roster payload: a count byte, that many fixed-size entries, then one flags
    /// byte for the list as a whole.
    ///
    /// The server includes **us** in the list; the caller drops its own id.
    ///
    /// Entries were 48 bytes before server-v2.9 (no per-member flags byte), so the size is
    /// taken from the payload length rather than assumed. Resolving it by "long enough for
    /// 49-byte entries plus the trailing byte" is unambiguous for every count, because the
    /// count byte is known: the two layouts only ever produce the same length for *different*
    /// counts (49×48 == 48×49).
    public static func readRoster(_ payload: ArraySlice<UInt8>) -> Roster? {
        let p = Array(payload)
        guard let first = p.first else { return nil }
        let count = Int(first)
        let entrySize = p.count >= 1 + count * rosterEntrySize + 1
            ? rosterEntrySize : rosterEntrySizeWithoutFlags
        guard p.count >= 1 + count * entrySize else { return nil }

        var members: [RosterEntry] = []
        members.reserveCapacity(count)
        for i in 0..<count {
            let start = 1 + i * entrySize
            guard let id = RelayClientId(bytes: Array(p[start..<(start + clientIdSize)])) else { continue }
            let name = decodeName(p[(start + clientIdSize)..<(start + clientIdSize + nameFieldSize)])
            let ticksUs = entrySize == rosterEntrySize
                && (p[start + entrySize - 1] & memberFlagTicksUs) != 0
            members.append(RosterEntry(id: id, name: name, ticksUs: ticksUs))
        }

        let flagsIndex = 1 + count * entrySize
        let flags = flagsIndex < p.count ? p[flagsIndex] : 0
        return Roster(members: members, pairedWithOrdinary: (flags & listFlagPairedWithOrdinary) != 0)
    }

    // MARK: - Full (type 8)

    /// "There is no room for you": the server's current client count and its maximum.
    public static func readFull(_ payload: ArraySlice<UInt8>) -> (count: Int, maximum: Int)? {
        let p = Array(payload)
        guard p.count >= 2 else { return nil }
        return (Int(p[0]), Int(p[1]))
    }

    // MARK: - Name field

    /// The 32-byte display-name field: UTF-8, **cut on a character boundary**, zero-padded.
    /// Truncating mid-codepoint would put a replacement character in everyone else's list.
    public static func encodeName(_ name: String) -> [UInt8] {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.utf8.count > nameFieldSize { text.removeLast() }
        var field = [UInt8](text.utf8)
        field.append(contentsOf: [UInt8](repeating: 0, count: nameFieldSize - field.count))
        return field
    }

    /// Reads a name field back — zero-terminated, and tolerant of whatever is in it (the
    /// server pads and truncates on bytes, and a hostile member can put anything here).
    public static func decodeName(_ field: ArraySlice<UInt8>) -> String {
        let bytes = Array(field)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[0..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A member's identity on a server: 16 bytes, picked once per install and kept, never all
/// zero (the server uses an all-zero id for itself). It is what makes us the same person in
/// everyone's list each time, so a tick on the other end survives a restart — and it is the
/// only thing that tells members apart, because through a server they all arrive from one
/// address.
public struct RelayClientId: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == RelayGroup.clientIdSize else { return nil }
        self.bytes = bytes
    }

    /// Parses the persisted form (32 hex characters). nil for anything else, including an
    /// all-zero id — a stored id that reads back as zero must be replaced, not used.
    public init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == RelayGroup.clientIdSize * 2 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(RelayGroup.clientIdSize)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = bytes
    }

    /// A fresh id. Loops on the vanishingly unlikely all-zero draw rather than accepting it:
    /// zero is the server's own id on the wire, so it is not ours to use.
    public static func random() -> RelayClientId {
        while true {
            var bytes = [UInt8](repeating: 0, count: RelayGroup.clientIdSize)
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
            if bytes.contains(where: { $0 != 0 }), let id = RelayClientId(bytes: bytes) { return id }
        }
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var isZero: Bool { !bytes.contains { $0 != 0 } }
    /// Enough of the id to tell two members apart in a log line.
    public var shortHex: String { String(hex.prefix(8)) }
    public var description: String { shortHex }

    /// FNV-1a over the 16 bytes — the seed for this member's stand-in address. Windows
    /// derives the same figure the same way, which is not required by the protocol but keeps
    /// a log line from one platform readable next to the other.
    var addressHash: UInt32 {
        var hash: UInt32 = 2166136261
        for byte in bytes { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return hash
    }
}
