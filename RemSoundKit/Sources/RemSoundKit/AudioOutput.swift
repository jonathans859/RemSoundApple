import AVFAudio
import Foundation
#if os(iOS)
import UIKit
#endif

/// Renders the mix bus through AVAudioEngine via an AVAudioSourceNode pulling 48 kHz
/// interleaved stereo float32 from the `PlayoutMixer`.
///
/// iOS specifics: configures an AVAudioSession with the `.playback` category and — unless
/// the user has asked RemSound to share the output — NO `.mixWithOthers`, i.e. RemSound is
/// the primary audio client. That (combined with the `audio` background mode in the app's
/// Info.plist) is what keeps audio running with the screen locked or the app in the
/// background, and what makes the app eligible to receive headset transport presses; see
/// `setExclusiveAudio`. It also asks for a short IO buffer for low output latency.
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

    /// True from an audio-session interruption until playback actually comes back. iOS only
    /// in practice (nothing sets it on macOS), but declared unconditionally so the recovery
    /// path below stays free of platform conditionals — pitfall 12 is what happens when that
    /// path grows an `#if os(iOS)`. Drives `pollInterruptionRecovery`.
    private var interrupted = false

    public var onDiagnostic: ((String) -> Void)?

    /// Fired when playback was brought back after it had actually stopped — an interruption
    /// that ended, a route or configuration change, a media-services reset, or returning to
    /// the foreground. Never fired for a normal start, and never while the engine was
    /// already running.
    ///
    /// It exists for the Now Playing claim: whatever interrupted us is very likely holding
    /// the system transport now, there is no API to ask who does, and re-publishing only
    /// works while we are eligible — i.e. playing audio through an exclusive session, which
    /// is exactly what has just become true again. See `ReceiverController`'s handler.
    public var onPlaybackRecovered: (() -> Void)?

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
        // A fresh engine is by definition not interrupted. This matters for the rebuild the
        // media-services reset does: leaving the flag set there would make the recovery poll
        // read a session property every second for the rest of the process's life.
        interrupted = false
        installEngineObservers()
        onDiagnostic?("audio output started")
    }

    public func stop() {
        guard isRunning else { return }
        interrupted = false
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
    /// When true (the default) the session drops `.mixWithOthers`: RemSound is the PRIMARY
    /// audio client. That is what keeps a locked iPhone streaming — iOS is willing to
    /// suspend a backgrounded app whose mixable session it deems silent and to let the
    /// network radio power-save under it, which kills the UDP stream (and our heartbeats)
    /// until the screen wakes. It is also what makes the app eligible to be the system's Now
    /// Playing app, i.e. to receive AirPods stem presses (`RemoteTransportControls`).
    ///
    /// Cost: while it is on, another app's playback interrupts us and ours interrupts
    /// theirs — exactly what someone listening to a room in the background does not want,
    /// which is why this is a user-facing switch. Off buys coexistence and gives up both of
    /// the above.
    private var exclusiveAudio = true

    /// Backstop for an interruption we were never told had ended, or that ended while the
    /// interrupting app was still playing. Both are real: an app that merely *pauses* often
    /// never deactivates its session, so no `.ended` arrives at all, and an `.ended` that
    /// carries no `.shouldResume` finds us with no other signal to act on.
    ///
    /// Called once a second from the functional half of `ReceiverController`'s existing
    /// refresh tick — no new timer, and no wakeup that was not already happening. It costs
    /// one session-property read per second, and ONLY while we are down: `interrupted` is
    /// false the rest of the time, so this is not a hot path. (`isOtherAudioPlaying` is a
    /// session property, not HAL device enumeration — pitfall 5 is about the latter.)
    ///
    /// Resuming here can interrupt an app that is paused but still holds an active session.
    /// That is the intent, not an accident: the user asked for RemSound back, and nothing is
    /// audibly playing at that moment. The gate is what keeps the original "don't ping-pong
    /// with the app that just took over" rule intact — while they are actually playing we
    /// stay down.
    ///
    /// Limitation, unavoidable: a backgrounded silent app can be suspended outright, and a
    /// suspended app runs no tick. When that happens nothing self-recovers and opening the
    /// app is still the way back.
    public func pollInterruptionRecovery() {
        guard isRunning, interrupted, let engine, !engine.isRunning else { return }
        guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }
        resumeEngine("audio resumed once the other app stopped playing")
    }

    public func setExclusiveAudio(_ exclusive: Bool) {
        guard exclusiveAudio != exclusive else { return }
        exclusiveAudio = exclusive
        guard isRunning else { return } // start() applies the right category itself
        applySessionCategory()
        // The category change re-routes audio, which can stop a running engine.
        if let engine, !engine.isRunning { try? engine.start() }
    }

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
        // `.mixWithOthers` goes in only when the user has asked RemSound to share the
        // output — see `exclusiveAudio` above for what the exclusive session buys and what
        // it costs. While it IS exclusive, another app's audio interrupts us; the
        // interruption observers below are what bring us back.
        if recordingMode {
            // .defaultToSpeaker: playAndRecord otherwise routes to the earpiece.
            // .allowBluetooth (HFP) is what makes AirPods microphones usable;
            // .allowBluetoothA2DP keeps full-quality output when only receiving on them.
            var options: AVAudioSession.CategoryOptions =
                [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            if !exclusiveAudio { options.insert(.mixWithOthers) }
            try? session.setCategory(.playAndRecord, mode: .default, options: options)
        } else {
            try? session.setCategory(
                .playback, mode: .default, options: exclusiveAudio ? [] : [.mixWithOthers])
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
                self.interrupted = true
                self.engine?.pause()
                self.onDiagnostic?("audio interrupted")
            case .ended:
                let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    .contains(.shouldResume)
                if shouldResume {
                    self.resumeEngine("audio resumed after interruption")
                } else if !AVAudioSession.sharedInstance().isOtherAudioPlaying {
                    // No resume flag, but nothing is playing — see `interrupted`. Confirmed
                    // on hardware (2026-08-27): another media app ending its playback is
                    // exactly this case, and ignoring it left the app silent AND holding no
                    // transport claim until the user opened it.
                    self.resumeEngine("audio resumed after interruption (no resume flag, nothing else playing)")
                } else {
                    // Something else is still playing: staying paused is the original rule,
                    // and `pollInterruptionRecovery` picks us up when they stop.
                    self.onDiagnostic?("interruption ended without a resume flag — another app is still playing")
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
            // Rebuilt from nothing — the media daemon that owns the Now Playing item is the
            // very thing that just restarted, so re-stake the claim like any other recovery.
            if self.isRunning { self.onPlaybackRecovered?() }
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
    /// macOS has no AVAudioSession — exclusive audio is an iOS-only concept; accept and
    /// ignore so the shared controller doesn't need platform conditionals.
    public func setExclusiveAudio(_ exclusive: Bool) {}

    /// No AVAudioSession means no interruptions to recover from; the configuration-change
    /// observer is macOS's recovery path (pitfall 12). Accept and ignore.
    public func pollInterruptionRecovery() {}

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
        // Report only what actually happened. A restart can legitimately fail — the poll
        // above retries once a second, and during a phone call every attempt fails until the
        // call ends — so claiming "audio resumed" on each of them would fill the diagnostics
        // with a recovery that never occurred and hide the fact that we are still down.
        guard engine.isRunning else { return }
        interrupted = false
        onDiagnostic?(diagnostic)
        // A silent app has no claim to stake; this is the moment we are eligible again.
        onPlaybackRecovered?()
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}
