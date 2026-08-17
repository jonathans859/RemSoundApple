import Foundation

/// Per-sender decode pipeline, mirroring the Windows `StreamSession`: PCM frame assembly +
/// decrypt + int24→float, or Opus decrypt + decode with single-packet FEC recovery. All work
/// runs on the network receive thread; the only cross-thread interaction is writing decoded
/// floats into the `SessionPlayout`.
final class StreamSession {
    let endpoint: UDPEndpoint
    let streamId: UInt16
    let format: AudioFormatInfo
    let playout: SessionPlayout

    private let decryptor: AudioDecryptor
    private let pcmAssembler = PcmFrameAssembler()
    private var opusDecoder: OpusStreamDecoder?
    private var expectedNextSequence: UInt32?

    /// Packet-level telemetry sink (loss / reorder / arrival gaps / sender Opus mode).
    /// Measurement only — the decode path below behaves identically with or without it.
    private let diagnostics: StreamDiagnostics?
    private var arrivals = ArrivalTracker()

    // Reused scratch buffers — steady-state allocation-free decode path.
    private var floatScratch: [Float] = []
    private var stereoScratch: [Float] = []
    private var shortScratch: [Int16] = []
    private let resampler: LinearResampler?

    var lastWriteTime: Date { playout.lastWriteTime }

    init(endpoint: UDPEndpoint, streamId: UInt16, format: AudioFormatInfo, playout: SessionPlayout,
         decryptor: AudioDecryptor, diagnostics: StreamDiagnostics? = nil) {
        self.endpoint = endpoint
        self.streamId = streamId
        self.format = format
        self.playout = playout
        self.decryptor = decryptor
        self.diagnostics = diagnostics
        if format.codec == .opus {
            opusDecoder = OpusStreamDecoder(sampleRate: format.sampleRate, channels: format.channels)
        }
        // PCM passthrough mode on the Windows sender can put the capture device's native
        // rate on the wire (44.1 k etc.); Opus is always 48 k. Resample anything non-48k.
        resampler = format.sampleRate != SessionPlayout.mixSampleRate && format.sampleRate > 0
            ? LinearResampler(inputRate: format.sampleRate, outputRate: SessionPlayout.mixSampleRate)
            : nil
    }

    func matchesFormat(_ other: AudioFormatInfo) -> Bool {
        format.matchesIdentity(of: other)
    }

    /// Decode one audio payload and hand the result to playout. Malformed or undecryptable
    /// payloads are dropped silently — a wrong password is surfaced from the format-packet
    /// fingerprint, never as garbage audio.
    func handleAudioPayload(sequence: UInt32, payload: ArraySlice<UInt8>, kernelArrivalNs: UInt64 = 0) {
        if let diagnostics {
            arrivals.record(sequence: sequence, kernelArrivalNs: kernelArrivalNs, into: diagnostics)
        }
        switch format.codec {
        case .pcm: handlePcm(payload)
        case .opus: handleOpus(sequence: sequence, payload: payload)
        }
    }

    // MARK: - PCM

    private func handlePcm(_ payload: ArraySlice<UInt8>) {
        guard let sub = RemPcmFrame.readSubHeader(payload) else { return }
        let partStart = payload.startIndex + RemPcmFrame.subHeaderSize
        guard let assembled = pcmAssembler.assemble(
            part: payload[partStart...], frameId: sub.frameId, partIndex: sub.partIndex, totalParts: sub.totalParts)
        else {
            return // pending or dropped-by-policy — not an error
        }

        // The reassembled frame is ciphertext — decrypt, then unpack int24 LE to float.
        guard let plain = decryptor.tryDecrypt(assembled[...]) else {
            diagnostics?.recordDecryptFailure()
            return
        }

        let sampleCount = plain.count / 3
        guard sampleCount > 0 else { return }
        PcmPack.int24LEToFloat(plain[...], into: &floatScratch)
        emit(samples: floatScratch, sampleCount: sampleCount)
    }

    // MARK: - Opus

