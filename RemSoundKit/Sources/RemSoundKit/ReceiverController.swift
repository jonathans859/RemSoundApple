import Foundation
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One row in the peer list — a discovered peer, a manual entry, or both merged by address.
public struct PeerListEntry: Identifiable, Hashable, Sendable {
    public enum Source: Sendable {
        case discovered
        case manual
    }

    public let id: String
    public let name: String
    public let addressString: String
    /// Every endpoint this peer is reachable at — multi-homed peers (LAN + VPN) have
    /// several. The first is the primary/display one. Empty while a manual host resolves.
    public let audioEndpoints: [UDPEndpoint]
    public let source: Source
    public let manualPeerId: UUID?
    public var isSelected: Bool
    public var statusText: String

    public var audioEndpoint: UDPEndpoint? { audioEndpoints.first }
    var addresses: [UInt32] { audioEndpoints.map(\.address) }
    var allAddressStrings: [String] { audioEndpoints.map(\.addressString) }
}

/// Holds a NotificationCenter observer token and unregisters it when it goes away, so an
/// actor-isolated owner does not need a `deinit` of its own (a `@MainActor` class cannot
/// touch its stored properties from the nonisolated `deinit`).
private final class NotificationToken {
    var value: NSObjectProtocol?

    deinit {
        if let value {
            NotificationCenter.default.removeObserver(value)
        }
    }
}

/// App-facing coordinator: owns the engine, audio output, discovery, heartbeat, and cues;
/// publishes UI state. All published state is touched on the main actor; the underlying
/// services run on their own threads and are polled / event-driven into main-actor updates.
@MainActor
@Observable
public final class ReceiverController {
    /// The one live instance. The apps' UI and the Shortcuts actions (`AppIntents.swift`)
    /// must drive the SAME receiver, so both go through this instead of creating their own.
    public static let shared = ReceiverController()

    // Published state
    public private(set) var peers: [PeerListEntry] = []
    public private(set) var statusSummary = "Stopped"
    public private(set) var isRunning = false
    public private(set) var lastError: String?
    /// The at-a-glance connection state — who is connected, their ping, uptime. Kept short
    /// on purpose: this is the list a screen-reader user arrows through every time they open
    /// the app, so the packet-level material lives in `diagnosticDetails` instead.
    public private(set) var connectionDetails: [String] = []
    /// The technical panel behind the Diagnostics button: traffic, buffer depth, glitch and
    /// packet counters, timing, codec mode. Same 1 Hz tick; collected whether or not anyone
    /// is looking, so opening the dialog shows real history rather than starting from zero.
    public private(set) var diagnosticDetails: [String] = []
    /// Inputs the user can pick for microphone sending. Refreshed when the hardware set
    /// changes (route change / device list notifications), at start, and on send start —
    /// never on a timer; enumeration IPC alongside live playback causes audible glitches.
    public private(set) var availableMicrophones: [AudioInputDevice] = []
    /// Plain-sentence state of the send path ("Sending microphone audio to 1 peer").
    public private(set) var sendStatus = ""
    /// Live traffic rates as one spoken sentence — the Connectivity tab bar item exposes
    /// this as its accessibility value (like the Audio tab's "Muted"), so VoiceOver users
    /// hear the rates without opening the tab. Same 1 Hz tick as `connectionDetails`.
    public private(set) var trafficSummary = ""
    /// Saved configuration snapshots (Profiles tab). Mutated only through the profile
    /// methods below, which keep `ProfileStore` in sync.
    public private(set) var profiles: [ReceiverProfile] = []
    /// The profile the settings last came from (applied, saved, or updated) — the
    /// candidate for the "currently applied" marker. `appliedProfile` re-checks it
    /// against the live configuration, so the marker drops the moment settings drift.
    public private(set) var lastAppliedProfileId: UUID?

    /// The profile the current configuration exactly matches, if any — drives the
    /// "Currently applied" row marker and the Profiles tab's accessibility value.
    /// Drift-checked: apply "Home", then change any profile-covered setting, and Home
    /// stops reading as applied.
    public var appliedProfile: ReceiverProfile? {
        guard let id = lastAppliedProfileId,
              let profile = profiles.first(where: { $0.id == id }),
              profileStore.password(forProfile: profile.id) == password else { return nil }
        var live = profileSnapshot(id: profile.id, name: profile.name)
        // A profile with auto-tune on does not pin a delay — the tuner owns that value at
        // runtime (which is also why its moves are not persisted). Comparing it would drop
        // the marker within seconds of applying such a profile, reporting drift for the one
        // thing the profile explicitly delegates. Every other field is still compared, so a
        // real edit — including turning auto-tune off — still clears the marker.
        if profile.autoTuneLatencyEnabled && live.autoTuneLatencyEnabled {
            live.targetLatencyMs = profile.targetLatencyMs
        }
        guard live == profile else { return nil }
        return profile
    }

    /// Microphone sending on/off — persisted like the receive toggle (user decision
    /// 2026-07-12: the old "never persist send" rule is retired). Sending saved as on
    /// resumes at launch, via `startupSendPending`: capture can only start once the
    /// engines are up, at the end of the first `start()`. Independent of
    /// `receiveEnabled` (Windows parity): both ride the always-bound audio socket.
    public var sendEnabled = false {
        didSet {
            guard sendEnabled != oldValue else { return }
            settings.sendEnabled = sendEnabled
            if sendEnabled { startSending() } else { stopSending() }
            discovery.setCapabilities(canSend: sendEnabled, canReceive: receiveEnabled)
        }
    }

    /// Playback of received audio — the Windows "Receive audio" checkbox. Gates ONLY
    /// playback: the socket, heartbeats, and discovery stay up regardless (single-port
    /// model — see the Windows AudioReceiver's SetPlaybackEnabled), so sending and peer
    /// health keep working while this is off, and peers see an honest CanReceive flag.
    /// Persisted, default on.
    public var receiveEnabled: Bool {
        didSet {
            guard receiveEnabled != oldValue else { return }
            settings.receiveEnabled = receiveEnabled
            engine.setPlaybackEnabled(receiveEnabled)
            discovery.setCapabilities(canSend: sendEnabled, canReceive: receiveEnabled)
            if receiveEnabled && !isRunning { start() }
            // Whatever moved this — the UI, a profile, a Shortcut, or a headset press —
            // the lock-screen play button must not be left showing the opposite state.
            updateNowPlaying()
            refreshNow()
        }
    }

    /// Which input to send from; nil = system default. Persisted.
    public var selectedMicrophoneId: String? {
        didSet {
            guard selectedMicrophoneId != oldValue else { return }
            settings.selectedMicrophoneId = selectedMicrophoneId
            microphone.setPreferredInput(id: selectedMicrophoneId)
            // Live switch: rebuild the capture graph on the new input.
            if microphone.isRunning {
                microphone.stop()
                try? microphone.start()
            }
        }
    }

    public var volume: Float {
        didSet {
            mixer.volume = volume
            settings.volume = volume
        }
    }

    /// Extra playback gain for quiet senders, on top of `volume`. Persisted; deliberately
    /// NOT part of a profile — like volume and the other audio options, it belongs to the
    /// device you are listening on, not to the connection setup.
    public var volumeBoost: VolumeBoost {
        didSet {
            mixer.boost = volumeBoost
            settings.volumeBoostDb = volumeBoost.rawValue
        }
    }

    public var isMuted = false {
        didSet { mixer.isMuted = isMuted }
    }

    /// Quick mute for the VoiceOver magic tap (two-finger double tap, iOS). Announces the
    /// result because the gesture fires from anywhere — the mute toggle is usually not the
    /// focused element, so its state change would otherwise be silent.
    public func toggleMute() {
        isMuted.toggle()
        announce(isMuted ? "Audio muted" : "Audio unmuted")
    }

