import AVFAudio
import Foundation
import os
#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
#endif

/// One selectable audio input. On iOS an entry is either an input port (AirPods, wired
/// headset) or one data source of the built-in mic (bottom, front, back); on macOS it is a
/// Core Audio input device (built-in mic, interface line-in, virtual devices like Loopback).
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Captures from the selected microphone/input device and delivers 48 kHz interleaved
/// stereo float to `onSamples` (called on the dedicated drain thread). Sample-rate and
/// channel conversion happen here, so the send engine only ever sees the wire mix format.
///
/// Capture topology: realtime callback (hardware quanta ~5 ms) → lock-free
/// `CaptureRingBuffer` → drain thread (converts and forwards in 10 ms units). The callback
/// is an `AVAudioSinkNode` on iOS and an input-only AUHAL (`CoreAudioInputUnit`) on macOS —
/// AVAudioEngine cannot select an input device there without moving its output binding too.
/// NOT `installTap` — iOS clamps tap buffers to ~100 ms regardless of the requested size,
/// which made outbound Opus packets leave in ten-packet bursts every 100 ms and forced the
/// Windows receiver up to a ~200 ms jitter buffer. The sink block runs realtime: it may
/// only copy into the ring and signal; conversion/encode/encrypt/send stay on the drain
/// thread, so `AudioEncryptor`'s capture-thread-only contract still holds (one thread).
///
/// iOS: the audio session category must already allow recording (`AudioOutput.setRecordingMode`)
/// before `start()`. Input selection goes through `AVAudioSession.setPreferredInput` /
/// `setPreferredDataSource`. macOS: the device is bound on our own input-only AUHAL.
public final class MicrophoneCapture {
    /// 48 kHz interleaved stereo float; second parameter is the sample-frame count.
    public var onSamples: ((UnsafePointer<Float>, Int) -> Void)?
    public var onDiagnostic: ((String) -> Void)?
    /// Fires on the main queue when the set of selectable inputs may have changed (device
    /// plug/unplug, route change). Enumerating inputs goes through the audio server, so
    /// callers must refresh on this signal instead of polling `availableInputs()` on a
    /// timer — per-second hardware polling runs IPC alongside live playback.
    public var onInputsChanged: (() -> Void)?

    public private(set) var isRunning = false

#if os(iOS)
    private var engine: AVAudioEngine?
    private var sinkNode: AVAudioSinkNode?
#else
    /// macOS captures through an input-only AUHAL instead of AVAudioEngine — see
    /// `CoreAudioInputUnit` for why the engine cannot be used to pick an input device here.
    private var inputUnit: CoreAudioInputUnit?
#endif
    private var converter: AVAudioConverter?
    private var convertedBuffer: AVAudioPCMBuffer?
    private var ringBuffer: CaptureRingBuffer?
    /// Hardware-rate staging buffer the drain thread refills from the ring (one 10 ms
    /// quantum); also the converter's input. Drain-thread only while running.
    private var hardwareInputBuffer: AVAudioPCMBuffer?
    private var drainQuantumFrames = 0
    private var hardwareSampleRate: Double = 0
    private var drainThread: Thread?
    private var drainSemaphore = DispatchSemaphore(value: 0)
    private var drainExitedSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = OSAllocatedUnfairLock()
    private var drainShouldStop = false
    /// Mono→stereo duplication scratch (mono mics must reach both wire channels).
    /// (`MicrophoneCapture.` spelled out: `Self` is not allowed in a class's stored
    /// property initializer.)
    private var stereoScratch = [Float](repeating: 0, count: MicrophoneCapture.maxConvertedFrames * 2)
    private var preferredInputId: String?
    private var configChangeObserver: NSObjectProtocol?
    private var inputsChangedObserver: NSObjectProtocol?
#if os(macOS)
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private static let devicesListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
#endif

    private static let wireSampleRate = 48_000.0
    private static let maxConvertedFrames = 9600 // 200 ms at 48 kHz — far above one drain quantum

