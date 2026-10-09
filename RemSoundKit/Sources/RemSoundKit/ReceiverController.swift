import Foundation
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One row in the peer list — a discovered peer, a manual entry, both merged by address, or
/// somebody on a server.
public struct PeerListEntry: Identifiable, Hashable, Sendable {
    public enum Source: Sendable {
        case discovered
        case manual
        /// A person on a server, named by its member list. They have no address of their own
        /// — through a server everybody arrives from the server's address — so this row's
        /// endpoint is the stand-in the group client gave them, and it is never shown.
        case server
        /// The server's own ordinary pair slot: a phone or an older RemSound that knows
        /// nothing about groups, reached through the server exactly as it is today.
        case serverPair
    }

    public let id: String
    /// What to call this peer on screen: the user's own name for it when they set one,
    /// otherwise the name it announces (or its address, for a peer added by address).
    public let name: String
    /// The name the peer announces for itself; nil when it never announced one — a peer
    /// added by address, until discovery matches it. Shown in the rename UI as the name a
    /// custom one replaces, and what clearing the custom one falls back to.
    public let machineName: String?
    /// The user's own name for this peer, when they have set one (`name` already resolves
    /// to it). nil means the row is showing the peer's own name.
    public let customName: String?
    /// Key the custom name is stored under — see `PeerNameBook.identityKey`.
    public let identityKey: String
    /// What the peer announces it can do. nil for a peer added by address that discovery
    /// has not matched to an announcement yet — "we don't know", not "no".
    public let canSend: Bool?
    public let canReceive: Bool?
    public let addressString: String
    /// Every endpoint this peer is reachable at — multi-homed peers (LAN + VPN) have
    /// several. The first is the primary/display one. Empty while a manual host resolves.
    public let audioEndpoints: [UDPEndpoint]
    public let source: Source
    public let manualPeerId: UUID?
    public var isSelected: Bool
    public var statusText: String
    /// The member's client id, as hex, when this row is somebody on a server. nil otherwise.
    public let serverMemberId: String?
    /// For somebody on a server: whether the member list says they have ticked us back.
    /// nil when the question does not arise — on a network nobody can tell you, and the
    /// server's own pair partner cannot say (being given the slot beside us stands for it).
    public let ticksUs: Bool?

    public init(id: String, name: String, machineName: String?, customName: String?,
                identityKey: String, canSend: Bool?, canReceive: Bool?, addressString: String,
                audioEndpoints: [UDPEndpoint], source: Source, manualPeerId: UUID?,
                isSelected: Bool, statusText: String,
                serverMemberId: String? = nil, ticksUs: Bool? = nil) {
        self.id = id
        self.name = name
        self.machineName = machineName
        self.customName = customName
        self.identityKey = identityKey
        self.canSend = canSend
        self.canReceive = canReceive
        self.addressString = addressString
        self.audioEndpoints = audioEndpoints
        self.source = source
        self.manualPeerId = manualPeerId
        self.isSelected = isSelected
        self.statusText = statusText
        self.serverMemberId = serverMemberId
        self.ticksUs = ticksUs
    }

    public var audioEndpoint: UDPEndpoint? { audioEndpoints.first }
    var addresses: [UInt32] { audioEndpoints.map(\.address) }
    var allAddressStrings: [String] { audioEndpoints.map(\.addressString) }

    /// True for the two kinds of row that only exist while connected to a server.
    public var isOnServer: Bool { source == .server || source == .serverPair }

    /// What to call this peer when the user has no name of their own for it: the name it
    /// announces, else the best thing there is. Somebody on a server has no address to fall
    /// back on, so it must not be offered one.
    public var fallbackName: String {
        if let machineName = machineName { return machineName }
        switch source {
        case .server: return "the name they give on the server"
        case .serverPair: return "someone on a phone or an older app"
        case .discovered, .manual: return addressString
        }
    }

    /// What goes in `ReceiverSettings.selectedPeerAddresses` for this row. Somebody on a
    /// server has no address to key on, so their client id is the key — which is also what
    /// makes a tick outlive their restart, and ours.
    var selectionKeys: [String] {
        if let serverMemberId = serverMemberId {
            return [ReceiverController.serverSelectionKey(hex: serverMemberId)]
        }
        var keys = Set(allAddressStrings)
        keys.insert(addressString)
        return Array(keys)
    }
}

