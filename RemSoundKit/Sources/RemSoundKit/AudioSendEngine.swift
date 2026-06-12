import Foundation

/// Outbound audio stream — the Swift equivalent of one Windows `SenderLane`, Opus-only
/// (no PCM path, no multi-lane modes: one mixed-lane 48 kHz stereo stream).
///
/// Hot path: `submit` is called from the capture thread with 48 kHz interleaved stereo
/// float; samples accumulate into fixed 10 ms Opus frames, each frame is encoded,
/// encrypted (`nonce || tag || ciphertext`, mandatory — no password means nothing is
/// sent), and emitted to every target endpoint through `transport`. A Format packet is
/// re-announced every 250 ms on the same stream, matching the Windows sender's cadence,
/// so receivers can open the session at any time.
///
/// Configuration (`setKeyMaterial`, `setTargets`, `start`, `stop`) comes from the main
/// actor; a single lock serialises it against the capture thread. At ~100 frames/sec the
/// lock is uncontended noise.
public final class AudioSendEngine {
    /// 480 samples = 10 ms at 48 kHz — the Windows sender's default Opus frame.
    public static let opusFrameSamplesPerChannel = 480
    static let channels = 2
    private static let formatResendInterval: TimeInterval = 0.25

    private let lock = NSLock()

    // Pushed by the app; read on the capture thread.
    private var audioKey: [UInt8]?
    private var audioFingerprint: [UInt8]?
    private var targets: [UDPEndpoint] = []
    private var running = false

    // Capture-thread state, all touched under the lock.
    private let encryptor = AudioEncryptor()
    private var encoder: OpusStreamEncoder?
    private var accumulator = [Float](repeating: 0, count: opusFrameSamplesPerChannel * channels)
    private var accumulatorWritten = 0
    private var audioSequence: UInt32 = 0
    private var formatSequence: UInt32 = 0
    private var streamId: UInt16 = 1
    private var lastFormatSent = Date.distantPast

    public private(set) var packetsSent: Int64 = 0
    public private(set) var bytesSent: Int64 = 0

    /// Sends one datagram to one endpoint. Wired by the app to the receiver engine's audio
    /// socket so outbound audio shares the NAT pinhole heartbeats and inbound audio use.
    public var transport: ((_ data: [UInt8], _ endpoint: UDPEndpoint) -> Bool)?

    public init() {}

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// True when packets are actually leaving: running, key set, and at least one target.
    public var isSending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && audioKey != nil && !targets.isEmpty
    }

    public func setKeyMaterial(key: [UInt8]?, fingerprint: [UInt8]?) {
        lock.lock()
        audioKey = key
        audioFingerprint = fingerprint
        lock.unlock()
    }

    /// Replace the destination endpoints — one per peer (sending the same stream to two
    /// addresses of one machine would open two doubled-up sessions on its receiver).
    public func setTargets(_ endpoints: [UDPEndpoint]) {
        lock.lock()
        targets = endpoints
        lock.unlock()
    }

    /// Begin a fresh outbound stream: new random streamId (receivers key sessions on it),
    /// counters reset, immediate format announce on the next submitted buffer.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        encoder = OpusStreamEncoder(frameSizePerChannel: Self.opusFrameSamplesPerChannel)
        streamId = UInt16.random(in: 1..<UInt16.max)
        audioSequence = 0
        formatSequence = 0
        accumulatorWritten = 0
        lastFormatSent = .distantPast
        packetsSent = 0
        bytesSent = 0
        running = encoder != nil
    }

    public func stop() {
        lock.lock()
        running = false
        encoder = nil
        accumulatorWritten = 0
        lock.unlock()
    }

    // MARK: - Hot path (capture thread)

    /// Feed 48 kHz interleaved stereo float. `frameCount` is sample frames (L+R pairs).
    public func submit(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard running, let encoder, audioKey != nil, !targets.isEmpty else { return }
        encryptor.ensureKey(audioKey)
        guard encryptor.hasKey else { return }

        sendFormatIfDue()

        let frameFloats = encoder.frameSizePerChannel * Self.channels
        let totalFloats = frameCount * Self.channels
        var index = 0
        while index < totalFloats {
            let copy = min(frameFloats - accumulatorWritten, totalFloats - index)
            accumulator.withUnsafeMutableBufferPointer { acc in
                acc.baseAddress!.advanced(by: accumulatorWritten)
                    .update(from: samples.advanced(by: index), count: copy)
            }
            accumulatorWritten += copy
            index += copy
            if accumulatorWritten == frameFloats {
                emitFrame(encoder: encoder)
                accumulatorWritten = 0
            }
        }
    }

    private func emitFrame(encoder: OpusStreamEncoder) {
        let encoded = accumulator.withUnsafeBufferPointer { acc in
            encoder.encode(acc.baseAddress!)
        }
        guard let encoded, let ciphertext = encryptor.tryEncrypt(encoded) else { return }
        audioSequence &+= 1
        var packet = RemPacket.writeHeader(type: .audio, streamId: streamId, sequence: audioSequence)
        packet.append(contentsOf: ciphertext)
        sendToAll([UInt8](packet))
    }

    private func sendFormatIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastFormatSent) >= Self.formatResendInterval else { return }
        lastFormatSent = now

        // Same field values the Windows sender announces for Opus (bits/blockAlign describe
        // the pre-encode PCM; receivers key the session off codec + rate + frame size).
        let format = AudioFormatInfo(
            sampleRate: OpusStreamEncoder.sampleRate,
            channels: Self.channels,
            bitsPerSample: 16,
            encoding: 1,
            blockAlign: 4,
            averageBytesPerSecond: OpusStreamEncoder.bitrate,
            codec: .opus,
            frameSamplesPerChannel: Self.opusFrameSamplesPerChannel,
            lane: .mixed)
        formatSequence &+= 1
        var packet = RemPacket.writeHeader(type: .format, streamId: streamId, sequence: formatSequence)
        packet.append(RemPacket.writeFormatPayload(format, passwordFingerprint: audioFingerprint))
        sendToAll([UInt8](packet))
    }

    private func sendToAll(_ packet: [UInt8]) {
        guard let transport else { return }
        for target in targets where transport(packet, target) {
            packetsSent &+= 1
            bytesSent &+= Int64(packet.count)
        }
    }
}