    public init() {
#if os(iOS)
        // Inputs appear/disappear only with a route change (plug/unplug, Bluetooth,
        // category switch), so that notification is the complete refresh signal.
        inputsChangedObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onInputsChanged?()
        }
#else
        // The HAL's device-list property covers attach/detach of every input device,
        // including virtual ones (Loopback/BlackHole) being created.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onInputsChanged?()
        }
        devicesListenerBlock = listener
        var address = Self.devicesListAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
#endif
    }

    deinit {
        if let inputsChangedObserver {
            NotificationCenter.default.removeObserver(inputsChangedObserver)
        }
#if os(macOS)
        if let devicesListenerBlock {
            var address = Self.devicesListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, devicesListenerBlock)
        }
#endif
    }

    // MARK: - Permission

    /// Ask for microphone access. Completion fires on an arbitrary queue.
    public static func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
#if os(iOS)
        AVAudioApplication.requestRecordPermission(completionHandler: completion)
#else
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
#endif
    }

    // MARK: - Input enumeration / selection

    public func availableInputs() -> [AudioInputDevice] {
#if os(iOS)
        var result: [AudioInputDevice] = []
        for port in AVAudioSession.sharedInstance().availableInputs ?? [] {
            let sources = port.dataSources ?? []
            if sources.count > 1 {
                // Built-in mic exposes its positions (bottom, front, back) as data sources.
                for source in sources {
                    result.append(AudioInputDevice(
                        id: "ds|\(port.uid)|\(source.dataSourceID)",
                        name: "\(port.portName) — \(source.dataSourceName)"))
                }
            } else {
                result.append(AudioInputDevice(id: "port|\(port.uid)", name: port.portName))
            }
        }
        return result
#else
        return Self.coreAudioInputDevices().map { AudioInputDevice(id: "dev|\($0.uid)", name: $0.name) }
#endif
    }

    /// Remember the input to capture from; nil = system default. Takes effect on the next
    /// `start()` — the controller restarts capture on a selection change.
    public func setPreferredInput(id: String?) {
        preferredInputId = id
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRunning else { return }

        applyPreferredInputPreStart()

        // The capture SOURCE differs per platform (AVAudioEngine on iOS, an input-only AUHAL
        // on macOS); everything downstream of the ring is shared.
#if os(iOS)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        let hwSampleRate = hardwareFormat.sampleRate
        let hwChannels = Int(hardwareFormat.channelCount)
#else
        let unit = try CoreAudioInputUnit(deviceId: preferredDeviceId())
        let hwSampleRate = unit.sampleRate
        let hwChannels = unit.channelCount
#endif
        guard hwSampleRate > 0, hwChannels > 0 else {
            throw NSError(domain: "RemSound", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input is available"])
        }

        // Converter target: wire rate, float32, interleaved. Mono stays mono through the
        // converter and is duplicated into both wire channels below — relying on the
        // converter's default 1→2 channel mapping risks left-only audio.
        //
        // Converter SOURCE is the ring's layout: interleaved hardware-rate float (mono
        // keeps the single-plane layout, which is byte-identical). AVAudioConverter is
        // fine with interleaved formats — pitfall 1 applies to engine node connections.
        let targetChannels: AVAudioChannelCount = hwChannels == 1 ? 1 : 2
        let quantumFrames = max(Int(hwSampleRate / 100), 120) // 10 ms of hw audio
        guard
            let stagingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: hwSampleRate,
                channels: AVAudioChannelCount(hwChannels), interleaved: hwChannels > 1),
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.wireSampleRate,
                channels: targetChannels, interleaved: true),
            let converter = AVAudioConverter(from: stagingFormat, to: targetFormat),
            let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Self.maxConvertedFrames)),
            let staging = AVAudioPCMBuffer(
                pcmFormat: stagingFormat, frameCapacity: AVAudioFrameCount(quantumFrames))
        else {
            throw NSError(domain: "RemSound", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not prepare the microphone format converter"])
        }
        self.converter = converter
        convertedBuffer = converted
        hardwareInputBuffer = staging
        drainQuantumFrames = quantumFrames
        hardwareSampleRate = hwSampleRate

        // The realtime capture block may only copy + signal — no locks, no allocation, no
        // self capture. Everything heavier happens on the drain thread.
        let ring = CaptureRingBuffer(
            capacityFrames: Int(hwSampleRate * 0.4), channels: hwChannels)
        let wakeups = DispatchSemaphore(value: 0)
#if os(iOS)
        let sink = AVAudioSinkNode { _, frameCount, audioBufferList in
            ring.write(bufferList: audioBufferList, frames: Int(frameCount))
            wakeups.signal()
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: hardwareFormat)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.detach(sink)
            self.converter = nil
            convertedBuffer = nil
            hardwareInputBuffer = nil
            throw error
        }
        self.engine = engine
        sinkNode = sink