/// Somebody has ticked us and the user is being asked whether to tick them back — see
/// `ReceiverController.acceptPeerConnections`. One at a time, so the UI shows at most one.
public struct ConnectionRequest: Identifiable, Equatable, Sendable {
    /// The `PeerAcceptPolicy` key of the person asking — stable for as long as they are.
    public let id: String
    /// The whole question as one plain sentence, naming who it is and where they are.
    public let question: String
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
    /// The details panel behind each peer row's "Peer details" action, keyed by
    /// `PeerListEntry.id`: the peer's own name, addresses, how long it has been connected,
    /// link health, what it is sending, and whether our microphone reaches it. Rebuilt in
    /// the presentation half of the 1 Hz tick, like every other status string — the peer
    /// ROWS deliberately keep their one-line summary, so opening a peer is what costs the
    /// extra detail, exactly as the Diagnostics button does for the connection panel.
    public private(set) var peerDetails: [String: [String]] = [:]
    /// What the server connection is doing, as one plain sentence for the Connectivity tab.
    /// Empty when the user has never connected to one.
    public private(set) var serverStatus = ""
    /// The server address the user last typed, exactly as typed. The connect sheet starts
    /// from this.
    public private(set) var serverAddress = ""
    /// True from the moment the user asks to connect until they ask to leave — NOT the same
    /// as being in a group, which also needs a password and a member list.
    public private(set) var isConnectedToServer = false
    /// A member list has arrived in the last few seconds, so the server list is live and our
    /// audio is going out group-framed. Everything about groups hangs off this.
    public private(set) var isInServerGroup = false
    /// Servers used before, most recent first — what the sheet offers instead of retyping.
    public private(set) var recentServers: [String] = []
    /// The one-time note about a server only ever showing people on your own password: the
    /// one thing that surprises people, so it is said once, plainly, the first time.
    public private(set) var showServerPasswordNotice = false
    /// A peer the user added by address has turned out to be a server — it answered with an
    /// address-proof challenge, and nothing else sends one. The host they typed, so the UI
    /// can offer to connect to it as a server instead; nil once offered and dismissed.
    public private(set) var serverSuggestion: String?
    /// Somebody who has ticked us, waiting on the user's answer (ask mode only). The UI puts
    /// this up as a question and answers through `answerConnectionRequest`.
    public private(set) var pendingConnectionRequest: ConnectionRequest?
    /// Fired when a connection question goes up. The macOS app uses it to open its window:
    /// the question lives there, and a menu-bar app is usually running with it closed.
    public var onConnectionRequestPending: (@MainActor () -> Void)?
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
            // In the didSet, so the cue follows the state wherever it was moved from —
            // the toggle, the menu bar, a Shortcut, or a profile being applied.
            cues.play(sendEnabled ? .sendOn : .sendOff)
        }
    }

    /// Which codec the microphone stream uses — Opus (default, ~24 kB/s per peer) or raw
    /// PCM (~288 kB/s per peer). Persisted and part of a profile. Changing it while sending
    /// rotates the outbound stream identity inside the engine, so the peer opens a fresh
    /// session on the new format instead of format-changing the live one.
    public var sendCodec: AudioTransportCodec = .opus {
        didSet {
            guard sendCodec != oldValue else { return }
            settings.sendCodec = sendCodec
            sendEngine.setCodec(sendCodec)
            refreshNow()
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
            cues.play(receiveEnabled ? .receiveOn : .receiveOff)
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

    /// Whether the app may claim the system transport at all. On iOS that takes the
    /// exclusive session on top of the setting: a `.mixWithOthers` app is not eligible to be
    /// the Now Playing app, so with mixing on the press goes to whatever else is playing no
    /// matter what we register. macOS has no such rule.
    private var canClaimTransportControls: Bool {
#if os(iOS)
        headsetTransportControls && exclusiveAudio
#else
        headsetTransportControls
#endif
    }

    /// Claim or release the system transport, following the setting and whether the
    /// receiver is up at all. Idempotent — safe to call from either trigger.
    private func applyRemoteControls() {
        guard canClaimTransportControls, isRunning else {
            remoteControls.deactivate()
            return
        }
        remoteControls.activate()
        updateNowPlaying()
    }

    /// Re-stake the Now Playing claim after playback came back from something that had
    /// stopped it (see `AudioOutput.onPlaybackRecovered`).
    ///
    /// Whatever interrupted us — a podcast, a call, Music — became the Now Playing app while
    /// it played, and it keeps that slot after it stops: the next stem press then resumes
    /// *it*, not us. Until now the only way back was to foreground RemSound, which is what
    /// `RemoteTransportControls`' activation observer handles. This is the same move on the
    /// other edge that makes us eligible again — our own audio is playing through an
    /// exclusive session once more, which is the moment a re-publish can win the
    /// arbitration.
    ///
    /// Blind by necessity: there is no public API to ask who holds the slot, so this fires
    /// whether or not it was lost. That costs one XPC push on an edge that happens a handful
    /// of times an hour — nothing like the per-second cadence the change-gate exists to
    /// prevent. Whether the system actually hands it back is not documented; this is the
    /// only lever there is, hence the diagnostics line.
    private func reclaimTransportControls() {
        guard canClaimTransportControls, isRunning else { return }
        remoteControls.reassert()
        lastTransportReclaim = Date()
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

    /// One switch for every cue sound, not just the connect/disconnect pair it started as:
    /// receive on/off, send on/off, and profile saved ride it too (see `CuePlayer`).
    public var cuesEnabled: Bool {
        didSet {
            cues.enabled = cuesEnabled
            settings.cuesEnabled = cuesEnabled
        }
    }

    /// iOS: take sole control of audio (drop `.mixWithOthers`) so playback and the network
    /// survive the screen locking, at the cost of interrupting other apps' audio — and of
    /// being interrupted by theirs. Persisted, default on; a no-op on macOS.
    ///
    /// It gates the headset transport too: a mixable app is not eligible to be the Now
    /// Playing app, so the transport is released and re-claimed with this rather than left
    /// registered against a system that will never route a press to us.
    public var exclusiveAudio: Bool {
        didSet {
            guard exclusiveAudio != oldValue else { return }
            settings.exclusiveAudio = exclusiveAudio
            output.setExclusiveAudio(exclusiveAudio)
            applyRemoteControls()
        }
    }

    /// Let an AirPods stem press (or the Mac's media keys, or the lock-screen / Control
    /// Center transport) pause and resume receiving. Persisted, default on. Inactive on iOS
    /// while `exclusiveAudio` is off. See `RemoteTransportControls`.
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
            // A new password is a new group on the server, so the people we had ticked there
            // are people we can no longer see or hear. Their ids go with them.
            if password != oldValue { clearServerMemberSelections() }
        }
    }

    /// What happens when somebody else ticks us: ask (default), tick them back at once, or
    /// nothing until the user ticks them — the Windows "Accept connections from other peers".
    /// Device-local and not part of a profile, like upstream's machine-wide setting. Two
    /// things set it off: audio arriving from somebody we have not ticked (on a network,
    /// the only sign they have ticked us), and a server's member list saying so outright.
    /// Somebody on a different password is never offered — their audio could not be played.
    public var acceptPeerConnections: PeerAcceptMode {
        didSet {
            guard acceptPeerConnections != oldValue else { return }
            settings.acceptPeerConnections = acceptPeerConnections
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
    /// Being one of several people on a server. Dormant until `connectToServer` — a server
    /// is somewhere you go, not a peer that turns up.
    private let relayGroup: RelayGroupClient
    /// The resolved endpoint of `serverAddress`, once DNS has had a go at it.
    private var serverEndpoint: UDPEndpoint?
    private var serverResolveInFlight = false
    private var lastServerResolveAttempt = Date.distantPast
    /// True only while `applyProfile` is rewriting the live configuration — see there.
    private var applyingProfile = false
    /// The live password's 8-byte fingerprint, kept here because it is also the server's
    /// **group tag** — the server groups by it and nothing else. nil while there is no
    /// password, or while the first derivation is still running.
    private var currentFingerprint: [UInt8]?
    /// The live audio key, kept for tick proofs (`TickProof`) — sealing ours and opening
    /// theirs. nil exactly when `currentFingerprint` is.
    private var currentKey: [UInt8]?
    /// The last few things the server told us, newest last — surfaced in the Diagnostics
    /// panel so a group that will not form leaves a trail to read.
    private var serverLog: [String] = []
    private static let serverLogDepth = 12
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
    /// Keeps a selected peer's addresses in the allow-list for a while after discovery last
    /// saw them, so a missed burst of announcements cannot close a live stream (issue #8).
    private var allowGrace = SelectionGrace()
    /// Peers currently delivering audio, by row id — drives the "Receiving from N peers"
    /// summary.
    private var audiblePeerIds: Set<String> = []
    /// Connect/disconnect cue hysteresis, keyed by the peer's ROW ID rather than by any
    /// address — see `PeerCueTracker`.
    private var cueTracker = PeerCueTracker()
    /// The user's friendly names for peers, applied in `refreshPeerList`. Device-local and
    /// shared by every profile — see `PeerNameBook`.
    private var peerNames: PeerNameBook
    /// Who has been asked about this run, and who the user has deliberately unticked — see
    /// `PeerAcceptPolicy`. Run-scoped by design.
    private var acceptPolicy = PeerAcceptPolicy()
    /// What answering yes to `pendingConnectionRequest` does.
    private var pendingAcceptance: (@MainActor () -> Void)?
    /// Opens tick proofs and refuses a replayed one. See `TickProofGuard`.
    private var tickProofGuard = TickProofGuard()
    /// The peers we tell, every `TickProof.sendInterval`, that we have ticked them: every path
    /// of every ticked peer on a network — never a server, nor anybody reached through one
    /// (its member list already says who ticked whom). Rebuilt in `applyPeerSelection`.
    private var tickProofTargets: [UDPEndpoint] = []
    private var nextTickProof = Date.distantPast
    private var tickProofSequence: UInt32 = 0
    /// Every server we have been on this run. A server's address is never a person, even
    /// after we leave it — upstream accepted its own server as a peer once (Ed, 2026-10-01).
    private var knownServerAddresses: Set<UInt32> = []
    /// Every address the heartbeat pings, as of the last `applyPeerSelection` — "who we are
    /// talking to", for the address-check echo gate.
    private var pingedAddresses: Set<UInt32> = []
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

    /// Last time we re-published the Now Playing item to take the transport back after
    /// playback recovered. Diagnostics only — the reclaim is invisible when it fails (we
    /// cannot see who holds the slot), so at least the attempt is on the record.
    private var lastTransportReclaim: Date?

    public init() {
        // Startup profile (if configured): rewrite the persisted settings BEFORE they are
        // read below — rewriting-then-loading avoids every didSet/engine side effect.
        ProfileStore().applyStartupProfile(to: ReceiverSettings())

        // Picked once per install and kept: it is what makes us the same person in every
        // server's member list, so somebody else's tick survives our restart.
        relayGroup = RelayGroupClient(clientId: settings.relayClientId())
        manualPeers = settings.manualPeers
        selectedAddresses = settings.selectedPeerAddresses
        peerNames = PeerNameBook(settings.peerNames)
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
        sendCodec = settings.sendCodec
        password = settings.password
        exclusiveAudio = settings.exclusiveAudio
        headsetTransportControls = settings.headsetTransportControls
        acceptPeerConnections = settings.acceptPeerConnections
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
        // exclusive-audio and receive-playback choices into the services explicitly.
        output.setExclusiveAudio(exclusiveAudio)
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
        output.onPlaybackRecovered = { [weak self] in
            Task { @MainActor [weak self] in self?.reclaimTransportControls() }
        }

        engine.onHeartbeatReceived = { [heartbeat] payload, remote in
            heartbeat.handleHeartbeatPayload(payload, remote: remote)
        }

        // The server path. `rawTransport` deliberately bypasses routing: a hello and a bye
        // are already group-framed, and wrapping them a second time would make nonsense of
        // both. Everything else the app sends goes through `sendFromAudioSocket`, which asks
        // the group client what to do with it.
        relayGroup.rawTransport = { [engine] data, endpoint in
            engine.sendRawFromAudioSocket(data, to: endpoint)
        }
        relayGroup.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleServerEvent(event) }
        }
        engine.onAddrCheckReceived = { [weak self] endpoint in
            Task { @MainActor [weak self] in self?.noteAddressCheck(from: endpoint) }
        }
        engine.onUnselectedSenderHeard = { [weak self] remote, samePassword in
            Task { @MainActor [weak self] in
                self?.someoneWantsToConnect(from: remote, samePassword: samePassword)
            }
        }
        engine.onTickProofReceived = { [weak self] payload, remote in
            let bytes = Array(payload)
            Task { @MainActor [weak self] in self?.tickProofArrived(bytes[...], from: remote) }
        }
        relayGroup.onChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A member appearing or leaving changes who is allowed to be heard and who
                // our microphone reaches, exactly as a discovery change does.
                self.applyPeerSelection()
                self.refreshNow()
            }
        }
        engine.setRelayGroup(relayGroup)
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
        // didSet does not fire for the init assignment, so hand the engine the loaded codec.
        sendEngine.setCodec(sendCodec)
        // Refresh the picker's input list only when the hardware set actually changes —
        // NOT on the 1 Hz tick. Polling AVAudioSession / the Core Audio HAL every second
        // does audio-server IPC alongside live playback and audibly glitched it.
        microphone.onInputsChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.refreshMicrophoneList() }
        }
        selectedMicrophoneId = settings.selectedMicrophoneId
        microphone.setPreferredInput(id: selectedMicrophoneId)
        serverAddress = settings.serverHost
        recentServers = settings.recentServers
        showServerPasswordNotice = !settings.serverPasswordNoticeSeen

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
        // A server is somewhere you go, and the user left the app standing there. Not a
        // "remember", so returning at launch does not reorder the recents list.
        if settings.serverConnected, !settings.serverHost.isEmpty {
            connectToServer(host: settings.serverHost, remember: false)
        }

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
        // Say goodbye so the others see us go at once. The persisted intent is untouched:
        // the user has not left the server, the app has stopped.
        relayGroup.disconnect()
        isConnectedToServer = false
        isInServerGroup = false
        serverEndpoint = nil
        remoteControls.deactivate()
        output.stop()
        engine.stop()
        isRunning = false
        audiblePeerIds = []
        allowGrace.reset()
        cueTracker.reset() // cleared silently — the stop toggle is its own feedback
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
            // otherwise keep running on the previously derived key). And no group to join:
            // the server has nothing to group us by.
            engine.setKeyMaterial(key: nil, fingerprint: nil)
            sendEngine.setKeyMaterial(key: nil, fingerprint: nil)
            currentFingerprint = nil
            currentKey = nil
            relayGroup.setIdentity(name: Self.deviceName(), passwordFingerprint: nil)
            updateServerStatus()
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
                self.currentFingerprint = fingerprint
                self.currentKey = key
                // The same eight bytes are the server's group tag, so a password change is a
                // move to a different group: the client resends its hello at once with the
                // new tag and an empty tick list.
                self.relayGroup.setIdentity(name: Self.deviceName(), passwordFingerprint: fingerprint)
                self.updateServerStatus()
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

    // MARK: - Servers

    /// What a ticked server member is stored under in `selectedPeerAddresses`. Their client
    /// id, not an address: through a server everybody arrives from the server's address, and
    /// keying on the id is what makes a tick outlive their restart — and ours.
    /// `nonisolated`: a pure string, and `PeerListEntry` (not main-actor) builds it too.
    nonisolated public static func serverSelectionKey(hex: String) -> String { "server-member-\(hex)" }

    /// Go to a server. From then on we say hello to it every couple of seconds and the
    /// people on it who share our password appear in their own part of the peer list, to be
    /// ticked like anybody else.
    ///
    /// `remember` is false only when this is the app returning at launch to where the user
    /// left it — the recents list should not reorder itself just because the app restarted.
    public func connectToServer(host: String, remember: Bool = true) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !isRunning { start() } // the server path shares the receiver's one socket
        let changed = trimmed != serverAddress
        serverAddress = trimmed
        settings.serverHost = trimmed
        settings.serverConnected = true
        isConnectedToServer = true
        if changed { serverEndpoint = nil }
        if remember { rememberServer(trimmed) }
        // Said out loud the first time, not just written on the server screen: a screen-reader
        // user who connects straight from the list of servers they have used never arrows
        // past the note, and "why is this list empty?" is exactly the moment it answers.
        if remember, showServerPasswordNotice {
            markServerPasswordNoticeSeen()
            announce("Please note: on a server you only see and connect to people using the same password as yours.")
        }
        resolveServerIfNeeded(force: true)
        updateServerStatus()
        refreshNow()
    }

    /// Leave the server. The ticks are deliberately kept: a tick belongs to a person, not to
    /// a moment, so coming back here (or applying a profile that does) puts them straight
    /// back and they take effect the moment those people appear in the list again.
    public func disconnectFromServer() {
        guard isConnectedToServer else { return }
        settings.serverConnected = false
        isConnectedToServer = false
        isInServerGroup = false
        serverEndpoint = nil
        relayGroup.disconnect()
        applyPeerSelection()
        updateServerStatus()
        refreshNow()
        announce("Left the server")
    }

    /// An address-proof challenge arrived. **Only a server sends one**, so an address the
    /// user typed into the add-a-peer box which answers with a challenge is a server they
    /// have added as though it were a person — and a server is somewhere you go. Offer it.
    private func noteAddressCheck(from endpoint: UDPEndpoint) {
        guard serverSuggestion == nil, endpoint != serverEndpoint else { return }
        guard let peer = manualPeers.first(where: { candidate in
            (manualResolved[candidate.id] ?? []).contains { $0.address == endpoint.address }
        }) else { return }
        serverSuggestion = peer.host
    }

    /// "Not now" on the offer above. Not asked again this run.
    public func dismissServerSuggestion() {
        serverSuggestion = nil
    }

    /// The user has read the note about a server only ever showing people on their own
    /// password. Said once, like upstream's.
    public func markServerPasswordNoticeSeen() {
        guard showServerPasswordNotice else { return }
        settings.serverPasswordNoticeSeen = true
        showServerPasswordNotice = false
    }

    public func forgetServer(host: String) {
        recentServers.removeAll { $0.caseInsensitiveCompare(host) == .orderedSame }
        settings.recentServers = recentServers
    }

    private func rememberServer(_ host: String) {
        var list = recentServers.filter { $0.caseInsensitiveCompare(host) != .orderedSame }
        list.insert(host, at: 0)
        recentServers = Array(list.prefix(ReceiverSettings.maxRecentServers))
        settings.recentServers = recentServers
    }

    /// Resolve the server's address and hand it to the group client. A server is commonly a
    /// name (a MagicDNS name, a dynamic-DNS host), so this is the same blocking lookup the
    /// manual peers get, on the same detached task, with the same retry off the 1 Hz tick —
    /// an address typed before the tunnel is up heals itself.
    private func resolveServerIfNeeded(force: Bool = false) {
        guard isConnectedToServer, !serverAddress.isEmpty, !serverResolveInFlight else { return }
        guard force || serverEndpoint == nil,
              force || Date().timeIntervalSince(lastServerResolveAttempt) >= Self.resolveRetryInterval
        else { return }
        serverResolveInFlight = true
        lastServerResolveAttempt = Date()
        let host = serverAddress
        Task.detached { [weak self] in
            let endpoints = UDPEndpoint.resolve(host: host, port: RemPacket.defaultPort)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.serverResolveInFlight = false
                // The user may have left, or gone somewhere else, while this was in flight.
                guard self.isConnectedToServer, self.serverAddress == host else { return }
                guard let endpoint = endpoints.first else {
                    self.updateServerStatus()
                    return
                }
                self.serverEndpoint = endpoint
                self.knownServerAddresses.insert(endpoint.address)
                // Before the hello: the server's address check answers it.
                self.pushAddressCheckEchoTargets()
                self.relayGroup.setIdentity(name: Self.deviceName(),
                                            passwordFingerprint: self.currentFingerprint)
                self.relayGroup.connect(to: endpoint)
                self.applyPeerSelection()
                self.updateServerStatus()
                self.refreshNow()
            }
        }
    }

    private func handleServerEvent(_ event: RelayGroupEvent) {
        serverLog.append(event.message)
        if serverLog.count > Self.serverLogDepth { serverLog.removeFirst() }
        if let spoken = event.announcement { announce(spoken) }
        updateServerStatus()
        refreshNow()
    }

    private func updateServerStatus() {
        let joined = relayGroup.isInGroup
        if isInServerGroup != joined { isInServerGroup = joined }

        let text: String
        if !isConnectedToServer {
            text = serverAddress.isEmpty ? "" : "Not connected to a server"
        } else if serverEndpoint == nil {
            text = "Looking up \(serverAddress)…"
        } else if password.isEmpty {
            // The server groups by the password fingerprint and nothing else, so without one
            // there is nothing to join — and an empty list with no explanation is the worst
            // thing we could show here.
            text = "Connected to \(serverAddress), but a group needs a password. Set one in Send and Receive."
        } else if !joined {
            text = "Connected to \(serverAddress), waiting for its member list…"
        } else {
            let others = relayGroup.members.count
            var sentence = others == 0
                ? "On \(serverAddress). Nobody else here is using your password yet"
                : "On \(serverAddress) with \(others) other\(others == 1 ? "" : "s") on your password"
            if relayGroup.isPairedWithOrdinary {
                sentence += ", plus someone on a phone or an older app"
            }
            text = sentence
        }
        if text != serverStatus { serverStatus = text }
    }

    /// Drop every ticked server member. A new password is a new group, so the ids we were
    /// ticking belong to people we can no longer see or hear — upstream drops them for the
    /// same reason, and says so.
    private func clearServerMemberSelections() {
        guard !applyingProfile else { return }
        let before = selectedAddresses.count
        selectedAddresses = selectedAddresses.filter { !$0.hasPrefix("server-member-") }
        guard selectedAddresses.count != before else { return }
        settings.selectedPeerAddresses = selectedAddresses
        applyPeerSelection()
    }

    // MARK: - Peer selection

    /// The user ticking or unticking a row. An untick is a decision nothing may quietly undo
    /// (`PeerAcceptPolicy`): the person may still have us ticked, so their audio keeps
    /// arriving, and without remembering this automatic mode would tick them straight back.
    public func setPeerSelected(_ entry: PeerListEntry, selected: Bool) {
        if selected {
            acceptPolicy.userTicked(acceptKeys(for: entry))
        } else {
            acceptPolicy.userUnticked(acceptKeys(for: entry))
        }
        applySelection(entry, selected: selected)
        refreshNow()
    }

    /// Persist a row's tick and push it to the allow-list and the server. No refresh: the
    /// accept path runs inside the 1 Hz tick and must not re-enter it.
    private func applySelection(_ entry: PeerListEntry, selected: Bool) {
        // Select/deselect every address the peer is reachable at, plus the manual hostname
        // if there is one, so the choice survives path changes and re-resolution. A person on
        // a server has no address, so their row's key is their client id.
        var strings = Set(entry.selectionKeys)
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
    }

    // MARK: - Accepting connections

    /// The `PeerAcceptPolicy` keys a row answers to — what the user's untick refuses, and
    /// what a request from that person is asked under.
    private func acceptKeys(for entry: PeerListEntry) -> [String] {
        switch entry.source {
        case .server:
            return entry.serverMemberId.map { [PeerAcceptPolicy.memberKey(hex: $0)] } ?? []
        case .serverPair:
            return [PeerAcceptPolicy.pairKey(server: entry.addressString)]
        case .discovered, .manual:
            // Every path: a multi-homed peer unticked here must not get back in by sending on
            // its other address.
            return entry.allAddressStrings.map { PeerAcceptPolicy.networkKey(address: $0) }
        }
    }

    /// Somebody not ticked here is sending us audio on a network, so they have ticked us.
    private func someoneWantsToConnect(from remote: UDPEndpoint, samePassword: Bool) {
        guard samePassword else { return }
        considerAccepting(remote, row: nil)
    }

    /// A tick proof: somebody has ticked us and says they hold our password. If it opens
    /// with OUR key, they do — which covers the peer that only listens and so sends no
    /// format packet to prove it. Found as the very device the proof names (its discovery
    /// instance id), never merely by address: two phones can both be called "iPhone".
    private func tickProofArrived(_ payload: ArraySlice<UInt8>, from remote: UDPEndpoint) {
        guard isRunning, acceptPeerConnections != .manual, let key = currentKey else { return }
        guard case .accepted(let instanceId) = tickProofGuard.check(key: key, payload: payload,
                                                                    now: Date())
        else { return } // another password, stale, or replayed: never offered
        considerAccepting(remote, row: peers.first { $0.id == "d-\(instanceId)" })
    }

    /// The one decision both signs of a connection on a network come to: not a server, not
    /// already ticked, not unticked by the user — then the setting decides. `row` is the row
    /// the sign itself names, when it names one; otherwise the row at that address, if any.
    private func considerAccepting(_ remote: UDPEndpoint, row named: PeerListEntry?) {
        guard isRunning else { return }
        // A server's own address is not a person, whether or not we are on it now: the people
        // behind it arrive in its member list with names of their own, and its pair partner
        // is asked about from there.
        if knownServerAddresses.contains(remote.address)
            || serverEndpoint?.address == remote.address { return }
        if peers.contains(where: { $0.isOnServer && $0.addresses.contains(remote.address) }) { return }
        let address = remote.addressString
        let row = named ?? peers.first { !$0.isOnServer && $0.addresses.contains(remote.address) }
        if row?.isSelected == true || selectedAddresses.contains(address) { return }
        // Unticked by the user on ANY of its paths: a multi-homed peer must not get back in by
        // proving itself from its other address.
        if let row, acceptKeys(for: row).contains(where: { acceptPolicy.refusedByUser.contains($0) }) {
            return
        }

        let who = row.map { "\($0.name) at \(address)" } ?? address
        let rowId = row?.id
        // Asked about under the row's primary address when there is a row, so the two signs
        // and a peer's two paths are one question, not several.
        offerConnection(key: PeerAcceptPolicy.networkKey(address: row?.addressString ?? address),
                        question: "\(who) would like to connect to you.",
                        name: who) { [weak self] in
            self?.acceptNetworkPeer(rowId: rowId, address: address)
        }
    }

    /// Every few seconds, a sealed proof to each peer we have ticked on a network. Nothing
    /// without a password: there is nothing to prove. Functional half of the tick, so it
    /// keeps going with the screen locked — that is exactly when a phone is only listening.
    private func sendTickProofsIfDue() {
        guard isRunning, let key = currentKey, !tickProofTargets.isEmpty else { return }
        let now = Date()
        guard now >= nextTickProof else { return }
        nextTickProof = now.addingTimeInterval(TickProof.sendInterval)
        tickProofSequence &+= 1
        guard let packet = TickProof.buildPacket(key: key, instanceId: discovery.instanceId,
                                                 unixSeconds: Int64(now.timeIntervalSince1970),
                                                 sequence: tickProofSequence) else { return }
        // Raw: a proof never goes through a server's group framing.
        for target in tickProofTargets {
            engine.sendRawFromAudioSocket(packet, to: target)
        }
    }

    private func acceptNetworkPeer(rowId: String?, address: String) {
        // Looked up again: by the time a question is answered the row may have changed.
        if let entry = peers.first(where: { $0.id == rowId })
            ?? peers.first(where: { !$0.isOnServer && $0.allAddressStrings.contains(address) }) {
            applySelection(entry, selected: true)
            return
        }
        // Nobody we know, so they become what they are — a peer at an address (upstream
        // does the same). Ticked by its address, which is also the manual host.
        addManualPeer(host: address)
        selectedAddresses.insert(address)
        settings.selectedPeerAddresses = selectedAddresses
        applyPeerSelection()
    }

    /// The server's member list says who has ticked us, so there is no guessing on a server.
    /// Everybody listed is on our password by definition — the server groups by it. Runs in
    /// the functional half of the tick, so it works with the window closed or the screen locked.
    private func reviewServerTicks() {
        for entry in peers where entry.isOnServer && !entry.isSelected {
            let key: String
            switch entry.source {
            case .server:
                guard entry.ticksUs == true, let hex = entry.serverMemberId else { continue }
                key = PeerAcceptPolicy.memberKey(hex: hex)
            case .serverPair:
                // A phone or an older app cannot say it has ticked us; the server giving it
                // the slot beside us is the same statement, so it is asked about like anyone.
                key = PeerAcceptPolicy.pairKey(server: entry.addressString)
            case .discovered, .manual:
                continue
            }
            let rowId = entry.id
            offerConnection(key: key,
                            question: "\(entry.name) on the server would like to connect to you.",
                            name: entry.name) { [weak self] in
                guard let self, let current = self.peers.first(where: { $0.id == rowId }) else { return }
                self.applySelection(current, selected: true)
            }
        }
    }

    /// Act on the setting for one person. `accept` only changes the selection; the row
    /// list is rebuilt here so the rest of the tick sees the tick.
    private func offerConnection(key: String, question: String, name: String,
                                 accept: @escaping @MainActor () -> Void) {
        switch acceptPolicy.decide(key: key, mode: acceptPeerConnections,
                                   promptOpen: pendingConnectionRequest != nil) {
        case .ignore:
            return
        case .accept:
            accept()
            refreshPeerList()
            announce("Connected to \(name).")
        case .ask:
            pendingAcceptance = { [weak self] in
                accept()
                self?.announce("Connected to \(name).")
            }
            pendingConnectionRequest = ConnectionRequest(id: key, question: question)
            onConnectionRequestPending?()
        }
    }

    /// The user's answer to `pendingConnectionRequest`. Either way they are not asked about
    /// this person again this run — a "no" is remembered the same as a "yes".
    public func answerConnectionRequest(allow: Bool) {
        guard pendingConnectionRequest != nil else { return }
        let acceptance = pendingAcceptance
        pendingConnectionRequest = nil
        pendingAcceptance = nil
        guard allow else { return }
        acceptance?()
        refreshNow()
    }

    /// Give a peer a name of the user's choosing; nil or blank clears it back to the name
    /// the peer announces (upstream's Clear-custom-name button, and its empty-box
    /// equivalent). The name is stored against the peer's identity, not its address, so it
    /// survives the peer moving networks — and it is device-local and shared by every
    /// profile, exactly like the Windows named-peers book, so applying a profile never
    /// changes what a peer is called here.
    public func renamePeer(_ entry: PeerListEntry, to name: String?) {
        guard peerNames.set(name, for: entry.identityKey) else { return }
        settings.peerNames = peerNames.storage
        refreshNow()
        if let resolved = peerNames.name(for: entry.identityKey) {
            announce("Peer renamed to \(resolved)")
        } else {
            announce("Custom name cleared. This peer is now \(entry.fallbackName)")
        }
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
        cues.play(.profileSaved)
        announce("Profile \(trimmed) saved")
    }

    /// Overwrite an existing profile with the current configuration, keeping its name.
    public func updateProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index] = profileSnapshot(id: id, name: profiles[index].name)
        profileStore.setPassword(password, forProfile: id)
        profileStore.profiles = profiles
        markApplied(id) // now identical to the current configuration
        cues.play(.profileSaved)
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
        // The password's didSet drops ticked server members, because a new password really is
        // a new group — but during an apply that would eat the very ticks the profile has
        // just restored. Guarded rather than reordered: a later reshuffle of the assignments
        // below must not be able to bring the bug back.
        applyingProfile = true
        defer { applyingProfile = false }
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
        // Before the send switch below: the codec must be in place when capture starts, or
        // the first quarter-second of the stream announces the previous one.
        sendCodec = profile.sendCodec
        password = profileStore.password(forProfile: profile.id)
        receiveEnabled = profile.receiveEnabled
        // Send last: it may start the capture pipeline (microphone permission prompt
        // included), and by now the key material and peer selection it needs are in place.
        // Applying a profile is an explicit user tap, so a profile with sending on turning
        // the mic on here does not break the "mic never goes hot at launch" rule.
        sendEnabled = profile.sendEnabled
        // The server last, like the send switch: by now the password the group tag comes
        // from is in place, and the ticks restored above take effect the moment the member
        // list names those people — a tick belongs to a person, not to a moment.
        if let host = profile.serverHost, !host.isEmpty {
            connectToServer(host: host, remember: false)
        } else if isConnectedToServer {
            disconnectFromServer()
        }
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
            autoTuneLatencyEnabled: autoTuneLatencyEnabled,
            sendCodec: sendCodec,
            serverHost: isConnectedToServer && !serverAddress.isEmpty ? serverAddress : nil)
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

    /// Push the current selection into the allow-list, heartbeat tracking, discovery unicast
    /// targets, and the engine's address→peer grouping.
    private func applyPeerSelection() {
        var allowed: Set<UInt32> = []
        var tracked: [UDPEndpoint] = []
        var unicast: [UInt32] = []
        var groups: [UInt32: String] = [:]
        let now = Date()

        for peer in discovery.currentPeers {
            unicast.append(contentsOf: peer.addresses)
            // Which addresses are the same machine — the engine needs this to tell one peer
            // on two paths from two senders (issue #8). Keyed like `PeerListEntry.id`.
            let identity = "d-\(peer.instanceId)"
            for address in peer.addresses { groups[address] = identity }
            // Selected if ANY of its addresses is — and then allow/track ALL of them: the
            // sender picks its own route, so audio can arrive from any of the peer's paths.
            if peer.addressStrings.contains(where: { selectedAddresses.contains($0) }) {
                allowed.formUnion(peer.addresses)
                let selectionKeys = Set(peer.addressStrings)
                for endpoint in peer.audioEndpoints {
                    if !tracked.contains(endpoint) { tracked.append(endpoint) }
                    allowGrace.note(endpoint: endpoint, selectionKeys: selectionKeys,
                                    identity: identity, now: now)
                }
            }
        }
        for peer in manualPeers {
            let manualIdentity = "m-\(peer.id)"
            for endpoint in manualResolved[peer.id] ?? [] {
                unicast.append(endpoint.address)
                // A manual row that discovery has already matched keeps the announced
                // instance as its identity — same machine, one group.
                let identity = groups[endpoint.address] ?? manualIdentity
                groups[endpoint.address] = identity
                if selectedAddresses.contains(endpoint.addressString) || selectedAddresses.contains(peer.host) {
                    allowed.insert(endpoint.address)
                    if !tracked.contains(endpoint) { tracked.append(endpoint) }
                    allowGrace.note(endpoint: endpoint,
                                    selectionKeys: [endpoint.addressString, peer.host],
                                    identity: identity, now: now)
                }
            }
        }

        // A peer that is still streaming but whose announcements have gone quiet has just
        // aged out of `discovery.currentPeers` above — and dropping it from the allow-list
        // would close its live sessions. `SelectionGrace` holds its addresses eligible a
        // while longer; it says why.
        for grace in allowGrace.eligible(selected: selectedAddresses, now: now) {
            allowed.insert(grace.endpoint.address)
            if !tracked.contains(grace.endpoint) { tracked.append(grace.endpoint) }
            // Keep announcing to it too: over a tunnel our unicast is how it finds us again.
            if !unicast.contains(grace.endpoint.address) { unicast.append(grace.endpoint.address) }
            if groups[grace.endpoint.address] == nil { groups[grace.endpoint.address] = grace.identity }
        }

        // Everything tracked so far is a ticked peer on a network — exactly who our tick proofs
        // go to. Servers and the people behind them are added below and must not get one.
        tickProofTargets = tracked.filter {
            $0.address != serverEndpoint?.address && !knownServerAddresses.contains($0.address)
        }

        // People on a server. Each has a stand-in address of their own, which is what the
        // allow-list gates and the heartbeat pings; the tick itself goes to the server in
        // the hello, and that — not the allow-list — is what decides who hears whom, in both
        // directions, because the server passes nothing until each has ticked the other.
        var tickedMembers: Set<RelayClientId> = []
        for member in relayGroup.members {
            groups[member.endpoint.address] = "s-\(member.id.hex)"
            guard selectedAddresses.contains(Self.serverSelectionKey(hex: member.id.hex)) else { continue }
            tickedMembers.insert(member.id)
            allowed.insert(member.endpoint.address)
            if !tracked.contains(member.endpoint) { tracked.append(member.endpoint) }
        }

        // The server's ordinary pair slot, if we hold one: a phone or an older app whose
        // audio arrives from the server's OWN address in version-1 framing. Keyed by that
        // address, so a user who had already added the server as a peer and the row the
        // server list shows are one row with one tick, never the same person twice.
        var pairPartnerTicked = false
        if let serverEndpoint = self.serverEndpoint {
            // Heartbeats go to the server for as long as we are there, ticked partner or
            // not: the ordinary one is what claims a pair slot beside a phone that is
            // waiting for one, and it keeps the pinhole open either way.
            if !tracked.contains(serverEndpoint) { tracked.append(serverEndpoint) }
            if groups[serverEndpoint.address] == nil { groups[serverEndpoint.address] = "s-pair" }
            if relayGroup.isPairedWithOrdinary,
               selectedAddresses.contains(serverEndpoint.addressString) {
                pairPartnerTicked = true
                allowed.insert(serverEndpoint.address)
            }
        }
        relayGroup.setTicked(tickedMembers, pairPartner: pairPartnerTicked)

        engine.setPeerAddressGroups(groups)
        engine.setAllowedSenders(allowed)
        heartbeat.setTrackedPeers(tracked)
        discovery.setUnicastPeerAddresses(unicast)
        pingedAddresses = Set(tracked.map(\.address))
        pushAddressCheckEchoTargets()
    }

    /// Answer address checks from everyone we ping, and from the server we are on even in the
    /// moment before the first ping goes out — its check can beat our next selection pass, and
    /// since server-v2.13 an unanswered one keeps us out of every group.
    private func pushAddressCheckEchoTargets() {
        var targets = pingedAddresses
        if let serverEndpoint { targets.insert(serverEndpoint.address) }
        engine.setAddressCheckEchoTargets(targets)
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
            if !peerDetails.isEmpty { peerDetails = [:] }
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
        // The server's own clock: the hello when it is due, and noticing a server that has
        // stopped answering. No timer of its own — this tick is it.
        relayGroup.tick()
        resolveServerIfNeeded()
        refreshPeerList()
        reviewServerTicks()
        sendTickProofsIfDue()
        updateCues()
        updateSendTargets()
        updateIOBufferDemand()
        // Functional: the only way back from an interruption that ended without telling us,
        // or that ended while the interrupting app was still playing. Costs one session
        // property read per second, and only while playback is actually down.
        output.pollInterruptionRecovery()
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
        updateServerStatus()
        updateSummary()
        updateConnectionDetails()
        updatePeerDetails()
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
            // So the FIRST format packet already carries it; the tick below keeps it in step
            // with a capture graph the mic rebuilt under us (route change, device swap).
            sendEngine.setCaptureLatencyMs(microphone.reportedInputLatencyMs)
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
        sendEngine.setCaptureLatencyMs(0) // nothing open: the "no figure" value on both sides
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
        // A cached value the capture graph wrote at build time — a plain property read, NOT
        // hardware polling (pitfall 5). Pushed here because MicrophoneCapture rebuilds itself
        // on a route or device change, and the figure we announce must follow it.
        sendEngine.setCaptureLatencyMs(microphone.reportedInputLatencyMs)
        let health = heartbeat.allPeerHealth()
        var targets: [UDPEndpoint] = []
        var people = 0
        var needsServerCopy = false
        for entry in peers where entry.isSelected && !entry.audioEndpoints.isEmpty {
            people += 1
            // Everybody reached through a server shares ONE datagram: we send a single
            // group-framed copy to the server and it makes the copies, one per person due
            // it. A copy per person would put the same audio on our link N times and have
            // the server fan out every one of them.
            if entry.isOnServer {
                needsServerCopy = true
                continue
            }
            if let best = bestHealth(for: entry.addresses, in: health), best.state == .healthy {
                targets.append(best.audioEndpoint)
            } else if let primary = entry.audioEndpoint {
                targets.append(primary)
            }
        }
        if needsServerCopy, let serverEndpoint = self.serverEndpoint,
           !targets.contains(serverEndpoint) {
            targets.append(serverEndpoint)
        }
        // The count the status line reads is people, not datagrams.
        sendTargetCount = people
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
            var status = "Sending microphone audio to \(sendTargetCount) peer\(sendTargetCount == 1 ? "" : "s") as \(sendCodec.displayName)"
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

        if isConnectedToServer || !serverStatus.isEmpty {
            lines.append(serverStatus.isEmpty ? "Server: not connected" : "Server: \(serverStatus)")
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
        appendServerDiagnostics(to: &tech)
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
        var nowAudible: Set<String> = []
        var observations: [PeerCueTracker.Observation] = []

        for entry in peers {
            guard entry.isSelected, !entry.addresses.isEmpty else { continue }
            let audioFlowing = entry.addresses.contains {
                engine.isAudioFlowing(from: $0, within: audioWindow)
            }
            // Identified by the row id — the announced instance for a discovered peer, the
            // entry for a manual one — never by an address, which moves under a multi-homed
            // peer when one of its paths ages out of discovery (issue #8).
            if audioFlowing { nowAudible.insert(entry.id) }
            let state = bestHealth(for: entry.addresses, in: health)?.state ?? .unknown
            observations.append(PeerCueTracker.Observation(
                id: entry.id,
                name: entry.name,
                isConnected: audioFlowing || state == .healthy,
                isLost: !audioFlowing && state == .unreachable))
        }

        let transitions = cueTracker.update(observations)
        if !transitions.connected.isEmpty { cues.play(.connect) }
        if !transitions.lost.isEmpty { cues.play(.disconnect) }
        // "Connected"/"lost", not "receiving audio" — with the heartbeat leg of the rule, a
        // peer can be connected before (or without) sending any audio.
        for peerName in transitions.connected { announce("Connected to \(peerName)") }
        for peerName in transitions.lost { announce("Connection to \(peerName) lost") }
        audiblePeerIds = nowAudible
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
    /// What the server has been doing. Worth a panel of its own because a group that will
    /// not form is otherwise completely silent about why: a password that does not match
    /// anybody's, a full server, a member list that never arrives. The trail is what tells
    /// those three apart.
    private func appendServerDiagnostics(to tech: inout [String]) {
        guard isConnectedToServer || !serverLog.isEmpty else { return }
        if isConnectedToServer {
            tech.append("Server: \(serverAddress)\(serverEndpoint.map { " (\($0.addressString))" } ?? ", not resolved")")
            tech.append("Group: \(isInServerGroup ? "joined, member list arriving" : "not joined")")
            tech.append("Our id on the server: \(relayGroup.clientId.shortHex)")
            if relayGroup.isPairedWithOrdinary {
                tech.append("Also holding one of the server's ordinary pair slots")
            }
        }
        for line in serverLog.suffix(6) { tech.append("Server: \(line)") }
    }

    private func appendTransportDiagnostics(to tech: inout [String], now: Date) {
        guard headsetTransportControls else {
            tech.append("Headset controls: off")
            return
        }
#if os(iOS)
        // On but never claimed: worth saying out loud, because from the outside this looks
        // exactly like a press that was routed elsewhere by the system.
        guard exclusiveAudio else {
            tech.append("Headset controls: on, but inactive while RemSound mixes with other sounds")
            return
        }
#endif
        if let command = remoteControls.lastCommand {
            let age = Int(now.timeIntervalSince(command.at).rounded())
            tech.append("Headset controls: last button was \(command.name), \(age) second\(age == 1 ? "" : "s") ago")
        } else {
            tech.append("Headset controls: on, no button press received yet")
        }
        if let reclaim = lastTransportReclaim {
            let age = Int(now.timeIntervalSince(reclaim).rounded())
            tech.append("Headset controls: reclaimed after audio recovered, \(age) second\(age == 1 ? "" : "s") ago")
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

        // People on a server, first, because the manual loop below merges a row away when
        // one of these already covers its address. Nobody is ever typed in as one of these:
        // they arrive only from the server's member list, and they go when it stops saying
        // they are there.
        if let serverEndpoint = self.serverEndpoint {
            for member in relayGroup.members {
                let announced = member.name.isEmpty ? nil : member.name
                // Keyed on the announced name, like every other row, so one rename covers
                // the same machine whether it is reached over the network or through a
                // server; the client id is the key for a member nobody has named yet.
                let key = PeerNameBook.identityKey(machineName: announced,
                                                   fallback: "server-\(member.id.hex)")
                let custom = peerNames.name(for: key)
                let selected = selectedAddresses.contains(Self.serverSelectionKey(hex: member.id.hex))
                entries.append(PeerListEntry(
                    id: "s-\(member.id.hex)",
                    name: custom ?? announced ?? "Someone not yet named",
                    machineName: announced,
                    customName: custom,
                    identityKey: key,
                    canSend: nil, // a member list says who is there, not what they can do
                    canReceive: nil,
                    // Never the stand-in address: a person on a server has no address of
                    // their own, and showing a made-up one is a lie the user cannot check.
                    addressString: "on the server",
                    audioEndpoints: [member.endpoint],
                    source: .server,
                    manualPeerId: nil,
                    isSelected: selected,
                    statusText: statusText(addresses: [member.endpoint.address],
                                           selected: selected, ticksUs: member.ticksUs),
                    serverMemberId: member.id.hex,
                    ticksUs: member.ticksUs))
            }

            // The server's ordinary pair slot. A phone or an older RemSound knows nothing
            // about ticking and so can never say it has ticked us — being GIVEN the slot
            // beside us is the same statement, so it appears here and is ticked like anybody
            // else. Upstream did not do this at first and had an iPhone sit in the list
            // saying "connected" while playing nothing for two and a half minutes.
            if relayGroup.isPairedWithOrdinary {
                let key = PeerNameBook.identityKey(machineName: nil,
                                                   fallback: serverEndpoint.addressString)
                let custom = peerNames.name(for: key)
                let selected = selectedAddresses.contains(serverEndpoint.addressString)
                entries.append(PeerListEntry(
                    id: "s-pair",
                    name: custom ?? "Someone on a phone or an older app",
                    machineName: nil,
                    customName: custom,
                    identityKey: key,
                    canSend: nil,
                    canReceive: nil,
                    addressString: serverEndpoint.addressString,
                    audioEndpoints: [serverEndpoint],
                    source: .serverPair,
                    manualPeerId: nil,
                    isSelected: selected,
                    statusText: statusText(addresses: [serverEndpoint.address], selected: selected)))
                seenAddresses.insert(serverEndpoint.addressString)
            }
        }

        for peer in discovery.currentPeers {
            let selected = peer.addressStrings.contains { selectedAddresses.contains($0) }
            let machine = PeerNameBook.machineName(announced: peer.name, addressString: peer.addressString)
            let key = PeerNameBook.identityKey(machineName: machine, fallback: peer.addressString)
            let custom = peerNames.name(for: key)
            entries.append(PeerListEntry(
                id: "d-\(peer.instanceId)", // instanceId, NOT address — stable across path changes
                name: custom ?? peer.name,
                machineName: machine,
                customName: custom,
                identityKey: key,
                canSend: peer.canSend,
                canReceive: peer.canReceive,
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
            // A peer added by address announces no machine name, so its identity — and the
            // key its custom name hangs off — is the host the user typed, which is also the
            // thing that persists across launches.
            let key = PeerNameBook.identityKey(machineName: nil, fallback: peer.host)
            let custom = peerNames.name(for: key)
            guard !resolved.isEmpty else {
                entries.append(PeerListEntry(
                    id: "m-\(peer.id)",
                    name: custom ?? peer.displayName,
                    machineName: nil,
                    customName: custom,
                    identityKey: key,
                    canSend: nil,
                    canReceive: nil,
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
                name: custom ?? peer.displayName,
                machineName: nil,
                customName: custom,
                identityKey: key,
                canSend: nil,
                canReceive: nil,
                addressString: resolved[0].addressString,
                audioEndpoints: resolved,
                source: .manual,
                manualPeerId: peer.id,
                isSelected: selected,
                statusText: statusText(addresses: resolved.map(\.address), selected: selected)))
        }

        if entries != peers { peers = entries }
    }

    /// `ticksUs` applies only to somebody on a server, where the member list is the one
    /// place that difference is visible. nil means the question does not arise.
    private func statusText(addresses: [UInt32], selected: Bool, ticksUs: Bool? = nil) -> String {
        guard isRunning else { return "—" }
        guard selected else {
            // They have ticked us and we have not ticked back: the one case where an
            // unselected row is the user's move to make, so say so rather than just "no".
            return ticksUs == true
                ? "Not selected. They have ticked you — tick them back to hear each other"
                : "Not selected"
        }

        var parts: [String] = []
        let flowing = addresses.first { engine.isAudioFlowing(from: $0, within: 1.5) }
        if let flowing, let format = engine.activeFormat(from: flowing) {
            parts.append("Receiving \(format.codec == .opus ? "Opus" : "PCM") \(Int(format.frameDurationMs.rounded())) ms frames")
        } else {
            parts.append("No audio")
        }
        // Sound needs both ticks. Saying which half is missing is the whole reason the
        // member list carries a flag for it — silence with no explanation looks exactly
        // like a broken link, and it is the one thing a person cannot work out alone.
        if ticksUs == false { parts.append("waiting for them to tick you") }

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

    /// Rebuild the per-peer details panels. Cheap (a handful of peers, a few strings each)
    /// and confined to the presentation half of the tick — nothing reads these while no UI
    /// is on screen. The row summaries stay one line; this is the "open a peer to see
    /// everything" layer, the same split the Diagnostics button makes for the connection.
    private func updatePeerDetails() {
        let health = heartbeat.allPeerHealth()
        let now = Date()
        var details: [String: [String]] = [:]
        for entry in peers {
            details[entry.id] = peerDetailLines(for: entry, health: health, now: now)
        }
        if details != peerDetails { peerDetails = details }
    }

    /// The details of one peer as plain sentences — the Windows "Peer details" box
    /// (MainForm.BuildPeerDetailsText), adapted: the ASIO/WASAPI device breakdown has no
    /// meaning here (one mixed output), and the encryption state, which the Windows box does
    /// not carry, does — a password mismatch is the single most common reason a peer looks
    /// connected and stays silent.
    private func peerDetailLines(for entry: PeerListEntry, health: [PeerHealth], now: Date) -> [String] {
        var lines: [String] = []
        if let custom = entry.customName { lines.append("Name: \(custom)") }

        // Somebody on a server has no address of their own and no announcement behind them,
        // so the ordinary address lines would be a stand-in nobody can act on.
        if entry.isOnServer {
            if entry.source == .server {
                lines.append("Machine name: \(entry.machineName ?? "not named on the server yet")")
                lines.append("Reached through the server at \(serverAddress)")
                lines.append("Everyone on a server shares its address, so this person has none of their own")
                if entry.ticksUs == true {
                    lines.append("They have ticked you")
                } else if entry.ticksUs == false {
                    lines.append("They have not ticked you yet — sound needs both ticks, so there will be none until they do")
                }
            } else {
                lines.append("A phone or an older RemSound, paired with you through the server at \(serverAddress)")
                lines.append("Address: \(entry.addressString), the server's own — an older app cannot say it has ticked you, so holding the slot beside you stands for it")
            }
            lines.append(entry.isSelected ? "Selected: yes, audio from this person plays here"
                                          : "Selected: no, audio from this person is ignored")
            if let since = cueTracker.connectedSince(id: entry.id) {
                lines.append("Connected for: \(Self.formatDuration(now.timeIntervalSince(since)))")
            }
            let best = bestHealth(for: entry.addresses, in: health)
            switch best?.state {
            case .healthy:
                lines.append(best?.rttMs.map { "Link: healthy, round trip \($0) ms through the server" }
                    ?? "Link: healthy, round trip pending")
            case .stale: lines.append("Link: unstable, replies have stopped for a moment")
            case .unreachable: lines.append("Link: not responding")
            case .unknown: lines.append("Link: waiting for the first reply")
            case nil: lines.append("Link: not being checked, tick this person to connect to them")
            }
            lines.append("Sending: \(describeIncoming(from: entry))")
            if !sendEnabled {
                lines.append("Your microphone: not being sent, sending is off")
            } else if !entry.isSelected {
                lines.append("Your microphone: not sent to this person, they are not ticked")
            } else {
                lines.append("Your microphone: sent to the server for them as \(sendCodec.displayName)")
            }
            // Everyone in a group is on the same password by definition — the server groups
            // by its fingerprint — so there is nothing to warn about, only to confirm.
            lines.append("Encryption: everyone on a server group shares your password, so the link is encrypted")
            return lines
        }

        lines.append("Machine name: \(entry.machineName ?? "not announced, this peer was added by address")")

        if let primary = entry.audioEndpoint {
            lines.append("Address: \(primary.addressString), port \(primary.port)")
            // Multi-homed peers (LAN + Tailscale) are one row on purpose (pitfall 7); this is
            // the one place the other paths are actually visible.
            let others = entry.allAddressStrings.dropFirst()
            if !others.isEmpty {
                lines.append("Also reachable at: \(others.joined(separator: ", "))")
            }
        } else {
            lines.append("Address: \(entry.addressString), still being looked up")
        }
        lines.append(entry.source == .manual ? "Added by address" : "Found by network discovery")
        lines.append(entry.isSelected ? "Selected: yes, audio from this peer plays here"
                                      : "Selected: no, audio from this peer is ignored")

        if let since = cueTracker.connectedSince(id: entry.id) {
            lines.append("Connected for: \(Self.formatDuration(now.timeIntervalSince(since)))")
        }

        let best = bestHealth(for: entry.addresses, in: health)
        switch best?.state {
        case .healthy:
            lines.append(best?.rttMs.map { "Link: healthy, round trip \($0) ms" } ?? "Link: healthy, round trip pending")
        case .stale: lines.append("Link: unstable, replies have stopped for a moment")
        case .unreachable: lines.append("Link: not responding")
        case .unknown: lines.append("Link: waiting for the first reply")
        case nil: lines.append("Link: not being checked, select this peer to connect to it")
        }

        lines.append("Sending: \(describeIncoming(from: entry))")

        if !sendEnabled {
            lines.append("Your microphone: not being sent, sending is off")
        } else if !entry.isSelected {
            lines.append("Your microphone: not sent to this peer, it is not selected")
        } else if entry.canReceive == false {
            lines.append("Your microphone: sent, but this peer has receiving turned off")
        } else {
            lines.append("Your microphone: being sent to this peer as \(sendCodec.displayName)")
        }

        // Worst news first across the peer's paths, like the row summary.
        let security = entry.addresses.map { engine.peerSecurityStatus(address: $0) }
        if security.contains(.passwordMismatch) {
            lines.append("Encryption: the password does not match this peer's")
        } else if security.contains(.peerNeedsUpdate) {
            lines.append("Encryption: this peer runs an older RemSound that cannot encrypt")
        } else if security.contains(.secure) {
            lines.append("Encryption: the password matches, the link is encrypted")
        } else {
            lines.append("Encryption: not known yet, it shows once this peer sends audio")
        }

        return lines
    }

    /// What this peer is sending us, in words: the live stream's codec and format when audio
    /// is arriving, otherwise why there is nothing to describe.
    private func describeIncoming(from entry: PeerListEntry) -> String {
        let flowing = entry.addresses.first { engine.isAudioFlowing(from: $0, within: 3) }
        if let flowing, let format = engine.activeFormat(from: flowing) {
            let codec = format.codec == .opus ? "Opus" : "PCM"
            let channels: String
            switch format.channels {
            case 1: channels = "mono"
            case 2: channels = "stereo"
            default: channels = "\(format.channels) channels"
            }
            let frame = format.frameDurationMs
            let frameText = frame == frame.rounded() ? "\(Int(frame)) ms" : String(format: "%.1f ms", frame)
            return "\(codec), \(format.sampleRate) Hz, \(channels), \(frameText) frames"
        }
        if !receiveEnabled { return "turn Receive audio on to see what this peer is sending" }
        if entry.canSend == false { return "no, this peer has sending turned off" }
        if !entry.isSelected { return "not known, select this peer to hear it" }
        return "nothing is arriving right now"
    }

    /// One peer's details as pasteable text, self-describing like `connectionReport` — the
    /// thing to paste into an issue when a peer connects but stays silent.
    public func peerReport(for entry: PeerListEntry) -> String {
        var lines = ["RemSound peer details", entry.name]
        let stamp = DateFormatter()
        stamp.dateStyle = .medium
        stamp.timeStyle = .medium
        lines.append(stamp.string(from: Date()))
        lines.append("")
        lines.append(contentsOf: peerDetails[entry.id] ?? [])
        return lines.joined(separator: "\n")
    }

    /// Put `peerReport` on the system pasteboard. Announces on iOS for the same reason
    /// `copyConnectionReport` does: a copy produces no other perceivable feedback.
    public func copyPeerReport(for entry: PeerListEntry) {
        let text = peerReport(for: entry)
#if os(iOS)
        UIPasteboard.general.string = text
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
        announce("Peer details copied")
    }

    private func updateSummary() {
        let summary: String
        if !isRunning {
            summary = "Stopped"
        } else if !receiveEnabled {
            // Sending and peer connections keep working — say so instead of "Stopped".
            summary = "Receiving is off — peers stay connected"
        } else {
            let receivingCount = audiblePeerIds.count
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
