import Foundation

/// Outbound audio stream — the Swift equivalent of one Windows `SenderLane`, minus the
/// multi-lane modes (one mixed-lane 48 kHz stereo stream). Either codec the wire defines can
/// carry it: Opus at 10 ms frames (the default — 192 kbps), or raw PCM at 2.5 ms frames
/// (24-bit, 288 kB/s), chosen by the user per `ReceiverSettings.sendCodec`.
///
/// Hot path: `submit` is called from the capture thread with 48 kHz interleaved stereo
/// float; samples accumulate into fixed frames, each frame is encoded (Opus) or packed to
/// int24-LE (PCM), encrypted (`nonce || tag || ciphertext`, mandatory — no password means
/// nothing is sent), and emitted to every target endpoint through `transport`. A Format
/// packet is re-announced every 250 ms on the same stream, matching the Windows sender's
/// cadence, so receivers can open the session at any time.
///
/// Configuration (`setKeyMaterial`, `setTargets`, `setCodec`, `start`, `stop`) comes from the
/// main actor; a single lock serialises it against the capture thread. At ~100-400 frames/sec
/// the lock is uncontended noise.
public final class AudioSendEngine {
    /// 480 samples = 10 ms at 48 kHz — the Windows sender's default Opus frame.
    public static let opusFrameSamplesPerChannel = 480
    /// 120 samples = 2.5 ms at 48 kHz — the Windows sender's "Tight" PCM frame, and the only
    /// PCM size whose encrypted frame still fits ONE datagram (120 × 2 × 3 = 720 bytes
    /// + 28 bytes of crypto, against a 1454-byte budget). Upstream's 5 ms default spills into
    /// a second part, and a PCM frame is all-or-nothing on the receiver — either part lost
    /// drops the whole frame — so the smaller frame also halves what one lost packet costs.
    public static let pcmFrameSamplesPerChannel = 120
    /// Wire rate for both codecs; the capture path converts to it.
    public static let sampleRate = 48_000
    static let channels = 2
    private static let formatResendInterval: TimeInterval = 0.25

    private let lock = NSLock()

    // Pushed by the app; read on the capture thread.
    private var audioKey: [UInt8]?
    private var audioFingerprint: [UInt8]?
    private var targets: [UDPEndpoint] = []
    private var codec: AudioTransportCodec = .opus
    private var captureLatencyMs: Double = 0
    private var running = false

    // Capture-thread state, all touched under the lock.
    private let encryptor = AudioEncryptor()
    private var encoder: OpusStreamEncoder?
    /// Sized for the largest frame either codec uses, so a codec change never reallocates.
    private var accumulator = [Float](repeating: 0, count: opusFrameSamplesPerChannel * channels)
    private var accumulatorWritten = 0
    /// int24-LE staging for one PCM frame (the plaintext that gets encrypted whole).
    private var pcmScratch = [UInt8](repeating: 0, count: pcmFrameSamplesPerChannel * channels * 3)
    private var audioSequence: UInt32 = 0
    private var formatSequence: UInt32 = 0
    private var pcmFrameId: UInt32 = 0
    private var streamId: UInt16 = 1
    private var lastFormatSent = Date.distantPast

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

    /// Switch the wire codec. Taking effect mid-stream rotates the stream identity, exactly
    /// like the Windows sender's `OnCodecChanged`: a receiver keys its session on
    /// (endpoint, streamId) and the format it opened with, so changing the codec under the
    /// same id would be a format change inside a live session. A fresh id opens a fresh one.
    public func setCodec(_ newCodec: AudioTransportCodec) {
        lock.lock()
        defer { lock.unlock() }
        guard newCodec != codec else { return }
        codec = newCodec
        guard running else { return }
        running = beginStream()
    }

    /// How long audio waits in our capture device before it reaches the wire, as the device
    /// reports it (0 = nothing open, or it would not say). Announced in every format packet
    /// so the peer can report the real journey instead of guessing at our capture stage.
    public func setCaptureLatencyMs(_ value: Double) {
        lock.lock()
        captureLatencyMs = value
        lock.unlock()
    }