#else
        unit.onAudio = { bufferList, frames in
            ring.write(bufferList: bufferList, frames: frames)
            wakeups.signal()
        }
        // The AUHAL equivalent of .AVAudioEngineConfigurationChange: the bound device changed
        // rate, or the default input moved under a "Default" selection. Either way the
        // converter and ring are sized to the old format — rebuild.
        unit.onDeviceChanged = { [weak self] in
            guard let self, self.isRunning else { return }
            self.onDiagnostic?("microphone configuration changed — restarting capture")
            self.stop()
            try? self.start()
        }
        do {
            try unit.start()
        } catch {
            self.converter = nil
            convertedBuffer = nil
            hardwareInputBuffer = nil
            throw error
        }
        inputUnit = unit
#endif
        ringBuffer = ring
        drainSemaphore = wakeups
        isRunning = true

        stateLock.lock()
        drainShouldStop = false
        stateLock.unlock()
        let exited = DispatchSemaphore(value: 0)
        drainExitedSemaphore = exited
        let thread = Thread { [self] in
            drainLoop(ring: ring, wakeups: wakeups, exited: exited)
        }
        thread.name = "RemSound.MicDrain"
        thread.qualityOfService = .userInteractive
        thread.start()
        drainThread = thread

#if os(iOS)
        // Route/format changes (AirPods picked up, device unplugged) invalidate the sink
        // connection format and converter — rebuild the capture graph. (macOS gets the
        // equivalent from `CoreAudioInputUnit.onDeviceChanged`, wired above.)
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.onDiagnostic?("microphone configuration changed — restarting capture")
            self.stop()
            try? self.start()
        }
