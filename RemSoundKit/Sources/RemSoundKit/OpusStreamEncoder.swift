import Foundation
import RemOpusShim

/// Thin wrapper over the libopus C encoder, configured exactly like the Windows sender's
/// `OpusEncoderState`: 48 kHz stereo, RESTRICTED_LOWDELAY, 192 kbps VBR, complexity 10,
/// inband FEC with a 10 % packet-loss bias. Goes through `RemOpusShim` because
/// `opus_encoder_ctl` is C-variadic and not callable from Swift.
final class OpusStreamEncoder {
    static let sampleRate = 48_000
    static let channels = 2
    static let bitrate = 192_000

    private var encoder: OpaquePointer?
    private var packetScratch = [UInt8](repeating: 0, count: 4000)

    /// Samples per channel per frame (480 = 10 ms at 48 kHz, the Windows default).
    let frameSizePerChannel: Int

    init?(frameSizePerChannel: Int = 480) {
        self.frameSizePerChannel = frameSizePerChannel
        var error: Int32 = 0
        encoder = rem_opus_encoder_create(Int32(Self.sampleRate), Int32(Self.channels), &error)
        guard let encoder, error == 0 else { return nil }
        let status = rem_opus_encoder_configure(
            encoder, Int32(Self.bitrate), 10 /* complexity */, 1 /* VBR */,
            1 /* inband FEC */, 10 /* packet loss % */)
        if status != 0 {
            rem_opus_encoder_destroy(encoder)
            self.encoder = nil
            return nil
        }
    }

    deinit {
        if let encoder { rem_opus_encoder_destroy(encoder) }
    }

    /// Encode one frame of interleaved stereo float (`frameSizePerChannel * 2` samples).
    /// Returns the encoded bytes (valid until the next encode call), or nil on failure.
    func encode(_ interleaved: UnsafePointer<Float>) -> ArraySlice<UInt8>? {
        guard let encoder else { return nil }
        let written = packetScratch.withUnsafeMutableBufferPointer { out in
            rem_opus_encode_float(
                encoder, interleaved, Int32(frameSizePerChannel),
                out.baseAddress!, Int32(out.count))
        }
        guard written > 0 else { return nil }
        return packetScratch[0..<Int(written)]
    }
}
