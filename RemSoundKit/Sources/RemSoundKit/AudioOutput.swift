import AVFAudio
import Foundation

/// Renders the mix bus through AVAudioEngine via an AVAudioSourceNode pulling 48 kHz
/// interleaved stereo float32 from the `PlayoutMixer`.
///
/// iOS specifics: configures an AVAudioSession with the `.playback` category (which, combined
/// with the `audio` background mode in the app's Info.plist, keeps audio running with the
/// screen locked or the app in the background) and asks for a short IO buffer for low output
/// latency. Interruptions (calls, Siri) and media-services resets restart the engine.
public final class AudioOutput {
    /// Upper bound on frames rendered per inner loop; the interleaved scratch is sized to
    /// this. IO buffers are far smaller (~256 frames at 5 ms), larger requests are chunked.
    private static let renderChunkFrames = 4096

    private let mixer: PlayoutMixer
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var renderScratch: UnsafeMutablePointer<Float>?
    private var observers: [NSObjectProtocol] = []

    public var onDiagnostic: ((String) -> Void)?
    public private(set) var isRunning = false

    /// Best-effort hardware output latency (device latency + IO buffer) in milliseconds,
    /// for the status panel. The jitter buffer is the dominant, user-tunable part of the
    /// end-to-end delay; this is the fixed tail after it.
    public var reportedOutputLatencyMs: Double {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return (session.outputLatency + session.ioBufferDuration) * 1000
#else
        return (engine?.outputNode.presentationLatency ?? 0) * 1000
#endif
    }

    public init(mixer: PlayoutMixer) {
        self.mixer = mixer
    }

    public func start() throws {
        guard !isRunning else { return }

#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        applySessionCategory()
        // 48 kHz to match the wire mix rate; ~5 ms IO buffer for low output latency. Both
        // are preferences — the OS may give us less aggressive values on some routes.
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        installSessionObservers()
#endif

        let engine = AVAudioEngine()
        // The connection format MUST be the deinterleaved "standard" layout — AVAudioEngine's
        // mixer nodes reject interleaved input with an unhandleable NSException at connect().
        // The mix bus is interleaved internally, so the render callback fills a pre-allocated
        // interleaved scratch and splits it into the channel planes, in bounded chunks so the
        // audio thread never allocates.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.renderChunkFrames * 2)
        renderScratch = scratch

        let source = AVAudioSourceNode(format: format) { [mixer] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let leftRaw = abl[0].mData, let rightRaw = abl[1].mData else { return noErr }
            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right = rightRaw.assumingMemoryBound(to: Float.self)

            var rendered = 0
            let total = Int(frameCount)
            while rendered < total {
                let chunk = min(Self.renderChunkFrames, total - rendered)
                mixer.render(into: scratch, frames: chunk)
                for i in 0..<chunk {
                    left[rendered + i] = scratch[i * 2]
                    right[rendered + i] = scratch[i * 2 + 1]
                }
                rendered += chunk
            }
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        self.engine = engine
        self.sourceNode = source
        isRunning = true
        onDiagnostic?("audio output started")
    }

    public func stop() {
        guard isRunning else { return }
        engine?.stop()
        if let source = sourceNode { engine?.detach(source) }
        engine = nil
        sourceNode = nil
        // Free the render scratch only after the engine is stopped and the source node
        // detached — the render callback captured this pointer.
        renderScratch?.deallocate()
        renderScratch = nil
        isRunning = false
#if os(iOS)
        removeSessionObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
        onDiagnostic?("audio output stopped")
    }

#if os(iOS)
    /// Whether the session is configured for simultaneous record + playback. Set BEFORE
    /// microphone capture starts. `.playAndRecord` is only held while sending — it routes
    /// Bluetooth output through the lower-fidelity bidirectional link, so plain `.playback`
    /// is restored the moment the mic stops.
    private var recordingMode = false

    public func setRecordingMode(_ active: Bool) {
        guard recordingMode != active else { return }
        recordingMode = active
        guard isRunning else { return } // start() applies the right category itself
        applySessionCategory()
        // The category change re-routes audio, which can stop a running engine.
        if let engine, !engine.isRunning { try? engine.start() }
    }

    private func applySessionCategory() {
        let session = AVAudioSession.sharedInstance()
        if recordingMode {
            // .defaultToSpeaker: playAndRecord otherwise routes to the earpiece.
            // .allowBluetooth (HFP) is what makes AirPods microphones usable;
            // .allowBluetoothA2DP keeps full-quality output when only receiving on them.
            try? session.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        } else {
            try? session.setCategory(.playback, mode: .default)
        }
    }

    private func installSessionObservers() {
        removeSessionObservers()
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            switch type {
            case .began:
                self.engine?.pause()
                self.onDiagnostic?("audio interrupted")
            case .ended:
                let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    try? self.engine?.start()
                    self.onDiagnostic?("audio resumed after interruption")
                }
            @unknown default:
                break
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Media services daemon restarted — all audio objects are invalid; rebuild.
            guard let self, self.isRunning else { return }
            self.onDiagnostic?("media services reset — restarting audio")
            self.isRunning = false
            self.engine = nil
            self.sourceNode = nil
            self.renderScratch?.deallocate()
            self.renderScratch = nil
            try? self.start()
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Headphones unplugged / AirPods connected etc. The engine usually survives, but
            // if the route change stopped it, kick it back into life.
            guard let self, self.isRunning, let engine = self.engine, !engine.isRunning else { return }
            try? engine.start()
            self.onDiagnostic?("audio restarted after route change")
        })
    }

    private func removeSessionObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
#endif
}
