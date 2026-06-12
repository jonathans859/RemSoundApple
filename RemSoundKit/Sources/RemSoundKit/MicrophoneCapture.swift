import AVFAudio
import Foundation
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
/// stereo float to `onSamples` (called on the capture tap thread). Sample-rate and channel
/// conversion happen here, so the send engine only ever sees the wire mix format.
///
/// iOS: the audio session category must already allow recording (`AudioOutput.setRecordingMode`)
/// before `start()`. Input selection goes through `AVAudioSession.setPreferredInput` /
/// `setPreferredDataSource`. macOS: the device is set directly on the input unit.
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

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var convertedBuffer: AVAudioPCMBuffer?
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
    private static let maxConvertedFrames = 9600 // 200 ms at 48 kHz — far above any tap buffer

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

        let engine = AVAudioEngine()
        let input = engine.inputNode
#if os(macOS)
        try applyPreferredDevice(to: input)
#endif

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw NSError(domain: "RemSound", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input is available"])
        }

        // Converter target: wire rate, float32, interleaved. Mono stays mono through the
        // converter and is duplicated into both wire channels below — relying on the
        // converter's default 1→2 channel mapping risks left-only audio.
        let targetChannels: AVAudioChannelCount = hardwareFormat.channelCount == 1 ? 1 : 2
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.wireSampleRate,
                channels: targetChannels, interleaved: true),
            let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat),
            let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Self.maxConvertedFrames))
        else {
            throw NSError(domain: "RemSound", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not prepare the microphone format converter"])
        }
        self.converter = converter
        convertedBuffer = converted

        input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            convertedBuffer = nil
            throw error
        }
        self.engine = engine
        isRunning = true

        // Route/format changes (AirPods picked up, device unplugged) invalidate the tap
        // format and converter — rebuild the capture graph.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.onDiagnostic?("microphone configuration changed — restarting capture")
            self.stop()
            try? self.start()
        }

        onDiagnostic?("microphone capture started: \(Int(hardwareFormat.sampleRate)) Hz, "
            + "\(hardwareFormat.channelCount) channel(s)")
    }

    public func stop() {
        guard isRunning else { return }
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        convertedBuffer = nil
        isRunning = false
        onDiagnostic?("microphone capture stopped")
    }

    // MARK: - Tap path (capture thread)

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
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

    private func applyPreferredDevice(to input: AVAudioInputNode) throws {
        guard let preferredInputId else { return }
        let parts = preferredInputId.split(separator: "|").map(String.init)
        guard parts.count == 2, parts[0] == "dev",
              let device = Self.coreAudioInputDevices().first(where: { $0.uid == parts[1] }),
              let unit = input.audioUnit
        else { return } // device unplugged → fall through to the system default input
        var deviceId = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceId, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not select the input device \(device.name)"])
        }
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
