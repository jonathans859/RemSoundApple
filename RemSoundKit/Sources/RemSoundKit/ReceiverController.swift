import Foundation
import Observation
#if os(iOS)
import UIKit
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

/// App-facing coordinator: owns the engine, audio output, discovery, heartbeat, and cues;
/// publishes UI state. All published state is touched on the main actor; the underlying
/// services run on their own threads and are polled / event-driven into main-actor updates.
@MainActor
@Observable
public final class ReceiverController {
    // Published state
    public private(set) var peers: [PeerListEntry] = []
    public private(set) var statusSummary = "Stopped"
    public private(set) var isRunning = false
    public private(set) var lastError: String?
    /// Windows-style connection details ("Connected to 1 peer", per-peer ping, uptime,
    /// rates, totals, buffer/output latency), refreshed once a second.
    public private(set) var connectionDetails: [String] = []
    /// Inputs the user can pick for microphone sending. Refreshed when the hardware set
    /// changes (route change / device list notifications), at start, and on send start —
    /// never on a timer; enumeration IPC alongside live playback causes audible glitches.
    public private(set) var availableMicrophones: [AudioInputDevice] = []
    /// Plain-sentence state of the send path ("Sending microphone audio to 1 peer").
    public private(set) var sendStatus = ""

    /// Microphone sending on/off. Deliberately NOT persisted — the microphone never goes
    /// hot just because the app launched; the user flips it each session.
    public var sendEnabled = false {
        didSet {
            guard sendEnabled != oldValue else { return }
            if sendEnabled { startSending() } else { stopSending() }
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

    public var targetLatencyMs: Int {
        didSet {
            mixer.setTargetLatencyMs(targetLatencyMs)
            settings.targetLatencyMs = targetLatencyMs
        }
    }

    public var cuesEnabled: Bool {
        didSet {
            cues.enabled = cuesEnabled
            settings.cuesEnabled = cuesEnabled
        }
    }

    public var password: String {
        didSet {
            settings.password = password
            applyPassword()
        }
    }

    // Services
    private let settings = ReceiverSettings()
    private let engine = AudioReceiverEngine()
    private let output: AudioOutput
    private let discovery = PeerDiscoveryService()
    private let heartbeat = HeartbeatService()
    private let cues = CuePlayer()
    private let sendEngine = AudioSendEngine()
    private let microphone = MicrophoneCapture()
    private var sendTargetCount = 0
    private var mixer: PlayoutMixer { engine.mixer }

    private var manualPeers: [ManualPeer]
    private var selectedAddresses: Set<String>
    /// Monotonic token guarding async PBKDF2 results — see `applyPassword`.
    private var passwordGeneration = 0
    /// Resolved IPv4 addresses (network byte order) per manual peer id.
    private var manualResolved: [UUID: [UDPEndpoint]] = [:]
    /// Addresses currently delivering audio — drives connect/disconnect cues.
    private var audibleAddresses: Set<UInt32> = []
    private var refreshTask: Task<Void, Never>?

    // Previous traffic-counter snapshot for the per-second rate lines.
    private var lastBytesReceived: Int64 = 0
    private var lastBytesSent: Int64 = 0
    private var lastRateDate = Date()
    private var lastRxRateKBs = 0.0
    private var lastTxRateKBs = 0.0

    // Sliding window of cumulative glitch totals for the "last minute" connection line.
    private var glitchSamples: [(time: Date, underruns: Int64, trims: Int64)] = []

    public init() {
        manualPeers = settings.manualPeers
        selectedAddresses = settings.selectedPeerAddresses
        volume = settings.volume
        targetLatencyMs = settings.targetLatencyMs
        cuesEnabled = settings.cuesEnabled
        password = settings.password
        output = AudioOutput(mixer: engine.mixer)

        mixer.volume = volume
        mixer.setTargetLatencyMs(targetLatencyMs)
        cues.enabled = cuesEnabled

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
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        lastError = nil
        glitchSamples = []
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
        isRunning = true
        applyPeerSelection()
        resolveManualPeers()

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshNow()
            }
        }
        refreshNow()
    }

