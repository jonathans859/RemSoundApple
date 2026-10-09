import Foundation

/// How audio is carried on the wire. Also the user-facing choice for our own microphone
/// stream (`ReceiverSettings.sendCodec`), which is why it is `Codable` — it is stored in
/// profiles by raw value, and those raw values are the wire's, so they can never be renumbered.
public enum AudioTransportCodec: Int, Sendable, Codable, Hashable {
    case pcm = 1
    case opus = 2

    /// Short name for status lines and pickers — spoken, so no abbreviation beyond the
    /// codec's own name.
    public var displayName: String {
        switch self {
        case .pcm: return "PCM"
        case .opus: return "Opus"
        }
    }
}

/// Which render lane a stream is tagged for. The Windows sender's BothIndependent mode emits
/// two parallel streams tagged `wasapiLane` / `asioLane`; this receiver has a single output,
/// so the tag only matters for session identity (two lanes from one peer must coexist) — all
/// lanes mix into the one output.
public enum RenderRoute: UInt8, Sendable {
    case mixed = 0
    case wasapiLane = 1
    case asioLane = 2
}

/// Audio format announcement carried in every Format packet, mirroring
/// `RemSound.Core.AudioFormatInfo`. Note `frameSamplesPerChannel` is an exact sample count at
/// `sampleRate` (v3.0 wire change, 2026-05-23) — NOT milliseconds.
public struct AudioFormatInfo: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let encoding: Int
    public let blockAlign: Int
    public let averageBytesPerSecond: Int
    public let codec: AudioTransportCodec
    public let frameSamplesPerChannel: Int
    public let lane: RenderRoute

    public init(
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int,
        encoding: Int,
        blockAlign: Int,
        averageBytesPerSecond: Int,
        codec: AudioTransportCodec = .pcm,
        frameSamplesPerChannel: Int = 480,
        lane: RenderRoute = .mixed
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.encoding = encoding
        self.blockAlign = blockAlign
        self.averageBytesPerSecond = averageBytesPerSecond
        self.codec = codec
        self.frameSamplesPerChannel = frameSamplesPerChannel
        self.lane = lane
    }

    /// Largest frame Opus can encode at 48 kHz (60 ms); nothing on the wire may legitimately
    /// exceed it, and the decode scratch is sized from this field.
    public static let maxFrameSamplesPerChannel = 2880

    /// Why this format cannot be played, or nil when it can. A Format packet is the one
    /// packet that is neither encrypted nor authenticated, so every field arrives unchecked
    /// from the network: zero channels divides by zero in the PCM path, and a huge frame size
    /// sizes the Opus decode scratch. Fail closed, as upstream does since its 2026-08-23
    /// audit (finding R4, `AudioFormatInfo.IsUsable`). Rejects only values no RemSound has
    /// ever sent; the fields we do not act on (bits, encoding, block align, bytes/s) are
    /// deliberately not checked, so a port that fills them differently keeps working.
    public var unusableReason: String? {
        if !(1...2).contains(channels) {
            return "channel count \(channels) (must be 1 or 2)"
        }
        if !(8000...192_000).contains(sampleRate) {
            return "sample rate \(sampleRate) (outside 8000-192000)"
        }
        if !(1...Self.maxFrameSamplesPerChannel).contains(frameSamplesPerChannel) {
            return "frame size \(frameSamplesPerChannel) samples (must be 1-\(Self.maxFrameSamplesPerChannel))"
        }
        // libopus accepts only these rates; its decoder would fail to construct on anything else.
        if codec == .opus, ![8000, 12000, 16000, 24000, 48000].contains(sampleRate) {
            return "Opus at \(sampleRate) Hz (Opus supports 8000, 12000, 16000, 24000 or 48000)"
        }
        return nil
    }

    /// Human-friendly frame duration; may be fractional (2.5 ms at 48 kHz / 120 samples).
    public var frameDurationMs: Double {
        sampleRate > 0 ? Double(frameSamplesPerChannel) * 1000.0 / Double(sampleRate) : 0
    }

    /// Session identity for format-change detection — same fields the Windows receiver's
    /// `StreamSession.MatchesFormat` compares.
    public func matchesIdentity(of other: AudioFormatInfo) -> Bool {
        codec == other.codec
            && sampleRate == other.sampleRate
            && channels == other.channels
            && frameSamplesPerChannel == other.frameSamplesPerChannel
    }

    public var displayDescription: String {
        let encodingName: String
        switch encoding {
        case 1: encodingName = "PCM"
        case 3: encodingName = "IEEE float"
        default: encodingName = "encoding \(encoding)"
        }
        let codecName = codec == .opus ? String(format: " over Opus (%.2f ms)", frameDurationMs) : ""
        return "\(sampleRate) Hz, \(channels) channel(s), \(bitsPerSample)-bit \(encodingName)\(codecName)"
    }
}