    /// A transport press arrived from outside the app (AirPods stem, media key, lock
    /// screen). Announced for the same reason `toggleMute` is: the press comes from
    /// somewhere the receive toggle is not focused — or not even on screen — so the state
    /// change would otherwise be silent for a screen-reader user.
    private func setReceiveFromTransport(_ enabled: Bool) {
        guard receiveEnabled != enabled else { return }
        receiveEnabled = enabled // didSet re-publishes the now-playing state
        announce(enabled ? "Receiving audio" : "Receiving paused")
    }

    /// Claim or release the system transport, following the setting and whether the
    /// receiver is up at all. Idempotent — safe to call from either trigger.
    private func applyRemoteControls() {
        guard headsetTransportControls, isRunning else {
            remoteControls.deactivate()
            return
        }
        remoteControls.activate()
        updateNowPlaying()
    }

    /// Push the receive state to the lock screen / Control Center. Cheap and change-gated
    /// inside `RemoteTransportControls`, and deliberately NOT on the 1 Hz tick.
    private func updateNowPlaying() {
        remoteControls.update(
            isPlaying: receiveEnabled,
            detail: receiveEnabled ? "Receiving audio" : "Receiving paused")
    }

    public var targetLatencyMs: Int {
        didSet {
            // Auto-tune moves this too. When it does, the change is runtime state, not a
            // setting the user chose: it must not be persisted over their value, and it must
            // not restart the deferral window that exists to let a *user* edit settle.
            // Upstream draws the same distinction with `suppressUserSliderMoveTracking`.
            if autoTuneIsMovingTarget {
                mixer.setTargetLatencyMs(targetLatencyMs, drainOnLower: false)
            } else {
                mixer.setTargetLatencyMs(targetLatencyMs)
                settings.targetLatencyMs = targetLatencyMs
                lastUserLatencyChange = Date()
            }
        }
    }

    /// Continuously retune `targetLatencyMs` to what the link needs. See `LatencyAutoTune`.
    public var autoTuneLatencyEnabled: Bool {
        didSet {
            settings.autoTuneLatencyEnabled = autoTuneLatencyEnabled
            guard autoTuneLatencyEnabled != oldValue else { return }
            // Start from a clean slate either way: stale history from before the toggle would
            // otherwise drive the first tick.
            autoTuneSamples = []
            lastUserLatencyChange = Date()
            if !autoTuneLatencyEnabled {
                // Hand the user's own setting back — the tuned value was never theirs.
                targetLatencyMs = settings.targetLatencyMs
            }
        }
    }

    public var cuesEnabled: Bool {
        didSet {
            cues.enabled = cuesEnabled
            settings.cuesEnabled = cuesEnabled
        }
    }

    /// Let an AirPods stem press (or the Mac's media keys, or the lock-screen / Control
    /// Center transport) pause and resume receiving. Persisted, default on.
    /// See `RemoteTransportControls`.
    public var headsetTransportControls: Bool {
        didSet {
            guard headsetTransportControls != oldValue else { return }
            settings.headsetTransportControls = headsetTransportControls
            applyRemoteControls()
        }
    }

    public var password: String {
        didSet {
            settings.password = password
            applyPassword()
        }
    }

    /// What the app applies at the next launch: nothing (default), the last applied
    /// profile, or one fixed profile. Persisted; consumed before the settings are read
    /// in `init` by `ProfileStore.applyStartupProfile(to:)`.
    public var startupProfile: StartupProfileChoice {
        didSet {
            guard startupProfile != oldValue else { return }
            settings.startupProfile = startupProfile
        }
    }

    /// Share saved profiles across the user's devices through iCloud. Flipping this moves
    /// the profile passwords between the device-local and iCloud keychains and, when
    /// turning on, merges with whatever is already in the account — so the store does the
    /// work, not a plain settings write.
    public var iCloudProfileSyncEnabled: Bool {
        didSet {
            guard iCloudProfileSyncEnabled != oldValue else { return }
            profileStore.setSyncEnabled(iCloudProfileSyncEnabled)
            profiles = profileStore.profiles
            announce(iCloudProfileSyncEnabled
                     ? "Profile sync through iCloud on"
                     : "Profile sync through iCloud off")
        }
    }

    // Services
    private let settings = ReceiverSettings()
    private let profileStore = ProfileStore(syncStore: NSUbiquitousKeyValueStore.default)
    /// Token for the iCloud external-change notification. It lives in a box rather than a
    /// plain property because this class is `@MainActor`, which makes its `deinit`
    /// nonisolated and therefore unable to read main-actor state — the box's own deinit
    /// does the removal instead. (`MicrophoneCapture` can hold its tokens directly; it is
    /// not actor-isolated.)
    private let cloudObserver = NotificationToken()
    private let engine = AudioReceiverEngine()
    private let output: AudioOutput
    private let discovery = PeerDiscoveryService()
    private let heartbeat = HeartbeatService()
    private let cues = CuePlayer()
    private let remoteControls = RemoteTransportControls()
    private let sendEngine = AudioSendEngine()
    private let microphone = MicrophoneCapture()
    private var sendTargetCount = 0
    private var mixer: PlayoutMixer { engine.mixer }

    private var manualPeers: [ManualPeer]
    private var selectedAddresses: Set<String>
    /// The persisted send toggle (possibly just rewritten by a startup profile) was on at
    /// launch — honoured at the end of the first `start()`, once the engines and
    /// discovery are up (flipping `sendEnabled` any earlier re-enters `start()` from its
    /// didSet). Consumed once; a later stop()/start() never resurrects it.
    private var startupSendPending = false
    /// Monotonic token guarding async PBKDF2 results — see `applyPassword`.
    private var passwordGeneration = 0
    /// Resolved IPv4 addresses (network byte order) per manual peer id.
    private var manualResolved: [UUID: [UDPEndpoint]] = [:]
    /// DNS retry state (issue #1): a manual peer whose name fails to resolve once — e.g.
    /// a Tailscale MagicDNS name looked up before the tunnel is fully up — must not stay
    /// "Resolving…" forever. The 1 Hz tick re-kicks resolution while any peer is
    /// unresolved, paced by this timestamp and serialized by the in-flight flag.
    private static let resolveRetryInterval: TimeInterval = 5
    private var lastResolveAttempt = Date.distantPast
    private var resolveInFlight = false
    /// Addresses currently delivering audio — drives the "Receiving from N peers" summary.
    private var audibleAddresses: Set<UInt32> = []
    /// Connect/disconnect cue state per selected peer, keyed by the stable primary address.
    /// Mirrors the Windows receiver's hysteresis rule (MainForm.
    /// DetectAndAnnouncePeerHealthTransitions, upstream 2026-05-31) — see `updateCues`.
    private var peerConnectedState: [UInt32: Bool] = [:]
    private var refreshTask: Task<Void, Never>?
    /// Whether a UI is currently on screen (battery finding 2). Defaults to false so a
    /// menu-bar macOS launch — window closed — does no presentation work until the window
    /// opens; the apps report visibility via `setUIVisible` (iOS scenePhase, macOS the main
    /// window's onAppear/onDisappear). Gates only the presentation half of the refresh tick.
    private var uiVisible = false

    // Previous traffic-counter snapshot for the per-second rate lines.
    private var lastBytesReceived: Int64 = 0
    private var lastBytesSent: Int64 = 0
    private var lastRateDate = Date()
    private var lastRxRateKBs = 0.0
    private var lastTxRateKBs = 0.0

    // Sliding window of cumulative glitch totals for the "last minute" connection line.
    private var glitchSamples: [(time: Date, underruns: Int64, trims: Int64, concealedMs: Int64)] = []

