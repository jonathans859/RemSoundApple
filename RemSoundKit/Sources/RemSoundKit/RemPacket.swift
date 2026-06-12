import Foundation

/// Wire format for RemSound packets, mirroring `RemSound.Core.RemPacket` in the Windows app
/// (v3.x wire protocol, header version 1). Header is 12 bytes; body length is implied by the
/// UDP datagram. Header layout (little-endian):
///
///     uint32 magic    'RMND'
///     uint8  version  1
///     uint8  type     RemPacketType
///     uint16 streamId
///     uint32 sequence
public enum RemPacketType: UInt8 {
    case format = 1
    case audio = 2
    /// Legacy (pre-2026-05-06 Windows builds). Silently ignored, never sent.
    case keepAlive = 3
    case heartbeat = 4
    /// Remote-control message (volume nudges). Not handled by this receiver in v1 —
    /// parsed and dropped, same wire-safety contract as old Windows peers.
    case control = 5
}

public enum HeartbeatKind: UInt8 {
    case ping = 0
    case pong = 1
}

public enum RemPacket {
    public static let headerSize = 12
    /// Minimum format payload (pre-2026-05-11 Windows senders).
    public static let formatPayloadSize = 32
    /// 32 base + 1 Lane byte + 3 reserved-zero bytes.
    public static let formatPayloadExtendedSize = 36
    /// Extended payload + 8-byte password fingerprint (2026-05-31+ senders).
    public static let formatPayloadWithFingerprintSize = 44
    public static let passwordFingerprintSize = 8
    /// 1 byte HeartbeatKind + 8 bytes originator-monotonic timestamp (ms).
    public static let heartbeatPayloadSize = 9
    /// Single canonical port: receiver bind, peer dials, and the public relay.
    public static let defaultPort: UInt16 = 47830
    public static let magic: UInt32 = 0x444E_4D52 // 'RMND' little-endian
    public static let version: UInt8 = 1

    // MARK: - Header

    public static func writeHeader(type: RemPacketType, streamId: UInt16, sequence: UInt32) -> Data {
        var data = Data(capacity: headerSize)
        data.appendLE(magic)
        data.append(version)
        data.append(type.rawValue)
        data.appendLE(streamId == 0 ? 1 : streamId)
        data.appendLE(sequence)
        return data
    }

    public struct Header {
        public let type: RemPacketType
        public let streamId: UInt16
        public let sequence: UInt32
        /// Raw type byte, kept so unknown types can be counted without crashing the enum.
        public let rawType: UInt8
    }

    /// Parses the 12-byte header. Returns nil for short packets, bad magic, or a header
    /// version other than 1. Unknown packet *types* still parse (Header.type is nil-mapped
    /// to nothing here — see `rawType`); the caller drops them, matching the Windows
    /// receiver's silent-drop dispatch.
    public static func readHeader(_ packet: [UInt8], length: Int) -> Header? {
        guard length >= headerSize, packet.count >= headerSize else { return nil }
        let m = UInt32(packet[0]) | UInt32(packet[1]) << 8 | UInt32(packet[2]) << 16 | UInt32(packet[3]) << 24
        guard m == magic, packet[4] == version else { return nil }
        let rawType = packet[5]
        guard let type = RemPacketType(rawValue: rawType) else { return nil }
        var streamId = UInt16(packet[6]) | UInt16(packet[7]) << 8
        if streamId == 0 { streamId = 1 }
        let sequence = UInt32(packet[8]) | UInt32(packet[9]) << 8 | UInt32(packet[10]) << 16 | UInt32(packet[11]) << 24
        return Header(type: type, streamId: streamId, sequence: sequence, rawType: rawType)
    }

    // MARK: - Format payload