    /// Begin a fresh outbound stream: new random streamId (receivers key sessions on it),
    /// counters reset, immediate format announce on the next submitted buffer.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = beginStream()
    }

    public func stop() {
        lock.lock()
        running = false
        encoder = nil
        accumulatorWritten = 0
        lock.unlock()
    }

    /// Fresh stream identity and counters for the current codec. False when the codec needs
    /// an encoder and libopus would not give us one — nothing can be sent in that state.
    /// Lock held by the caller.
    private func beginStream() -> Bool {
        encoder = codec == .opus
            ? OpusStreamEncoder(frameSizePerChannel: Self.opusFrameSamplesPerChannel)
            : nil
        streamId = UInt16.random(in: 1..<UInt16.max)
        audioSequence = 0
        formatSequence = 0
        pcmFrameId = 0
        accumulatorWritten = 0
        lastFormatSent = .distantPast
        return codec != .opus || encoder != nil
    }

    // MARK: - Hot path (capture thread)

    /// Feed 48 kHz interleaved stereo float. `frameCount` is sample frames (L+R pairs).
    public func submit(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard running, audioKey != nil, !targets.isEmpty else { return }
        encryptor.ensureKey(audioKey)
        guard encryptor.hasKey else { return }

        sendFormatIfDue()

        let frameFloats = currentFrameFloats
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
                emitFrame(frameFloats: frameFloats)
                accumulatorWritten = 0
            }
        }
    }

    /// Interleaved floats in one frame of the current codec. Lock held by the caller.
    private var currentFrameFloats: Int {
        switch codec {
        case .opus:
            return (encoder?.frameSizePerChannel ?? Self.opusFrameSamplesPerChannel) * Self.channels
        case .pcm:
            return Self.pcmFrameSamplesPerChannel * Self.channels
        }
    }

    private func emitFrame(frameFloats: Int) {
        switch codec {
        case .opus: emitOpusFrame()
        case .pcm: emitPcmFrame(frameFloats: frameFloats)
        }
    }

    private func emitOpusFrame() {
        guard let encoder else { return }
        let encoded = accumulator.withUnsafeBufferPointer { acc in
            encoder.encode(acc.baseAddress!)
        }
        guard let encoded, let ciphertext = encryptor.tryEncrypt(encoded) else { return }
        audioSequence &+= 1
        var packet = RemPacket.writeHeader(type: .audio, streamId: streamId, sequence: audioSequence)
        packet.append(contentsOf: ciphertext)
        sendToAll([UInt8](packet))
    }

    /// Pack, encrypt the WHOLE frame, then split the ciphertext across as many parts as the
    /// datagram budget needs — the receiver reassembles the parts and decrypts after, so the
    /// split can never be done per part. At 2.5 ms frames there is exactly one part; the
    /// generic split stays because the frame size is a constant we may want to move.
    private func emitPcmFrame(frameFloats: Int) {
        accumulator.withUnsafeBufferPointer { acc in
            PcmPack.floatToInt24LE(acc.baseAddress!, count: frameFloats, into: &pcmScratch)
        }
        guard let ciphertext = encryptor.tryEncrypt(pcmScratch[0..<(frameFloats * 3)]) else { return }

        let maxPart = RemPacket.maxAudioPayloadBytes
        let totalParts = (ciphertext.count + maxPart - 1) / maxPart
        guard totalParts > 0, totalParts <= Int(UInt8.max) else { return }
        pcmFrameId &+= 1
        for part in 0..<totalParts {
            let offset = part * maxPart
            let end = min(offset + maxPart, ciphertext.count)
            // Every part carries its own audio sequence, like the Windows sender — the
            // receiver's loss and reorder counters work on packets, not frames.
            audioSequence &+= 1
            var packet = RemPacket.writeHeader(type: .audio, streamId: streamId, sequence: audioSequence)
            packet.append(RemPcmFrame.writeSubHeader(
                frameId: pcmFrameId, partIndex: UInt8(part), totalParts: UInt8(totalParts)))
            packet.append(contentsOf: ciphertext[offset..<end])
            sendToAll([UInt8](packet))
        }
    }

    private func sendFormatIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastFormatSent) >= Self.formatResendInterval else { return }
        lastFormatSent = now

        // The same field values the Windows sender announces for each codec. For Opus,
        // bits/blockAlign describe the pre-encode PCM; receivers key the session off
        // codec + rate + frame size either way.
        let format: AudioFormatInfo
        switch codec {
        case .opus:
            format = AudioFormatInfo(
                sampleRate: Self.sampleRate,
                channels: Self.channels,
                bitsPerSample: 16,
                encoding: 1,
                blockAlign: 4,
                averageBytesPerSecond: OpusStreamEncoder.bitrate,
                codec: .opus,
                frameSamplesPerChannel: encoder?.frameSizePerChannel ?? Self.opusFrameSamplesPerChannel,
                lane: .mixed)
        case .pcm:
            format = AudioFormatInfo(
                sampleRate: Self.sampleRate,
                channels: Self.channels,
                bitsPerSample: 24,
                encoding: 1,
                blockAlign: 6,
                averageBytesPerSecond: Self.sampleRate * 6,
                codec: .pcm,
                frameSamplesPerChannel: Self.pcmFrameSamplesPerChannel,
                lane: .mixed)
        }
        formatSequence &+= 1
        var packet = RemPacket.writeHeader(type: .format, streamId: streamId, sequence: formatSequence)
        packet.append(RemPacket.writeFormatPayload(
            format, passwordFingerprint: audioFingerprint, captureLatencyMs: captureLatencyMs))
        sendToAll([UInt8](packet))
    }

    private func sendToAll(_ packet: [UInt8]) {
        guard let transport else { return }
        for target in targets {
            _ = transport(packet, target)
        }
    }
}