    private func handleOpus(sequence: UInt32, payload: ArraySlice<UInt8>) {
        guard let opusDecoder else { return }
        guard let plain = decryptor.tryDecrypt(payload) else {
            diagnostics?.recordDecryptFailure()
            return
        }
        // First plaintext byte is the Opus TOC — tells us which internal mode the sender's
        // encoder actually chose, and therefore whether inband FEC can exist at all.
        if let first = plain.first { diagnostics?.recordOpusTOC(first) }

        // Floor at 120 samples = 2.5 ms, libopus's RESTRICTED_LOWDELAY minimum, so a
        // malformed format packet can't undersize the decode buffer.
        let frameSize = max(120, format.frameSamplesPerChannel)

        // Single-packet gap: this packet carries FEC redundancy for the one we missed.
        // Decode the FEC frame first (so audio stays in order), then the current frame.
        let useFec = expectedNextSequence.map { sequence &- $0 == 1 } ?? false // uint wrap intentional
        if useFec, let fecCount = opusDecoder.decode(plain, frameSize: frameSize, fec: true, into: &shortScratch) {
            emitShorts(count: fecCount)
        }

        guard let decoded = opusDecoder.decode(plain, frameSize: frameSize, fec: false, into: &shortScratch) else {
            return
        }
        emitShorts(count: decoded)
        expectedNextSequence = sequence &+ 1
    }

    private func emitShorts(count samplesPerChannel: Int) {
        let total = samplesPerChannel * format.channels
        if floatScratch.count < total {
            floatScratch = [Float](repeating: 0, count: total)
        }
        for i in 0..<total {
            floatScratch[i] = Float(shortScratch[i]) / 32768.0
        }
        emit(samples: floatScratch, sampleCount: total)
    }

    /// Common tail: up/down-mix to stereo, resample to 48 k if needed, hand to playout.
    private func emit(samples: [Float], sampleCount: Int) {
        var stereo = samples
        var frames = sampleCount / max(1, format.channels)

        switch format.channels {
        case 2:
            break
        case 1:
            if stereoScratch.count < sampleCount * 2 {
                stereoScratch = [Float](repeating: 0, count: sampleCount * 2)
            }
            for i in 0..<sampleCount {
                stereoScratch[i * 2] = samples[i]
                stereoScratch[i * 2 + 1] = samples[i]
            }
            stereo = stereoScratch
            frames = sampleCount
        default:
            return // wire protocol is mono/stereo only — anything else is malformed
        }

        if let resampler {
            let outFrames = resampler.process(input: stereo, inputFrames: frames, output: &stereoScratch)
            playout.write(stereoScratch, frames: outFrames)
        } else {
            playout.write(stereo, frames: frames)
        }
    }
}

/// Stateful linear-interpolation stereo resampler for the (uncommon) PCM-passthrough case
/// where the wire rate isn't 48 kHz. Linear is audibly adequate for v1; the Windows receiver
/// uses a WDL resampler here, and this can be upgraded if a non-48k sender is in regular use.
final class LinearResampler {
    private let ratio: Double // input frames consumed per output frame
    private var position: Double = 0
    private var prevL: Float = 0
    private var prevR: Float = 0
    private var primed = false

    init(inputRate: Int, outputRate: Int) {
        ratio = Double(inputRate) / Double(outputRate)
    }

    /// Returns the number of output frames written. Output is interleaved stereo; the buffer
    /// is grown when needed.
    func process(input: [Float], inputFrames: Int, output: inout [Float]) -> Int {
        if inputFrames <= 0 { return 0 }
        let maxOut = Int(Double(inputFrames + 2) / ratio) + 2
        if output.count < maxOut * 2 {
            output = [Float](repeating: 0, count: maxOut * 2)
        }
        if !primed {
            prevL = input[0]
            prevR = input[1]
            primed = true
        }

        var out = 0
        // `position` is the fractional read cursor in input frames, where -1 refers to the
        // carried-over previous frame.
        while true {
            let idx = Int(floor(position))
            if idx >= inputFrames - 1 {
                // Need the next packet; carry the last frame and rebase the cursor.
                position -= Double(inputFrames)
                prevL = input[(inputFrames - 1) * 2]
                prevR = input[(inputFrames - 1) * 2 + 1]
                break
            }
            let frac = Float(position - Double(idx))
            let l0: Float, r0: Float
            if idx < 0 {
                l0 = prevL
                r0 = prevR
            } else {
                l0 = input[idx * 2]
                r0 = input[idx * 2 + 1]
            }
            let l1 = input[(idx + 1) * 2]
            let r1 = input[(idx + 1) * 2 + 1]
            output[out * 2] = l0 + (l1 - l0) * frac
            output[out * 2 + 1] = r0 + (r1 - r0) * frac
            out += 1
            position += ratio
        }
        return out
    }
}
