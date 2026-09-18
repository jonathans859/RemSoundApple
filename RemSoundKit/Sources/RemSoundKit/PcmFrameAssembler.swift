import Foundation

/// Assembles multi-part PCM transport frames back into a single contiguous payload.
/// Direct port of the Windows `PcmFrameAssembler`: parts must arrive in order; a missed part
/// drops the whole frame rather than waiting (at 10 ms cadence, waiting is worse than one
/// dropped frame).
public final class PcmFrameAssembler {
    private var pendingFrameId: UInt32 = 0
    private var pendingPartIndex: UInt8 = 0 // index of the NEXT expected part
    private var pendingTotalParts: UInt8 = 0
    private var assemblyBuffer = [UInt8](repeating: 0, count: 8192)
    private var assemblyWritten = 0

    public private(set) var rejectionCount: Int64 = 0
    public private(set) var discardedPartialCount: Int64 = 0

    public init() {}

    /// Feed one part. Returns the completed frame's bytes when the last part lands, nil while
    /// pending or when the frame was dropped (drops are counted, not errors).
    public func assemble(part: ArraySlice<UInt8>, frameId: UInt32, partIndex: UInt8, totalParts: UInt8) -> [UInt8]? {
        if totalParts == 0 {
            rejectionCount += 1
            return nil
        }

        if partIndex == 0 {
            // New frame starts — if a partial was waiting, its audio is lost.
            if pendingTotalParts != 0 && assemblyWritten > 0 {
                discardedPartialCount += 1
            }
            pendingFrameId = frameId
            pendingPartIndex = 0
            pendingTotalParts = totalParts
            assemblyWritten = 0
        } else if frameId != pendingFrameId || partIndex != pendingPartIndex || totalParts != pendingTotalParts {
            // We missed the start, or this belongs to a different frame. Discard.
            assemblyWritten = 0
            pendingTotalParts = 0
            rejectionCount += 1
            return nil
        }

        if assemblyWritten + part.count > assemblyBuffer.count {
            assemblyWritten = 0
            pendingTotalParts = 0
            rejectionCount += 1
            return nil
        }

        assemblyBuffer.replaceSubrange(assemblyWritten..<(assemblyWritten + part.count), with: part)
        assemblyWritten += part.count
        pendingPartIndex += 1

        if pendingPartIndex == pendingTotalParts {
            let frame = Array(assemblyBuffer[0..<assemblyWritten])
            pendingTotalParts = 0
            assemblyWritten = 0
            return frame
        }
        return nil
    }
}

/// Float ↔ packed signed 24-bit little-endian PCM (the PCM wire format).
/// Mirrors `RemSound.Core.PcmPack`.
public enum PcmPack {
    /// Pack floats in [-1, +1] into signed 24-bit little-endian, 3 bytes per sample.
    /// `destination` must hold at least `source.count * 3` bytes; it is written in place so
    /// the send path can reuse one scratch buffer per frame.
    ///
    /// Scaling and truncation match the Windows sender exactly (clamp, × (2^23 - 1),
    /// truncate toward zero) — the same bytes must come out of both implementations for a
    /// given frame, because a receiver cannot tell which one sent it.
    public static func floatToInt24LE(_ source: UnsafePointer<Float>, count: Int, into destination: inout [UInt8]) {
        let needed = count * 3
        if destination.count < needed {
            destination = [UInt8](repeating: 0, count: needed)
        }
        destination.withUnsafeMutableBufferPointer { dst in
            var j = 0
            for i in 0..<count {
                // NaN would trap the Int32 conversion — a crash in the capture thread over
                // one bad sample. Treat it as silence, the way the C# cast does.
                let value = source[i]
                let clamped = value.isNaN ? 0 : min(max(value, -1), 1)
                let sample = Int32(clamped * 8_388_607)
                dst[j] = UInt8(truncatingIfNeeded: sample)
                dst[j + 1] = UInt8(truncatingIfNeeded: sample >> 8)
                dst[j + 2] = UInt8(truncatingIfNeeded: sample >> 16)
                j += 3
            }
        }
    }

    public static func int24LEToFloat(_ source: ArraySlice<UInt8>, into destination: inout [Float]) {
        let src = Array(source)
        let sampleCount = src.count / 3
        if destination.count < sampleCount {
            destination = [Float](repeating: 0, count: sampleCount)
        }
        var j = 0
        for i in 0..<sampleCount {
            let packed = Int32(src[j]) | Int32(src[j + 1]) << 8 | Int32(src[j + 2]) << 16
            // Sign-extend from bit 23.
            let signed = (packed << 8) >> 8
            destination[i] = Float(signed) / 8_388_607.0
            j += 3
        }
    }
}