    // Same sliding-minute treatment for the packet counters. The peak arrival gap is a peak
    // rather than a total, so it is drained from the engine each tick and kept per-sample —
    // the reported figure is the max across the window, not a difference of endpoints.
    private var packetSamples: [(time: Date, stats: StreamDiagnosticsSnapshot,
                                peakGapMs: Int, peakRenderGapMs: Int)] = []

    // --- Continuous auto-tune state (see LatencyAutoTune) ---
    private var autoTuneSamples: [LatencyAutoTune.Sample] = []
    private var lastAutoTuneRun = Date.distantPast
    private var lastUserLatencyChange = Date.distantPast
    private var lastTuneBlockingUnderruns: Int64 = 0
    private var lastSessionsOpenedCount: Int64 = 0
    /// True only while the tuner is assigning `targetLatencyMs`, so its didSet can tell an
    /// automatic move from a user's.
    private var autoTuneIsMovingTarget = false
    /// Last decision, for the diagnostics panel.
    private(set) var lastAutoTuneNote: String?

    /// Last thing the audio engine reported (interruption, route change, media-services
    /// reset, start/stop). Shown in the Diagnostics panel: when a headset press stops the
    /// audio without changing our state, this is what says whether the system interrupted
    /// the session behind our back or nothing happened at that layer at all.
    private var lastAudioEvent: (message: String, at: Date)?