#endif

        onDiagnostic?("microphone capture started: \(Int(hwSampleRate)) Hz, "
            + "\(hwChannels) channel(s)")
    }

    public func stop() {
        guard isRunning else { return }
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
#if os(iOS)
        engine?.stop()
        if let sinkNode { engine?.detach(sinkNode) }
        sinkNode = nil
#else
        // Drop the rebuild callback before stopping: stop() is itself called from it.
        inputUnit?.onDeviceChanged = nil
        inputUnit?.stop()
#endif
        // The render block no longer fires; flag + wake + join the drain thread BEFORE
        // tearing down the converter state it reads. The join is fast (the loop checks
        // the flag right after every wait/timeout) and keeps the config-change
        // stop-then-start rebuild deterministic.
        stateLock.lock()
        drainShouldStop = true
        stateLock.unlock()
        drainSemaphore.signal()
        if drainThread != nil {
            drainExitedSemaphore.wait()
            drainThread = nil
        }
#if os(iOS)
        engine = nil
#else
        inputUnit = nil
#endif
        converter = nil
        convertedBuffer = nil
        hardwareInputBuffer = nil
        ringBuffer = nil
        isRunning = false
        onDiagnostic?("microphone capture stopped")
    }

    // MARK: - Capture diagnostics (plain atomic reads — safe on the 1 Hz status tick)

    /// Duration of the most recent capture callback's chunk in milliseconds (0 until the
    /// first callback). ~5 ms means healthy sink-node quanta; ~100 ms would mean tap-like
    /// chunking is back and outbound packets are leaving in bursts again.
    public var captureChunkMs: Double {
        guard hardwareSampleRate > 0, let ring = ringBuffer else { return 0 }
        return Double(ring.lastChunkFrames) * 1000 / hardwareSampleRate
    }

    /// Hardware frames discarded because the drain thread fell ~400 ms behind capture.
    public var captureDroppedFrames: Int { ringBuffer?.droppedFrames ?? 0 }

    // MARK: - Drain path (dedicated capture-side thread)

    private func drainLoop(ring: CaptureRingBuffer, wakeups: DispatchSemaphore, exited: DispatchSemaphore) {
        let quantum = drainQuantumFrames
        while true {
            _ = wakeups.wait(timeout: .now() + .milliseconds(250))
            stateLock.lock()
            let shouldStop = drainShouldStop
            stateLock.unlock()
            if shouldStop { break }
            while ring.availableFrames >= quantum {
                guard let staging = hardwareInputBuffer,
                      let data = staging.floatChannelData?[0],
                      ring.read(into: data, frames: quantum)
                else { break }
                staging.frameLength = AVAudioFrameCount(quantum)
                convertAndForward(staging)
            }
        }
        exited.signal()
    }

    /// One hardware-rate quantum → 48 kHz interleaved (mono duplicated) → `onSamples`.
    private func convertAndForward(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let converted = convertedBuffer, let onSamples else { return }

        converted.frameLength = 0
        var fed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0,
              let data = converted.floatChannelData?[0] else { return }
        let frames = Int(converted.frameLength)

        if converted.format.channelCount == 2 {
            onSamples(data, frames)
        } else {
            // Mono: duplicate into both wire channels.
            let count = min(frames, Self.maxConvertedFrames)
            stereoScratch.withUnsafeMutableBufferPointer { scratch in
                for i in 0..<count {
                    scratch[i * 2] = data[i]
                    scratch[i * 2 + 1] = data[i]
                }
                onSamples(scratch.baseAddress!, count)
            }
        }
    }

    // MARK: - Platform input selection

    private func applyPreferredInputPreStart() {
#if os(iOS)
        guard let preferredInputId else { return }
        let session = AVAudioSession.sharedInstance()
        let parts = preferredInputId.split(separator: "|").map(String.init)
        guard parts.count >= 2, let port = (session.availableInputs ?? []).first(where: { $0.uid == parts[1] })
        else { return }
        try? session.setPreferredInput(port)
        if parts.count == 3, parts[0] == "ds",
           let source = (port.dataSources ?? []).first(where: { "\($0.dataSourceID)" == parts[2] }) {
            try? port.setPreferredDataSource(source)
        }
#endif
    }

#if os(macOS)
    private struct CoreAudioDevice {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// The Core Audio device to capture from, or nil for the system default input — which is
    /// also what an unplugged/renamed selection falls through to.
    ///
    /// This is the whole macOS device-selection surface now. It used to set
    /// `kAudioOutputUnitProperty_CurrentDevice` on AVAudioEngine's input node, which on macOS
    /// is the SAME I/O unit as its output node, so picking a mic moved the engine's output
    /// binding too — see `CoreAudioInputUnit` for the full story.
    private func preferredDeviceId() -> AudioDeviceID? {
        guard let preferredInputId else { return nil }
        let parts = preferredInputId.split(separator: "|").map(String.init)
        guard parts.count == 2, parts[0] == "dev" else { return nil }
        return Self.coreAudioInputDevices().first(where: { $0.uid == parts[1] })?.id
    }

    private static func coreAudioInputDevices() -> [CoreAudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr
        else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIds = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIds) == noErr
        else { return [] }

        var devices: [CoreAudioDevice] = []
        for id in deviceIds where inputChannelCount(of: id) > 0 {
            guard let uid = stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(of: id, selector: kAudioObjectPropertyName)
            else { continue }
            devices.append(CoreAudioDevice(id: id, uid: uid, name: name))
        }
        return devices
    }

    private static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }
        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, listPointer) == noErr
        else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(
            listPointer.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(of device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
#endif
}
