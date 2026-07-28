#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

/// Input-only Core Audio (AUHAL) capture unit — the macOS half of `MicrophoneCapture`.
///
/// **Why not AVAudioEngine.** On macOS one `AVAudioEngine` has a SINGLE HAL I/O unit shared
/// by its input and output nodes, and `kAudioOutputUnitProperty_CurrentDevice` is a property
/// of that unit, not of one direction. Selecting an input device through the engine therefore
/// drags the engine's OUTPUT element onto the same device — and a built-in mic is a separate
/// HAL device with no output streams at all. In practice that released the previous output
/// binding mid-transition; with a Bluetooth headset on the other end of it, picking the
/// built-in mic in RemSound killed the headset's audio until it was reconnected
/// (user-reported, 2026-07-28).
///
/// Here element 0 (output) is explicitly disabled before the device is set, so the device
/// selection can only ever affect capture. Everything downstream is unchanged: the render
/// callback hands `CaptureRingBuffer` the same deinterleaved float planes `AVAudioSinkNode`
/// did, and the drain thread converts to the wire format exactly as before.
///
/// Client format is float32 **non-interleaved** at the device's own rate — the canonical
/// Core Audio layout, and the multi-plane path `CaptureRingBuffer.write(bufferList:frames:)`
/// already handles. Rate conversion stays with the existing `AVAudioConverter`; asking the
/// AUHAL to resample as well would put two resamplers in series.
final class CoreAudioInputUnit {
    /// The bound device's own sample rate and channel count — known before `start()` so the
    /// caller can build its converter, exactly like `inputNode.outputFormat(forBus: 0)`.
    let sampleRate: Double
    let channelCount: Int

    /// Called on the realtime render thread with deinterleaved float planes. Set before
    /// `start()`; the render path may only copy and signal (no locks, no allocation).
    var onAudio: ((UnsafePointer<AudioBufferList>, Int) -> Void)?
    /// Called on the main queue when the bound device's format changed or the default input
    /// moved — the caller rebuilds capture (the converter is tied to the old rate).
    var onDeviceChanged: (() -> Void)?

    private let unit: AudioUnit
    private let deviceId: AudioDeviceID
    /// True when the caller asked for "system default" — only then does a default-input
    /// change concern us.
    private let followsDefaultDevice: Bool
    private var isStarted = false

    /// Pre-allocated render target: one plane per channel, plus the buffer list describing
    /// them. `AudioBufferList.allocate` reserves the list only, never the sample memory.
    private var bufferList: UnsafeMutableAudioBufferListPointer
    private var planes: [UnsafeMutablePointer<Float>] = []
    private let maxFrames: UInt32

    private var formatListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private static let maximumFramesPerSlice: UInt32 = 4096