    public func stop() {
        if sendEnabled { sendEnabled = false } // didSet stops capture + send engine
        refreshTask?.cancel()
        refreshTask = nil
        discovery.stop()
        heartbeat.stop()
        output.stop()
        engine.stop()
        isRunning = false
        audibleAddresses = []
        statusSummary = "Stopped"
        connectionDetails = []
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

    private func resolveManualPeers() {
        let peersToResolve = manualPeers
        Task.detached { [weak self] in
            var resolved: [UUID: [UDPEndpoint]] = [:]
            for peer in peersToResolve {
                resolved[peer.id] = UDPEndpoint.resolve(host: peer.host, port: peer.port)
            }
            let result = resolved
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.manualResolved = result
                self.applyPeerSelection()
                self.refreshNow()
            }
        }
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

    private func refreshNow() {
        guard isRunning else {
            refreshPeerList()
            connectionDetails = []
            return
        }
        updateCues()
        refreshPeerList()
        updateSendTargets()
        updateSendStatus()
        updateSummary()
        updateConnectionDetails()
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
        guard sendEnabled else {
            sendStatus = ""
            return
        }
        if password.isEmpty {
            sendStatus = "Set a password below to send — audio is always encrypted"
        } else if sendTargetCount == 0 {
            sendStatus = "No peers selected — tick a peer above to send to it"
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
            sendStatus = status
        }
    }

    private func updateConnectionDetails() {
        var lines: [String] = []

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
        lines.append(String(format: "Receiving %.1f kB/s; sending %.1f kB/s", lastRxRateKBs, lastTxRateKBs))
        lines.append(String(format: "Total received %.1f MB; sent %.1f MB",
                            Double(received) / 1_000_000, Double(sent) / 1_000_000))

        if mixer.activeSessionCount > 0 {
            lines.append(String(format: "Audio buffer %d ms; output latency %.0f ms",
                                mixer.currentBufferMs, output.reportedOutputLatencyMs))
        } else {
            lines.append("No audio playing")
        }

        // Glitch visibility: dropouts = the buffer ran dry mid-playback (network jitter
        // exceeded the buffered cushion); trims = the buffer overfilled past the jitter
        // margin and old audio was cut to bound latency. Reported over a sliding minute
        // so "is it glitching right now" is answerable from the panel, with VoiceOver.
        let totals = mixer.glitchTotals
        glitchSamples.append((time: now, underruns: totals.underruns, trims: totals.trims))
        glitchSamples.removeAll { now.timeIntervalSince($0.time) > 60 }
        if mixer.activeSessionCount > 0, let oldest = glitchSamples.first {
            let dropouts = totals.underruns - oldest.underruns
            let trims = totals.trims - oldest.trims
            if dropouts == 0 && trims == 0 {
                lines.append("No audio dropouts in the last minute")
            } else {
                lines.append("Last minute: \(dropouts) audio dropout\(dropouts == 1 ? "" : "s"), \(trims) buffer trim\(trims == 1 ? "" : "s")")
            }
        }

        connectionDetails = lines
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
        var nowAudible: Set<UInt32> = []
        for entry in peers {
            guard entry.isSelected, let primary = entry.audioEndpoint else { continue }
            // Keyed by the stable primary address even when audio arrives on another path,
            // so a path switch doesn't fire a spurious disconnect+connect cue pair.
            if entry.addresses.contains(where: { engine.isAudioFlowing(from: $0, within: 1.5) }) {
                nowAudible.insert(primary.address)
            }
        }
        let appeared = nowAudible.subtracting(audibleAddresses)
        let disappeared = audibleAddresses.subtracting(nowAudible)
        if !appeared.isEmpty { cues.play(.connect) }
        if !disappeared.isEmpty { cues.play(.disconnect) }
        for address in appeared { announce("Receiving audio from \(name(for: address))") }
        for address in disappeared { announce("Audio from \(name(for: address)) stopped") }
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

        peers = entries
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
        if !isRunning {
            statusSummary = "Stopped"
            return
        }
        let receivingCount = audibleAddresses.count
        if receivingCount > 0 {
            let buffer = mixer.currentBufferMs
            statusSummary = "Receiving from \(receivingCount) peer\(receivingCount == 1 ? "" : "s") — buffer \(buffer) ms"
        } else if password.isEmpty {
            statusSummary = "Listening — set a password to receive audio"
        } else {
            statusSummary = "Listening on port \(settings.listenPort)"
        }
    }
}
