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