    /// Configures and initialises the unit. `deviceId` nil = the current system default
    /// input, which is also resolved to a concrete device here so the format listener has
    /// something to attach to.
    init(deviceId requestedDeviceId: AudioDeviceID?) throws {
        followsDefaultDevice = requestedDeviceId == nil
        guard let resolvedDevice = requestedDeviceId ?? Self.defaultInputDevice() else {
            throw NSError(domain: "RemSound", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input is available"])
        }
        deviceId = resolvedDevice

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NSError(domain: "RemSound", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The system audio input component is unavailable"])
        }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), "create the input unit")
        guard let instance else {
            throw NSError(domain: "RemSound", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not create the input unit"])
        }
        // Everything up to the last stored-property assignment must clean the unit up itself:
        // a class initializer that throws before the object is fully initialised does NOT run
        // `deinit`, so an early failure here would leak the component instance.
        let configured: (rate: Double, channels: Int, maxFrames: UInt32)
        do {
            configured = try Self.configure(unit: instance, device: resolvedDevice)
        } catch {
            AudioComponentInstanceDispose(instance)
            throw error
        }
        unit = instance
        sampleRate = configured.rate
        channelCount = configured.channels
        maxFrames = configured.maxFrames

        bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
        for channel in 0..<channelCount {
            let plane = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFrames))
            plane.initialize(repeating: 0, count: Int(maxFrames))
            planes.append(plane)
            bufferList[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: maxFrames * 4,
                mData: UnsafeMutableRawPointer(plane))
        }

        // From here on the object is fully initialised, so `deinit` runs on a throw and does
        // the disposing. The callback needs `self`, which is exactly why it comes last.
        var callback = AURenderCallbackStruct(
            inputProc: remSoundInputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "install the capture callback")

        try Self.check(AudioUnitInitialize(unit), "initialise the input unit")
    }

    /// All the pre-`self` unit configuration, in the order the AUHAL requires: enable IO,
    /// bind the device, then negotiate formats. Returns the device's format for the caller's
    /// converter.
    private static func configure(
        unit: AudioUnit, device: AudioDeviceID
    ) throws -> (rate: Double, channels: Int, maxFrames: UInt32) {
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size)), "enable audio input")
        // THE point of this class — element 0 off means the device bound below can never
        // become an output binding.
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disable, UInt32(MemoryLayout<UInt32>.size)), "disable audio output on the input unit")

        var boundDevice = device
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &boundDevice, UInt32(MemoryLayout<AudioDeviceID>.size)), "select the input device")

        // The hardware's own format, read from the INPUT scope of element 1.
        var hardwareFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
            &hardwareFormat, &formatSize), "read the input device format")
        guard hardwareFormat.mSampleRate > 0, hardwareFormat.mChannelsPerFrame > 0 else {
            throw NSError(domain: "RemSound", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The input device reported no usable audio format"])
        }

        // What WE want handed to the render callback, on the OUTPUT scope of element 1: the
        // device's own rate (a second resampler here would fight the converter downstream),
        // float32, one plane per channel.
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: hardwareFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: hardwareFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0)
        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "set the capture format")

        var slice = maximumFramesPerSlice
        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &slice, UInt32(MemoryLayout<UInt32>.size)), "set the capture slice size")

        return (hardwareFormat.mSampleRate, Int(hardwareFormat.mChannelsPerFrame), slice)
    }

    deinit {
        stop()
        removeListeners()
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        for plane in planes { plane.deallocate() }
        free(bufferList.unsafeMutablePointer)
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isStarted else { return }
        try Self.check(AudioOutputUnitStart(unit), "start the input unit")
        isStarted = true
        installListeners()
    }

    func stop() {
        guard isStarted else { return }
        removeListeners()
        AudioOutputUnitStop(unit)
        isStarted = false
    }

    // MARK: - Realtime render

    /// Realtime thread. Pulls the captured frames into our planes and forwards them; the
    /// buffer list's sizes must be restored on every call because `AudioUnitRender` rewrites
    /// them to what it actually delivered.
    fileprivate func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard frames > 0, frames <= maxFrames else { return noErr }
        for channel in 0..<channelCount {
            bufferList[channel].mDataByteSize = frames * 4
            bufferList[channel].mData = UnsafeMutableRawPointer(planes[channel])
        }
        let status = AudioUnitRender(unit, actionFlags, timeStamp, bus, frames,
                                     bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }
        onAudio?(UnsafePointer(bufferList.unsafeMutablePointer), Int(frames))
        return noErr
    }

    // MARK: - Device change tracking

    /// AVAudioEngine used to post `.AVAudioEngineConfigurationChange` for these; owning the
    /// unit directly means owning the notifications too. Both fire on the main queue and ask
    /// the caller to rebuild — the converter and ring are sized to the old rate.
    private func installListeners() {
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let formatBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDeviceChanged?()
        }
        formatListener = formatBlock
        AudioObjectAddPropertyListenerBlock(deviceId, &rateAddress, DispatchQueue.main, formatBlock)

        guard followsDefaultDevice else { return }
        var defaultAddress = Self.defaultInputAddress
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDeviceChanged?()
        }
        defaultDeviceListener = defaultBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main, defaultBlock)
    }

    private func removeListeners() {
        if let formatListener {
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                deviceId, &rateAddress, DispatchQueue.main, formatListener)
            self.formatListener = nil
        }
        if let defaultDeviceListener {
            var defaultAddress = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main,
                defaultDeviceListener)
            self.defaultDeviceListener = nil
        }
    }

    // MARK: - Helpers

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = defaultInputAddress
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Could not \(what) (Core Audio error \(status))"])
    }
}

/// C callback — no captures allowed, so the instance travels in `inputProcRefCon`.
/// `takeUnretainedValue` keeps the realtime thread free of ARC traffic on the unit itself.
private func remSoundInputRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let unit = Unmanaged<CoreAudioInputUnit>.fromOpaque(inRefCon).takeUnretainedValue()
    return unit.render(
        actionFlags: ioActionFlags, timeStamp: inTimeStamp, bus: inBusNumber, frames: inNumberFrames)
}
#endif
