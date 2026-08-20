import AVFAudio
import Foundation
#if os(iOS)
import UIKit
#endif

/// Renders the mix bus through AVAudioEngine via an AVAudioSourceNode pulling 48 kHz
/// interleaved stereo float32 from the `PlayoutMixer`.
///
/// iOS specifics: configures an AVAudioSession with the `.playback` category and NO
/// `.mixWithOthers` — RemSound is always the primary audio client, which (combined with the
/// `audio` background mode in the app's Info.plist) keeps audio running with the screen
/// locked or the app in the background and makes the app eligible to receive headset
/// transport presses. It also asks for a short IO buffer for low output latency.
/// Interruptions (calls, Siri), engine configuration changes, route changes, returning to
/// the foreground, and media-services resets all restart the engine so audio never stays
/// dead after another app grabs focus.
public final class AudioOutput {
    /// Upper bound on frames rendered per inner loop; the interleaved scratch is sized to
    /// this. IO buffers are far smaller (~256 frames at 5 ms), larger requests are chunked.
    private static let renderChunkFrames = 4096

    private let mixer: PlayoutMixer
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var renderScratch: UnsafeMutablePointer<Float>?
    /// The source→mixer connection format, kept so the graph can be reconnected after an
    /// engine configuration change (which invalidates connections and stops the engine).
    private var renderFormat: AVAudioFormat?
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
        // The media-services-reset path re-enters start() with isRunning already cleared, so
        // drop the previous engine's observers before a new set goes on.
        removeObservers()

#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        applySessionCategory()
        // 48 kHz to match the wire mix rate. The IO buffer duration is a preference (the OS
        // may give us a less aggressive value on some routes) and is now demand-adaptive —
        // see `setLowLatencyDemand`. At launch nothing is flowing, so start on the idle
        // (long) buffer; the controller raises the low-latency value the moment a session
        // opens or capture starts.
        try? session.setPreferredSampleRate(48_000)
        applyPreferredIOBufferDuration()
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
        renderFormat = format
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
        installEngineObservers()
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
        renderFormat = nil
        isRunning = false
        removeObservers()
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
        onDiagnostic?("audio output stopped")
    }

#if os(iOS)
    /// Adaptive IO buffer duration (battery). The render callback fires once per IO buffer,
    /// so a 5 ms buffer wakes the CPU ~200×/s — and the engine is deliberately never stopped
    /// (locked decision: stopping deactivates the shared session, killing background survival
    /// and any live mic capture). While NOTHING is flowing (no playout session and the mic
    /// idle) that cadence renders pure silence, so we stretch the buffer to 100 ms (~10
    /// wakeups/s); the moment demand appears we restore 5 ms. The switch-back latency is
    /// masked by the jitter buffer filling at stream start, so it is never audible.
    private static let lowLatencyIOBufferDuration = 0.005
    private static let idleIOBufferDuration = 0.1
    private var lowLatencyDemand = false

    /// Raise (true) or lower (false) the render-callback cadence to match demand. Driven from
    /// `ReceiverController` on the main actor off session open/close and mic start/stop —
    /// NEVER from the render callback or any audio thread, since `setPreferredIOBufferDuration`
    /// is AVAudioSession IPC.
    public func setLowLatencyDemand(_ demand: Bool) {
        guard lowLatencyDemand != demand else { return }
        lowLatencyDemand = demand
        guard isRunning else { return } // start() applies the right duration itself
        applyPreferredIOBufferDuration()
    }

    private func applyPreferredIOBufferDuration() {
        let duration = lowLatencyDemand ? Self.lowLatencyIOBufferDuration : Self.idleIOBufferDuration
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(duration)
    }

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
        // No `.mixWithOthers` in either branch: RemSound holds the session exclusively.
        // That is what keeps a locked iPhone streaming — iOS is willing to suspend a
        // backgrounded app whose mixable session it deems silent, and to let the network
        // radio power-save under it, which kills the UDP stream (and our heartbeats) until
        // the screen wakes. It is also what makes the app eligible to be the system's Now
        // Playing app, i.e. to receive AirPods stem presses (`RemoteTransportControls`).
        // Cost, accepted by the user 2026-08-20 when the opt-in toggle was dropped: other
        // apps' audio is interrupted while RemSound runs, and theirs interrupts us — the
        // interruption observers below are what bring us back.
        if recordingMode {
            // .defaultToSpeaker: playAndRecord otherwise routes to the earpiece.
            // .allowBluetooth (HFP) is what makes AirPods microphones usable;
            // .allowBluetoothA2DP keeps full-quality output when only receiving on them.
            try? session.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        } else {
            try? session.setCategory(.playback, mode: .default, options: [])
        }
    }

    /// iOS-only session observers. Purely additive — `start()` does the clearing, so this
    /// can never wipe the cross-platform engine observers installed alongside it.
    private func installSessionObservers() {
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
                // Resume when the system asks us to; the didBecomeActive observer is the
                // backstop for interruptions that end without a resume flag.
                let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                    self.resumeEngine("audio resumed after interruption")
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
            self?.resumeEngine("audio restarted after route change")
        })

        // Returning to the foreground: reassert the session and restart the engine if it was
        // left paused. This is the safety net for interruptions that end without a
        // .shouldResume flag (e.g. after another media app held focus), which is exactly the
        // "switch away and audio never comes back" case.
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resumeEngine("audio resumed on returning to foreground")
        })
    }

#else
    /// macOS has no AVAudioSession IO-buffer preference to adapt (the HAL negotiates it), so
    /// the adaptive-cadence lever is iOS-only; accept and ignore for a uniform controller API.
    public func setLowLatencyDemand(_ demand: Bool) {}
#endif

    // MARK: - Engine recovery (both platforms)

    /// The engine stops itself on a configuration change and does NOT auto-restart — the
    /// single most common cause of "audio just stopped". Its connections may be invalidated,
    /// so the graph is reconnected before restarting.
    ///
    /// This MUST stay cross-platform. On iOS the trigger is a route/format change (another
    /// app's audio starting or ending around an app switch); on macOS it is any Core Audio
    /// device change — the output device going away, the system default output moving, or
    /// another engine in this process rebinding a device. macOS has no AVAudioSession and
    /// therefore none of the other recovery notifications, so without this observer a Mac
    /// that switches audio devices loses playback permanently while `isRunning` still
    /// reports true. (It lived inside the iOS-only block until 2026-07-28; a Mac that
    /// changed its input device went silent until relaunch.)
    private func installEngineObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning,
                  let engine = self.engine, !engine.isRunning,
                  let source = self.sourceNode, let format = self.renderFormat else { return }
            // Reconnect at OUR fixed 48 kHz render format — the new device may run at a
            // different rate, and the engine resamples mainMixer → output for us.
            engine.connect(source, to: engine.mainMixerNode, format: format)
            self.resumeEngine("audio restarted after configuration change")
        })
    }

    /// Restart the engine if it is not already running (reasserting the audio session first
    /// on iOS). Safe to call from any recovery notification; a no-op when the engine is
    /// healthy or when playback is stopped.
    private func resumeEngine(_ diagnostic: String) {
        guard isRunning, let engine, !engine.isRunning else { return }
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
#endif
        engine.prepare()
        try? engine.start()
        onDiagnostic?(diagnostic)
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}
