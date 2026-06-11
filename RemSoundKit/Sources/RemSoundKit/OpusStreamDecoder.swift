import Copus
import Foundation

/// Thin wrapper over the libopus C decoder. We need the raw C API (not an AVAudioConverter)
/// because the receive path uses `opus_decode`'s `decode_fec` flag to recover single-packet
/// gaps from the next packet's inband redundancy — same as the Windows receiver.
final class OpusStreamDecoder {
    private var decoder: OpaquePointer?
    let sampleRate: Int
    let channels: Int

    init?(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        var error: Int32 = 0
        decoder = opus_decoder_create(Int32(sampleRate), Int32(channels), &error)
        if error != OPUS_OK || decoder == nil { return nil }
    }

    deinit {
        if let decoder { opus_decoder_destroy(decoder) }
    }

    /// Decode one packet into interleaved int16 samples. `frameSize` is samples per channel.
    /// `fec` true decodes the redundancy for the PREVIOUS (lost) packet instead of this one.
    /// Returns the decoded samples-per-channel count, or nil on decode failure.
    func decode(_ packet: [UInt8], frameSize: Int, fec: Bool, into output: inout [Int16]) -> Int? {
        guard let decoder else { return nil }
        let needed = frameSize * channels
        if output.count < needed {
            output = [Int16](repeating: 0, count: needed)
        }
        let decoded = packet.withUnsafeBufferPointer { data in
            output.withUnsafeMutableBufferPointer { pcm in
                // pcm.baseAddress is non-nil: output was sized to `needed` (>= 120 * channels)
                // above. opus_decode's output parameter is imported non-optional.
                opus_decode(decoder, data.baseAddress, opus_int32(packet.count), pcm.baseAddress!, Int32(frameSize), fec ? 1 : 0)
            }
        }
        return decoded > 0 ? Int(decoded) : nil
    }
}