    public init() {
        // Startup profile (if configured): rewrite the persisted settings BEFORE they are
        // read below — rewriting-then-loading avoids every didSet/engine side effect.
        ProfileStore().applyStartupProfile(to: ReceiverSettings())

        manualPeers = settings.manualPeers
        selectedAddresses = settings.selectedPeerAddresses
        profiles = profileStore.profiles
        startupProfile = settings.startupProfile
        iCloudProfileSyncEnabled = settings.iCloudProfileSyncEnabled
        // After the overlay above, so a startup profile reads as applied right away.
        lastAppliedProfileId = settings.lastAppliedProfileId
        volume = settings.volume
        volumeBoost = VolumeBoost(rawValue: settings.volumeBoostDb) ?? .off
        targetLatencyMs = settings.targetLatencyMs
        cuesEnabled = settings.cuesEnabled
        autoTuneLatencyEnabled = settings.autoTuneLatencyEnabled
        password = settings.password
        headsetTransportControls = settings.headsetTransportControls
        receiveEnabled = settings.receiveEnabled
        // Loaded into the pending flag, not sendEnabled itself: capture must not start
        // until the engines are up (end of the first start()); didSet is skipped in init
        // anyway, so assigning sendEnabled here would show "on" without ever sending.
        startupSendPending = settings.sendEnabled
        output = AudioOutput(mixer: engine.mixer)

        mixer.volume = volume
        mixer.boost = volumeBoost
        mixer.setTargetLatencyMs(targetLatencyMs)
        cues.enabled = cuesEnabled
        // didSet does not fire for the assignments above (init), so push the persisted
        // receive-playback choice into the engine explicitly.
        engine.setPlaybackEnabled(receiveEnabled)

        // Headset / lock-screen transport. The commands are only registered once the
        // receiver is actually running (`applyRemoteControls` in `start()`); wiring the
        // handlers here just says what they do.
        remoteControls.onPlay = { [weak self] in self?.setReceiveFromTransport(true) }
        remoteControls.onPause = { [weak self] in self?.setReceiveFromTransport(false) }
        remoteControls.onToggle = { [weak self] in
            guard let self else { return }
            self.setReceiveFromTransport(!self.receiveEnabled)
        }

        output.onDiagnostic = { [weak self] message in
            Task { @MainActor [weak self] in self?.lastAudioEvent = (message, Date()) }
        }

        engine.onHeartbeatReceived = { [heartbeat] buffer, length, remote in
            heartbeat.handleInjectedPacket(buffer, length: length, remote: remote)
        }
        heartbeat.sendTransport = { [engine] data, endpoint in
            engine.sendFromAudioSocket(data, to: endpoint)
        }
        discovery.onPeersChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A peer appearing (or changing address) must re-feed the allow-list and
                // heartbeat tracking, or a previously-selected peer discovered after start()
                // shows as selected while all its audio packets are rejected.
                self.applyPeerSelection()
                self.refreshNow()
            }
        }
        engine.onSessionsChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.refreshNow() }
        }

        // Send path: outbound audio leaves the SAME socket inbound audio arrives on (the
        // shared NAT pinhole), and the capture tap feeds the send engine directly on the
        // capture thread.
        sendEngine.transport = { [engine] data, endpoint in
            engine.sendFromAudioSocket(data, to: endpoint)
        }
        microphone.onSamples = { [sendEngine] samples, frames in
            sendEngine.submit(samples, frameCount: frames)
        }
        // Refresh the picker's input list only when the hardware set actually changes —
        // NOT on the 1 Hz tick. Polling AVAudioSession / the Core Audio HAL every second
        // does audio-server IPC alongside live playback and audibly glitched it.
        microphone.onInputsChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.refreshMicrophoneList() }
        }
        selectedMicrophoneId = settings.selectedMicrophoneId
        microphone.setPreferredInput(id: selectedMicrophoneId)

        // Another device changed the shared profile set. The notification also fires for
        // the initial download after a fresh install, which is how a new device picks up
        // the existing profiles without any user action.
        cloudObserver.value = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.mergeProfilesFromCloud() }
        }
        // Kick a pull at launch: changes that landed while the app was not running do not
        // replay as notifications.
        if iCloudProfileSyncEnabled {
            NSUbiquitousKeyValueStore.default.synchronize()
            mergeProfilesFromCloud()
        }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        lastError = nil
        glitchSamples = []
        packetSamples = []
        autoTuneSamples = []
        lastAutoTuneNote = nil
        lastUserLatencyChange = Date()
        refreshMicrophoneList()
        applyPassword()
        do {
            try engine.start(port: settings.listenPort)
            try output.start()
        } catch {
            lastError = "Could not start: \(error.localizedDescription)"
            engine.stop()
            statusSummary = "Stopped — \(lastError!)"
            return
        }
        heartbeat.start()
        discovery.start(displayName: Self.deviceName(), audioPort: settings.listenPort)
        discovery.setCapabilities(canSend: sendEnabled, canReceive: receiveEnabled)
        isRunning = true
        applyRemoteControls()
        applyPeerSelection()
        resolveManualPeers()

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // 200 ms tolerance lets this UI-refresh wakeup coalesce with the heartbeat,
                // discovery, and prune timers and the audio callbacks (battery); the refresh
                // is cosmetic-cadence, so a little jitter is invisible.
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(200))
                self?.refreshNow()
            }
        }
        refreshNow()

        // Send was persisted as on (directly or via a startup profile): resume it now.
        // isRunning is already true, so the sendEnabled didSet cannot re-enter start().
        if startupSendPending {
            startupSendPending = false
            sendEnabled = true
        }
    }

    public func stop() {
        if sendEnabled { sendEnabled = false } // didSet stops capture + send engine
        refreshTask?.cancel()
        refreshTask = nil
        discovery.stop()
        heartbeat.stop()
        remoteControls.deactivate()
        output.stop()
        engine.stop()
        isRunning = false
        audibleAddresses = []
        peerConnectedState = [:] // cleared silently — the stop toggle is its own feedback
        statusSummary = "Stopped"
        connectionDetails = []
        trafficSummary = ""
        refreshPeerList()
    }

    private static func deviceName() -> String {
#if os(iOS)
        return UIDevice.current.name
#else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
#endif
    }

    private func applyPassword() {
        // Each edit bumps the generation so a slow derivation of an older password can
        // never land after a newer one (or after the password was cleared).
        passwordGeneration &+= 1
        let generation = passwordGeneration
        guard !password.isEmpty else {
            // No password = no key: stop decrypting and sending immediately (the engines
            // otherwise keep running on the previously derived key).
            engine.setKeyMaterial(key: nil, fingerprint: nil)
            sendEngine.setKeyMaterial(key: nil, fingerprint: nil)
            return
        }
        // PBKDF2 at 100k iterations takes ~50-100 ms — off the main actor. Derived once,
        // shared by the receive and send engines.
        let pw = password
        Task.detached(priority: .userInitiated) { [weak self] in
            let key = RemSoundCrypto.deriveKey(password: pw)
            let fingerprint = RemSoundCrypto.fingerprint(password: pw)
            await MainActor.run { [weak self] in
                guard let self, self.passwordGeneration == generation else { return }
                self.engine.setKeyMaterial(key: key, fingerprint: fingerprint)
                self.sendEngine.setKeyMaterial(key: key, fingerprint: fingerprint)
            }
        }
    }

    // MARK: - Peer management

    public func addManualPeer(host: String, port: UInt16 = RemPacket.defaultPort) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !manualPeers.contains(where: { $0.host == trimmed && $0.port == port }) else { return }
        let peer = ManualPeer(host: trimmed, port: port)
        manualPeers.append(peer)
        settings.manualPeers = manualPeers
        resolveManualPeers()
        refreshNow()
    }

    public func removeManualPeer(id: UUID) {
        if let peer = manualPeers.first(where: { $0.id == id }) {
            for ep in manualResolved[id] ?? [] {
                selectedAddresses.remove(ep.addressString)
            }
            selectedAddresses.remove(peer.host)
        }
        manualPeers.removeAll { $0.id == id }
        manualResolved.removeValue(forKey: id)
        settings.manualPeers = manualPeers
        settings.selectedPeerAddresses = selectedAddresses
        applyPeerSelection()
        refreshNow()
    }

    public func setPeerSelected(_ entry: PeerListEntry, selected: Bool) {
        // Select/deselect every address the peer is reachable at, plus the manual hostname
        // if there is one, so the choice survives path changes and re-resolution.
        var strings = Set(entry.allAddressStrings)
        strings.insert(entry.addressString)
        if let manualId = entry.manualPeerId,
           let manual = manualPeers.first(where: { $0.id == manualId }) {
            strings.insert(manual.host)
        }
        if selected {
            selectedAddresses.formUnion(strings)
        } else {
            selectedAddresses.subtract(strings)
        }
        settings.selectedPeerAddresses = selectedAddresses
        applyPeerSelection()
        refreshNow()
    }

    // MARK: - Profiles

    /// Save the current configuration under `name`. A name matching an existing profile
    /// (case-insensitive) updates that profile in place — that's the edit path, alongside
    /// the row's explicit "save current settings here" action.
    public func saveProfile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let existing = profiles.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            updateProfile(id: existing.id)
            return
        }
        let profile = profileSnapshot(id: UUID(), name: trimmed)
        profiles.append(profile)
        profileStore.setPassword(password, forProfile: profile.id)
        profileStore.profiles = profiles
        markApplied(profile.id) // the saved profile IS the current configuration
        announce("Profile \(trimmed) saved")
    }

    /// Overwrite an existing profile with the current configuration, keeping its name.
    public func updateProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index] = profileSnapshot(id: id, name: profiles[index].name)
        profileStore.setPassword(password, forProfile: id)
        profileStore.profiles = profiles
        markApplied(id) // now identical to the current configuration
        announce("Profile \(profiles[index].name) updated")
    }

    public func renameProfile(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
        profileStore.profiles = profiles
    }

    public func deleteProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let name = profiles[index].name
        profileStore.removePassword(forProfile: id) // the one path that may remove it
        profiles.remove(at: index)
        profileStore.profiles = profiles
        // Deleting is the ONE path that removes the profile from iCloud, so that a device
        // which has not pulled yet can never wipe the shared set just by publishing its
        // own shorter list (see ProfileSync.push).
        profileStore.removeFromCloud(id: id)
        // Drop dangling launch references so the picker never shows a deleted profile.
        if startupProfile == .fixed(id) { startupProfile = .off }
        if settings.lastAppliedProfileId == id { settings.lastAppliedProfileId = nil }
        if lastAppliedProfileId == id { lastAppliedProfileId = nil }
        announce("Profile \(name) deleted")
    }

    /// Adopt profile changes made on another device. Only the saved snapshots move — the
    /// live configuration, which profile is applied here, and the launch choice are all
    /// device state and stay put, so a profile applied on the Mac does not reach in and
    /// change what the iPhone is running.
    private func mergeProfilesFromCloud() {
        guard let merged = profileStore.mergeFromCloud() else { return }
        profiles = merged
        // A profile deleted elsewhere must not linger as the launch choice here.
        if case .fixed(let id) = startupProfile, !merged.contains(where: { $0.id == id }) {
            startupProfile = .off
        }
        refreshNow()
    }

    /// Replace the live configuration with a saved profile. Only the profile's fields are
    /// touched — volume, cues, exclusive audio, and the rest stay as they are.
    public func applyProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        manualPeers = profile.manualPeers
        settings.manualPeers = manualPeers
        // Keep resolutions for peers that survive the swap (matched by id); drop the rest.
        let ids = Set(manualPeers.map(\.id))
        manualResolved = manualResolved.filter { ids.contains($0.key) }
        selectedAddresses = Set(profile.selectedPeerAddresses)
        settings.selectedPeerAddresses = selectedAddresses
        // Before the delay, not after: switching auto-tune off hands back the persisted
        // user value, which would otherwise land on top of the profile's own delay.
        autoTuneLatencyEnabled = profile.autoTuneLatencyEnabled
        targetLatencyMs = profile.targetLatencyMs
        selectedMicrophoneId = profile.selectedMicrophoneId
        password = profileStore.password(forProfile: profile.id)
        receiveEnabled = profile.receiveEnabled
        // Send last: it may start the capture pipeline (microphone permission prompt
        // included), and by now the key material and peer selection it needs are in place.
        // Applying a profile is an explicit user tap, so a profile with sending on turning
        // the mic on here does not break the "mic never goes hot at launch" rule.
        sendEnabled = profile.sendEnabled
        markApplied(profile.id)
        applyPeerSelection()
        resolveManualPeers()
        refreshNow()
        announce("Profile \(profile.name) applied")
    }

    /// Record which profile the settings now come from — persisted (feeds the
    /// "last applied" launch mode) and published (feeds the applied marker).
    private func markApplied(_ id: UUID) {
        settings.lastAppliedProfileId = id
        lastAppliedProfileId = id
    }

    private func profileSnapshot(id: UUID, name: String) -> ReceiverProfile {
        ReceiverProfile(
            id: id,
            name: name,
            manualPeers: manualPeers,
            selectedPeerAddresses: Array(selectedAddresses).sorted(),
            receiveEnabled: receiveEnabled,
            sendEnabled: sendEnabled,
            selectedMicrophoneId: selectedMicrophoneId,
            targetLatencyMs: targetLatencyMs,
            autoTuneLatencyEnabled: autoTuneLatencyEnabled)
    }

    private func resolveManualPeers() {
        guard !resolveInFlight else { return }
        resolveInFlight = true
        lastResolveAttempt = Date()
        let peersToResolve = manualPeers
        Task.detached { [weak self] in
            var resolved: [UUID: [UDPEndpoint]] = [:]
            for peer in peersToResolve {
                resolved[peer.id] = UDPEndpoint.resolve(host: peer.host, port: peer.port)
            }
            let result = resolved
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.resolveInFlight = false
                // Merge per peer instead of replacing wholesale: a transient DNS failure
                // during a retry must not wipe a previously good resolution (that would
                // drop the peer from the allow-list mid-stream), a peer added while this
                // lookup was in flight must not lose its own fresher entry, and a peer
                // removed meanwhile must not be re-inserted.
                for (id, endpoints) in result where self.manualPeers.contains(where: { $0.id == id }) {
                    if endpoints.isEmpty, !(self.manualResolved[id] ?? []).isEmpty { continue }
                    self.manualResolved[id] = endpoints
                }
                self.applyPeerSelection()
                self.refreshNow()
            }
        }
    }

    /// Issue #1: names that failed to resolve retry every few seconds while receiving is
    /// on, so a Tailscale name entered (or launched) before the tunnel was up heals itself.
    /// Runs on the 1 Hz tick; plain DNS on a detached task, no audio-server IPC involved.
    private func retryUnresolvedPeersIfNeeded() {
        guard isRunning, !resolveInFlight,
              manualPeers.contains(where: { (manualResolved[$0.id] ?? []).isEmpty }),
              Date().timeIntervalSince(lastResolveAttempt) >= Self.resolveRetryInterval
        else { return }
        resolveManualPeers()
    }

    /// Push the current selection into the allow-list, heartbeat tracking, and discovery
    /// unicast targets.
    private func applyPeerSelection() {
        var allowed: Set<UInt32> = []
        var tracked: [UDPEndpoint] = []
        var unicast: [UInt32] = []

        for peer in discovery.currentPeers {
            unicast.append(contentsOf: peer.addresses)
            // Selected if ANY of its addresses is — and then allow/track ALL of them: the
            // sender picks its own route, so audio can arrive from any of the peer's paths.
            if peer.addressStrings.contains(where: { selectedAddresses.contains($0) }) {
                allowed.formUnion(peer.addresses)
                for endpoint in peer.audioEndpoints where !tracked.contains(endpoint) {
                    tracked.append(endpoint)
                }
            }
        }
        for peer in manualPeers {
            for endpoint in manualResolved[peer.id] ?? [] {
                unicast.append(endpoint.address)
                if selectedAddresses.contains(endpoint.addressString) || selectedAddresses.contains(peer.host) {
                    allowed.insert(endpoint.address)
                    if !tracked.contains(endpoint) { tracked.append(endpoint) }
                }
            }
        }

        engine.setAllowedSenders(allowed)
        heartbeat.setTrackedPeers(tracked)
        discovery.setUnicastPeerAddresses(unicast)
    }

    // MARK: - Periodic refresh

    /// Report whether a UI is on screen (battery finding 2). iOS calls this from scenePhase
    /// (.active vs not); macOS from the main window's onAppear/onDisappear — the menu-bar
    /// label shows no controller state, so window-closed correctly means "not visible". While
    /// invisible the 1 Hz tick runs only its functional half; on becoming visible we run one
    /// immediate full refresh so the UI is never stale.
    public func setUIVisible(_ visible: Bool) {
        guard uiVisible != visible else { return }
        uiVisible = visible
        if visible { refreshNow() }
    }

    // Every published property this tick touches is assigned only when its value actually
    // changed. `@Observable` fires its mutation on the *write*, not on the change, so an
    // unguarded per-second assignment of an identical string wakes every view that reads it
    // 60 times a minute for nothing — `peers` in particular is rebuilt below even while the
    // app is backgrounded, which is where it spends most of its life.
    private func refreshNow() {
        guard isRunning else {
            refreshPeerList()
            if !connectionDetails.isEmpty { connectionDetails = [] }
            if !diagnosticDetails.isEmpty { diagnosticDetails = [] }
            if !trafficSummary.isEmpty { trafficSummary = "" }
            return
        }
        // Functional half — MUST run whether or not a UI is visible; this app spends most of
        // its life screen-locked, but cues, DNS retry, send-path health, and the IO-buffer
        // adaptation still have to work. refreshPeerList stays here (rather than with the
        // presentation steps as the audit first sketched) because updateCues/updateSendTargets
        // read `peers`, and rebuilding it is the cheapest way to keep that data fresh; it now
        // runs BEFORE updateCues so the cues see this-tick peers, not last-tick. updateCues
        // also fires the connect/lost VoiceOver announcements, which background screen-reader
        // users depend on, so it is never gated.
        retryUnresolvedPeersIfNeeded()
        refreshPeerList()
        updateCues()
        updateSendTargets()
        updateIOBufferDemand()
        // Functional, not presentational: the peak arrival gap is a read-and-reset value, so
        // sampling only while a UI is on screen would fold a whole backgrounded session into
        // the first sample and report it under a "last minute" label. This app is backgrounded
        // for most of its life — which is also exactly when the interesting network events
        // happen — so the window has to be kept regardless of visibility.
        samplePacketDiagnostics()

        // Presentation half — status-string building and @Observable churn the UI diffs.
        // Pure waste while nothing is on screen; setUIVisible(true) forces one immediate full
        // refresh so the UI never shows stale data on return.
        guard uiVisible else { return }
        updateSendStatus()
        updateSummary()
        updateConnectionDetails()
    }

    /// Battery (finding 1): the audio engine renders ~200×/s at the 5 ms low-latency IO
    /// buffer and is deliberately never stopped. When nothing is flowing — no playout
    /// session AND the mic is not capturing — that cadence is pure wakeup cost against a
    /// silent bus, so drop the callback rate; restore it the moment audio appears. Only the
    /// preferred IO buffer duration changes; the engine and audio session stay running
    /// throughout (locked decision). iOS-effective, a no-op on macOS.
    private func updateIOBufferDemand() {
        output.setLowLatencyDemand(mixer.activeSessionCount > 0 || microphone.isRunning)
    }

    // MARK: - Microphone sending

    private func startSending() {
        if !isRunning { start() } // the send path shares the receiver's socket
        guard isRunning else {
            sendEnabled = false
            return
        }
        MicrophoneCapture.requestPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self, self.sendEnabled else { return } // toggled off while prompted
                guard granted else {
                    self.sendEnabled = false
                    self.lastError = "Microphone access is not allowed. Enable it in system settings to send audio."
                    return
                }
                self.beginCapture()
            }
        }
    }

    private func beginCapture() {
#if os(iOS)
        output.setRecordingMode(true)
#endif
        // The record-capable session can expose inputs that .playback hid; re-list now
        // (the route-change notification usually also fires, but don't depend on it).
        refreshMicrophoneList()
        microphone.setPreferredInput(id: selectedMicrophoneId)
        sendEngine.start()
        updateSendTargets()
        do {
            try microphone.start()
            announce("Microphone sending started")
        } catch {
            sendEngine.stop()
#if os(iOS)
            output.setRecordingMode(false)
#endif
            sendEnabled = false
            lastError = "Could not start the microphone: \(error.localizedDescription)"
        }
        refreshNow()
    }

    private func stopSending() {
        let wasCapturing = microphone.isRunning
        microphone.stop()
        sendEngine.stop()
#if os(iOS)
        output.setRecordingMode(false)
#endif
        if wasCapturing { announce("Microphone sending stopped") }
        refreshNow()
    }

    /// One destination per selected peer — its healthiest heartbeat path, falling back to
    /// the primary address. Never more than one of a peer's addresses: sending the same
    /// stream down two paths would open two doubled-up sessions on its receiver.
    private func updateSendTargets() {
        guard sendEngine.isRunning else {
            sendTargetCount = 0
            return
        }
        let health = heartbeat.allPeerHealth()
        var targets: [UDPEndpoint] = []
        for entry in peers where entry.isSelected && !entry.audioEndpoints.isEmpty {
            if let best = bestHealth(for: entry.addresses, in: health), best.state == .healthy {
                targets.append(best.audioEndpoint)
            } else if let primary = entry.audioEndpoint {
                targets.append(primary)
            }
        }
        sendTargetCount = targets.count
        sendEngine.setTargets(targets)
    }

    private func refreshMicrophoneList() {
        let inputs = microphone.availableInputs()
        if inputs != availableMicrophones { availableMicrophones = inputs }
    }

    private func updateSendStatus() {
        let text: String
        if !sendEnabled {
            text = ""
        } else if password.isEmpty {
            text = "Set a password below to send — audio is always encrypted"
        } else if sendTargetCount == 0 {
            text = "No peers selected — tick a peer above to send to it"
        } else {
            var status = "Sending microphone audio to \(sendTargetCount) peer\(sendTargetCount == 1 ? "" : "s")"
            // Capture cadence diagnostic: ~5 ms = smooth packet pacing; ~100 ms would
            // mean burst sending is back (the receiving side would need a huge buffer).
            // Plain atomic read, NOT hardware polling (CLAUDE.md pitfall 6).
            let chunkMs = microphone.captureChunkMs
            if chunkMs > 0 {
                status += String(format: ". Capture chunk %.0f ms", chunkMs)
            }
            let dropped = microphone.captureDroppedFrames
            if dropped > 0 {
                status += ". \(dropped) capture frames dropped"
            }
            text = status
        }
        if text != sendStatus { sendStatus = text }
    }

    private func updateConnectionDetails() {
        var lines: [String] = []   // general status — always on screen
        var tech: [String] = []    // technical detail — behind the Diagnostics button

        // Connected = selected peers whose heartbeat is currently healthy, like Windows.
        // One line per selected peer ROW (a multi-homed peer is pinged on every path; show
        // the best), and the line set stays structurally stable from tick to tick — every
        // peer always gets a line, and the rate/buffer lines are always present — otherwise
        // the Form rows below shift every second and become impossible to tap.
        let health = heartbeat.allPeerHealth()
        let trackedEntries = peers.filter { $0.isSelected && !$0.audioEndpoints.isEmpty }
        let bests = trackedEntries.map { ($0, bestHealth(for: $0.addresses, in: health)) }
        let healthyCount = bests.filter { $0.1?.state == .healthy }.count
        if healthyCount == 0 {
            lines.append("Not connected to any peer")
        } else {
            lines.append("Connected to \(healthyCount) peer\(healthyCount == 1 ? "" : "s")")
        }
        for (entry, best) in bests {
            let status: String
            switch best?.state {
            case .healthy:
                if let rtt = best?.rttMs {
                    status = "ping \(rtt) ms"
                } else {
                    status = "ping pending"
                }
            case .stale: status = "connection unstable"
            case .unreachable: status = "not responding"
            case .unknown, nil: status = "waiting for a reply"
            }
            lines.append("\(entry.name): \(status)")
        }

        lines.append("Uptime: \(Self.formatDuration(engine.uptime))")

        // Per-second rates from the counter deltas since the previous tick. Bursty refreshes
        // (peer/session change callbacks) can land < 0.2 s apart — keep showing the last
        // computed rate then instead of dropping the line or resetting the baseline.
        let now = Date()
        let dt = now.timeIntervalSince(lastRateDate)
        let received = engine.bytesReceived
        let sent = engine.bytesSent
        if dt > 0.2 {
            lastRxRateKBs = max(0, Double(received - lastBytesReceived) / 1000.0 / dt)
            lastTxRateKBs = max(0, Double(sent - lastBytesSent) / 1000.0 / dt)
            lastBytesReceived = received
            lastBytesSent = sent
            lastRateDate = now
        }
        tech.append(String(format: "Receiving %.1f kB/s; sending %.1f kB/s", lastRxRateKBs, lastTxRateKBs))
        // Whole numbers for the spoken tab value — decimals are noise read aloud.
        let traffic = String(format: "Receiving %.0f kilobytes per second, sending %.0f kilobytes per second",
                             lastRxRateKBs, lastTxRateKBs)
        if traffic != trafficSummary { trafficSummary = traffic }
        tech.append(String(format: "Total received %.1f MB; sent %.1f MB",
                           Double(received) / 1_000_000, Double(sent) / 1_000_000))

        if mixer.activeSessionCount > 0 {
            tech.append(String(format: "Audio buffer %d ms; output latency %.0f ms",
                               mixer.currentBufferMs, output.reportedOutputLatencyMs))
        } else {
            // Whether audio is playing at all is general status, not diagnostics.
            lines.append("No audio playing")
        }

        // Glitch visibility: dropouts = the buffer ran dry mid-playback (network jitter
        // exceeded the buffered cushion); trims = the buffer overfilled past the jitter
        // margin and old audio was cut to bound latency. Reported over a sliding minute
        // so "is it glitching right now" is answerable from the panel, with VoiceOver.
        let totals = mixer.glitchTotals
        glitchSamples.append((time: now, underruns: totals.underruns, trims: totals.trims,
                              concealedMs: totals.concealedMs))
        glitchSamples.removeAll { now.timeIntervalSince($0.time) > 60 }
        if mixer.activeSessionCount > 0, let oldest = glitchSamples.first {
            let dropouts = totals.underruns - oldest.underruns
            let trims = totals.trims - oldest.trims
            if dropouts == 0 && trims == 0 {
                tech.append("No audio dropouts in the last minute")
            } else {
                tech.append("Last minute: \(dropouts) audio dropout\(dropouts == 1 ? "" : "s"), \(trims) buffer trim\(trims == 1 ? "" : "s")")
            }
            // Duration, not just frequency. Raising the buffer on a jittery link can leave the
            // dropout COUNT unchanged while making each one far shorter — a difference the
            // listener hears clearly and a count alone reports as "no improvement".
            let concealed = totals.concealedMs - oldest.concealedMs
            if concealed > 0 {
                tech.append("Silence inserted last minute: \(concealed) ms")
            }
        }

        appendTransportDiagnostics(to: &tech, now: now)
        appendNetworkDiagnostics(to: &tech)

        if lines != connectionDetails { connectionDetails = lines }
        if tech != diagnosticDetails { diagnosticDetails = tech }
    }

    /// The whole connection panel as pasteable plain text, with a timestamp and the app
    /// version so a pasted report is self-describing. The status and error lines come first
    /// because they are the context the numbers below only make sense against.
    public var connectionReport: String {
        var lines: [String] = ["RemSound connection details"]
        let stamp = DateFormatter()
        stamp.dateStyle = .medium
        stamp.timeStyle = .medium
        lines.append(stamp.string(from: Date()))
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String {
            let build = info?["CFBundleVersion"] as? String
            lines.append(build.map { "Version \(short) (build \($0))" } ?? "Version \(short)")
        }
        lines.append("")
        lines.append(statusSummary)
        if let lastError { lines.append("Error: \(lastError)") }
        lines.append("Maximum delay: \(targetLatencyMs) ms")
        lines.append("")
        lines.append(contentsOf: connectionDetails)
        return lines.joined(separator: "\n")
    }

    /// Put `connectionReport` on the system pasteboard. Announces on iOS because a copy
    /// produces no other feedback a screen-reader user can perceive.
    public func copyConnectionReport() {
        let text = connectionReport
#if os(iOS)
        UIPasteboard.general.string = text
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
        announce("Connection details copied")
    }

    /// Take one point of the sliding minute of packet counters. Called from the functional
    /// half of the refresh tick — see the note at the call site.
    private func samplePacketDiagnostics() {
        let now = Date()
        // Drained every tick: the peak is a since-last-read value, so a skipped read would
        // silently widen the window it represents.
        let peakGapMs = engine.diagnostics.drainPeakGapMs()
        let peakRenderGapMs = mixer.drainPeakRenderGapMs()
        packetSamples.append((time: now, stats: engine.diagnostics.snapshot(),
                              peakGapMs: peakGapMs, peakRenderGapMs: peakRenderGapMs))
        packetSamples.removeAll { now.timeIntervalSince($0.time) > 60 }

        // Feed the tuner's own history. Only while audio is actually flowing — a second with
        // no packets carries no timing information, and upstream skips those too.
        if mixer.activeSessionCount > 0 {
            autoTuneSamples.append(.init(arrivalGapMs: peakGapMs, renderGapMs: peakRenderGapMs))
            let excess = autoTuneSamples.count - LatencyAutoTune.historySeconds
            if excess > 0 { autoTuneSamples.removeFirst(excess) }
        }
        runAutoTuneIfDue(now: now)
    }

    /// Drive `LatencyAutoTune` on its interval. Runs in the functional half of the refresh
    /// tick — the whole point is that it works while the app is backgrounded, which is exactly
    /// when a mobile link misbehaves.
    private func runAutoTuneIfDue(now: Date) {
        // A new session invalidates the history: it may span a session boundary, and a
        // cross-session gap would recommend a target the new stream could never arm at.
        let opened = engine.sessionsOpenedCount
        if opened != lastSessionsOpenedCount {
            lastSessionsOpenedCount = opened
            autoTuneSamples = []
            lastUserLatencyChange = now
        }

        // The underrun baseline must track even while disabled, or enabling the tuner would
        // hand it a huge first delta and make it skip.
        let tuneBlocking = mixer.glitchTotals.tuneBlocking
        let underrunDelta = tuneBlocking - lastTuneBlockingUnderruns

        guard autoTuneLatencyEnabled else {
            lastTuneBlockingUnderruns = tuneBlocking
            return
        }
        let interval = TimeInterval(LatencyAutoTune.defaultIntervalSec)
        guard now.timeIntervalSince(lastAutoTuneRun) >= interval else { return }
        lastAutoTuneRun = now
        lastTuneBlockingUnderruns = tuneBlocking

        guard let frameMs = engine.activeStreamFrameMs else { return }

        let decision = LatencyAutoTune.decide(.init(
            samples: autoTuneSamples,
            frameMs: frameMs,
            currentTargetMs: targetLatencyMs,
            minTargetMs: ReceiverSettings.minTargetLatencyMs,
            maxTargetMs: ReceiverSettings.maxTargetLatencyMs,
            tuneBlockingUnderrunDelta: underrunDelta,
            deferring: now.timeIntervalSince(lastUserLatencyChange) < interval))

        let note: String
        switch decision {
        case .retarget(let ms):
            autoTuneIsMovingTarget = true
            targetLatencyMs = ms
            autoTuneIsMovingTarget = false
            note = "Auto-tune set the delay to \(ms) ms"
        case .hold(.underrunsSinceLastTick(let count)):
            note = "Auto-tune held at \(targetLatencyMs) ms (\(count) dropout\(count == 1 ? "" : "s") since the last check)"
        case .hold:
            note = "Auto-tune holding the delay at \(targetLatencyMs) ms"
        }
        // @Observable fires on the write, not on the change, and this runs while backgrounded.
        if note != lastAutoTuneNote { lastAutoTuneNote = note }
    }

    /// Packet-level lines: what the *network* did, as opposed to what the jitter buffer did.
    /// The two are routinely confused — a dropout counter alone cannot tell you whether
    /// packets were lost or merely arrived late, and the fixes differ completely (redundancy
    /// on the sender vs. a deeper buffer here).
    private func appendNetworkDiagnostics(to lines: inout [String]) {
        guard mixer.activeSessionCount > 0,
              let oldest = packetSamples.first, let latest = packetSamples.last else { return }
        let stats = latest.stats

        let received = stats.audioPacketsReceived - oldest.stats.audioPacketsReceived
        let lost = stats.packetsLost - oldest.stats.packetsLost
        let late = stats.packetsLate - oldest.stats.packetsLate
        let duplicate = stats.packetsDuplicate - oldest.stats.packetsDuplicate
        let expected = received + lost

        if expected > 0 {
            var parts = ["\(received) received"]
            let lossPercent = Double(lost) * 100 / Double(expected)
            parts.append(String(format: "%lld lost (%.2f%%)", lost, lossPercent))
            if late > 0 { parts.append("\(late) arrived late") }
            if duplicate > 0 { parts.append("\(duplicate) duplicated") }
            lines.append("Packets last minute: " + parts.joined(separator: ", "))
        }

        // Inter-arrival gaps are what the jitter buffer has to absorb: a gap longer than the
        // buffered cushion is a dropout no matter how little was lost.
        // Not a key path: Swift has no key paths into tuple elements.
        let windowPeak = packetSamples.map { $0.peakGapMs }.max() ?? 0
        if windowPeak > 0 {
            let over30 = stats.gapsOver30ms - oldest.stats.gapsOver30ms
            let over60 = stats.gapsOver60ms - oldest.stats.gapsOver60ms
            let over100 = stats.gapsOver100ms - oldest.stats.gapsOver100ms
            // Say which clock produced these. Timed on the receive thread they measure our
            // own scheduling as much as the network — under iOS background throttling a burst
            // of on-time packets reads as one huge gap.
            let clock = stats.usingKernelTimestamps ? "kernel-timed" : "thread-timed"
            lines.append("Packet timing last minute (\(clock)): longest gap \(windowPeak) ms; "
                         + "\(over30) over 30 ms, \(over60) over 60 ms, \(over100) over 100 ms")
            if windowPeak > targetLatencyMs {
                lines.append("The longest gap was larger than the \(targetLatencyMs) ms maximum delay, "
                             + "so the buffer could not cover it")
            }
            // The output device's own callback period is the OTHER half of the auto-tune's
            // recommendation, and a slow output can inflate the delay as much as the network
            // does. Shown so the target is decomposable into network vs device.
            let renderPeak = packetSamples.map { $0.peakRenderGapMs }.max() ?? 0
            if renderPeak > 0 {
                lines.append("Longest audio callback gap: \(renderPeak) ms")
            }
        }

        if stats.opusMode != .unknown {
            lines.append("Sender codec mode: Opus \(stats.opusMode.displayDescription)")
        }

        let decryptFailures = stats.decryptFailures - oldest.stats.decryptFailures
        if decryptFailures > 0 {
            lines.append("Packets that failed to decrypt last minute: \(decryptFailures)")
        }
        let resyncs = stats.resyncs - oldest.stats.resyncs
        if resyncs > 0 {
            lines.append("Sender stream restarts last minute: \(resyncs)")
        }
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min \(seconds) s" }
        return "\(seconds) seconds"
    }

    private func updateCues() {
        // Mirrors the Windows receiver's cue rule (upstream 2026-05-31 rewrite): connected
        // the moment audio arrives OR the heartbeat is solidly healthy; lost only when audio
        // has stopped AND the heartbeat has gone unreachable. Everything in between
        // (heartbeat stale, audio briefly paused) HOLDS the previous state — hysteresis, so
        // a two-second Wi-Fi/VPN stall never fires a false disconnect+connect cue pair.
        // Audio arrives hundreds of times a second, so a 3-second gap is a genuine
        // interruption, not jitter; the unreachable heartbeat (~5 s of no replies) is the
        // slower gate for a real, total loss.
        let audioWindow: TimeInterval = 3
        let health = heartbeat.allPeerHealth()
        var nowAudible: Set<UInt32> = []
        var seen: Set<UInt32> = []
        var connected: [UInt32] = []
        var lost: [UInt32] = []

        for entry in peers {
            guard entry.isSelected, let primary = entry.audioEndpoint else { continue }
            // Keyed by the stable primary address even when audio arrives on another path,
            // so a path switch doesn't fire a spurious disconnect+connect cue pair.
            let key = primary.address
            seen.insert(key)
            let audioFlowing = entry.addresses.contains {
                engine.isAudioFlowing(from: $0, within: audioWindow)
            }
            if audioFlowing { nowAudible.insert(key) }

            let state = bestHealth(for: entry.addresses, in: health)?.state ?? .unknown
            let isConnected = audioFlowing || state == .healthy
            let isLost = !audioFlowing && state == .unreachable
            let wasConnected = peerConnectedState[key] ?? false
            if isConnected && !wasConnected {
                connected.append(key)
                peerConnectedState[key] = true
            } else if isLost && wasConnected {
                lost.append(key)
                peerConnectedState[key] = false
            } else if peerConnectedState[key] == nil {
                // First sighting and neither clearly connected nor lost (address entered but
                // no audio or pong yet) — seed quietly. If it later goes unreachable without
                // ever connecting, that is a connect-FAILED event and stays silent too.
                peerConnectedState[key] = false
            }
        }

        // Peers that vanished from tracking entirely (deselected or expired): a disconnect
        // cue only if they were connected when last seen — one that never connected stays quiet.
        for (key, wasConnected) in peerConnectedState where !seen.contains(key) {
            if wasConnected { lost.append(key) }
            peerConnectedState.removeValue(forKey: key)
        }

        if !connected.isEmpty { cues.play(.connect) }
        if !lost.isEmpty { cues.play(.disconnect) }
        // "Connected"/"lost", not "receiving audio" — with the heartbeat leg of the rule, a
        // peer can be connected before (or without) sending any audio.
        for address in connected { announce("Connected to \(name(for: address))") }
        for address in lost { announce("Connection to \(name(for: address)) lost") }
        audibleAddresses = nowAudible
    }

    private func name(for address: UInt32) -> String {
        let addressString = UDPEndpoint(address: address, port: 0).addressString
        return peers.first { $0.addresses.contains(address) || $0.addressString == addressString }?.name
            ?? addressString
    }

    /// Best heartbeat result across a peer's addresses: healthiest state first, then lowest
    /// round trip.
    private func bestHealth(for addresses: [UInt32], in health: [PeerHealth]) -> PeerHealth? {
        health
            .filter { addresses.contains($0.audioEndpoint.address) }
            .min { (Self.healthRank($0.state), $0.rttMs ?? .max) < (Self.healthRank($1.state), $1.rttMs ?? .max) }
    }

    private static func healthRank(_ state: PeerHealthState) -> Int {
        switch state {
        case .healthy: return 0
        case .stale: return 1
        case .unknown: return 2
        case .unreachable: return 3
        }
    }

    /// Diagnostics for the headset / lock-screen transport. Deliberately reports the
    /// *absence* of a command too: "nothing has been routed to us" and "we were sent
    /// something and ignored it" look identical from the outside, and they need opposite
    /// fixes.
    private func appendTransportDiagnostics(to tech: inout [String], now: Date) {
        guard headsetTransportControls else {
            tech.append("Headset controls: off")
            return
        }
        if let command = remoteControls.lastCommand {
            let age = Int(now.timeIntervalSince(command.at).rounded())
            tech.append("Headset controls: last button was \(command.name), \(age) second\(age == 1 ? "" : "s") ago")
        } else {
            tech.append("Headset controls: on, no button press received yet")
        }
        if let event = lastAudioEvent {
            let age = Int(now.timeIntervalSince(event.at).rounded())
            tech.append("Audio engine: \(event.message), \(age) second\(age == 1 ? "" : "s") ago")
        }
    }

    private func announce(_ message: String) {
#if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: message)
#else
        // On macOS the menu-bar UI is transient; VoiceOver users get the cue sound plus the
        // status line. NSAccessibility announcements from a background LSUIElement app are
        // unreliable, so we rely on those instead.
#endif
    }

    private func refreshPeerList() {
        var entries: [PeerListEntry] = []
        var seenAddresses: Set<String> = []

        for peer in discovery.currentPeers {
            let selected = peer.addressStrings.contains { selectedAddresses.contains($0) }
            entries.append(PeerListEntry(
                id: "d-\(peer.instanceId)", // instanceId, NOT address — stable across path changes
                name: peer.name,
                addressString: peer.addressString,
                audioEndpoints: peer.audioEndpoints,
                source: .discovered,
                manualPeerId: nil,
                isSelected: selected,
                statusText: statusText(addresses: peer.addresses, selected: selected)))
            seenAddresses.formUnion(peer.addressStrings)
        }

        for peer in manualPeers {
            let resolved = manualResolved[peer.id] ?? []
            guard !resolved.isEmpty else {
                entries.append(PeerListEntry(
                    id: "m-\(peer.id)",
                    name: peer.displayName,
                    addressString: peer.host,
                    audioEndpoints: [],
                    source: .manual,
                    manualPeerId: peer.id,
                    isSelected: selectedAddresses.contains(peer.host),
                    statusText: isRunning ? "Resolving…" : "—"))
                continue
            }
            // Merged with a discovery row when any resolved address matches one.
            if resolved.contains(where: { seenAddresses.contains($0.addressString) }) { continue }
            let selected = selectedAddresses.contains(peer.host)
                || resolved.contains { selectedAddresses.contains($0.addressString) }
            entries.append(PeerListEntry(
                id: "m-\(peer.id)",
                name: peer.displayName,
                addressString: resolved[0].addressString,
                audioEndpoints: resolved,
                source: .manual,
                manualPeerId: peer.id,
                isSelected: selected,
                statusText: statusText(addresses: resolved.map(\.address), selected: selected)))
        }

        if entries != peers { peers = entries }
    }

    private func statusText(addresses: [UInt32], selected: Bool) -> String {
        guard isRunning else { return "—" }
        guard selected else { return "Not selected" }

        var parts: [String] = []
        let flowing = addresses.first { engine.isAudioFlowing(from: $0, within: 1.5) }
        if let flowing, let format = engine.activeFormat(from: flowing) {
            parts.append("Receiving \(format.codec == .opus ? "Opus" : "PCM") \(Int(format.frameDurationMs.rounded())) ms frames")
        } else {
            parts.append("No audio")
        }

        // Worst-news-first across the peer's paths: a mismatch on any of them matters more
        // than a clean link on another.
        let security = addresses.map { engine.peerSecurityStatus(address: $0) }
        if security.contains(.passwordMismatch) {
            parts.append("password does not match")
        } else if security.contains(.peerNeedsUpdate) {
            parts.append("peer app needs update")
        } else if security.contains(.secure) {
            parts.append("encrypted link")
        }

        let health = bestHealth(for: addresses, in: heartbeat.allPeerHealth())
        switch health?.state {
        case .healthy:
            if let rtt = health?.rttMs { parts.append("\(rtt) ms round trip") }
        case .stale: parts.append("connection unstable")
        case .unreachable: parts.append("unreachable")
        case .unknown, nil: break
        }
        return parts.joined(separator: ", ")
    }

    private func updateSummary() {
        let summary: String
        if !isRunning {
            summary = "Stopped"
        } else if !receiveEnabled {
            // Sending and peer connections keep working — say so instead of "Stopped".
            summary = "Receiving is off — peers stay connected"
        } else {
            let receivingCount = audibleAddresses.count
            if receivingCount > 0 {
                let buffer = mixer.currentBufferMs
                summary = "Receiving from \(receivingCount) peer\(receivingCount == 1 ? "" : "s") — buffer \(buffer) ms"
            } else if password.isEmpty {
                summary = "Listening — set a password to receive audio"
            } else {
                summary = "Listening on port \(settings.listenPort)"
            }
        }
        if summary != statusSummary { statusSummary = summary }
    }
}