    /// Reads a Format payload (legacy 32-byte, extended 36-byte, or fingerprinted 44-byte).
    /// Unknown Lane values clamp to `.mixed` (forward-compat — better to play the audio in
    /// the default route than drop the stream). A missing fingerprint means the sender is a
    /// pre-encryption build that needs to update.
    public static func readFormat(_ payload: ArraySlice<UInt8>) -> (format: AudioFormatInfo, passwordFingerprint: [UInt8]?)? {
        let p = Array(payload)
        guard p.count >= formatPayloadSize else { return nil }

        func int32(_ offset: Int) -> Int32 {
            Int32(bitPattern: UInt32(p[offset]) | UInt32(p[offset + 1]) << 8 | UInt32(p[offset + 2]) << 16 | UInt32(p[offset + 3]) << 24)
        }

        var fingerprint: [UInt8]? = nil
        if p.count >= formatPayloadWithFingerprintSize {
            fingerprint = Array(p[36..<44])
        }

        var lane = RenderRoute.mixed
        if p.count >= formatPayloadExtendedSize {
            lane = RenderRoute(rawValue: p[32]) ?? .mixed
        }

        let format = AudioFormatInfo(
            sampleRate: Int(int32(0)),
            channels: Int(int32(4)),
            bitsPerSample: Int(int32(8)),
            encoding: Int(int32(12)),
            blockAlign: Int(int32(16)),
            averageBytesPerSecond: Int(int32(20)),
            codec: AudioTransportCodec(rawValue: Int(int32(24))) ?? .pcm,
            frameSamplesPerChannel: Int(int32(28)),
            lane: lane)
        return (format, fingerprint)
    }

    /// Writes a Format payload, mirroring the Windows `RemPacket.WriteFormatPayload`:
    /// eight little-endian int32 fields, the Lane byte + 3 reserved-zero bytes, and (when a
    /// fingerprint is supplied) the 8-byte password fingerprint — 36 or 44 bytes total.
    public static func writeFormatPayload(_ format: AudioFormatInfo, passwordFingerprint: [UInt8]?) -> Data {
        var data = Data(capacity: formatPayloadWithFingerprintSize)
        data.appendLE(UInt32(bitPattern: Int32(format.sampleRate)))
        data.appendLE(UInt32(bitPattern: Int32(format.channels)))
        data.appendLE(UInt32(bitPattern: Int32(format.bitsPerSample)))
        data.appendLE(UInt32(bitPattern: Int32(format.encoding)))
        data.appendLE(UInt32(bitPattern: Int32(format.blockAlign)))
        data.appendLE(UInt32(bitPattern: Int32(format.averageBytesPerSecond)))
        data.appendLE(UInt32(bitPattern: Int32(format.codec.rawValue)))
        data.appendLE(UInt32(bitPattern: Int32(format.frameSamplesPerChannel)))
        data.append(format.lane.rawValue)
        data.append(contentsOf: [0, 0, 0]) // reserved
        if let passwordFingerprint, passwordFingerprint.count == passwordFingerprintSize {
            data.append(contentsOf: passwordFingerprint)
        }
        return data
    }

    // MARK: - Heartbeat payload

    public static func writeHeartbeatPayload(kind: HeartbeatKind, originatorTickMs: Int64) -> Data {
        var data = Data(capacity: heartbeatPayloadSize)
        data.append(kind.rawValue)
        data.appendLE(UInt64(bitPattern: originatorTickMs))
        return data
    }

    public static func readHeartbeat(_ payload: ArraySlice<UInt8>) -> (kind: HeartbeatKind, originatorTickMs: Int64)? {
        let p = Array(payload)
        guard p.count >= heartbeatPayloadSize, let kind = HeartbeatKind(rawValue: p[0]) else { return nil }
        var tick: UInt64 = 0
        for i in 0..<8 { tick |= UInt64(p[1 + i]) << (8 * i) }
        return (kind, Int64(bitPattern: tick))
    }
}

/// PCM transport sub-header, mirroring `RemPcmFrame`. PCM frames are larger than one UDP
/// datagram, so they're split into multi-part chunks. Sub-header (6 bytes, little-endian)
/// prepended to the audio bytes:
///
///     uint32 frameId
///     uint8  partIndex
///     uint8  totalParts
public enum RemPcmFrame {
    public static let subHeaderSize = 6

    public static func readSubHeader(_ source: ArraySlice<UInt8>) -> (frameId: UInt32, partIndex: UInt8, totalParts: UInt8)? {
        let p = Array(source)
        guard p.count >= subHeaderSize else { return nil }
        let frameId = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
        let partIndex = p[4]
        let totalParts = p[5]
        guard totalParts > 0, partIndex < totalParts else { return nil }
        return (frameId, partIndex, totalParts)
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }

    mutating func appendLE(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }
}
