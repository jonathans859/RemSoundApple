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
    public let audioEndpoint: UDPEndpoint?
    public let source: Source
    public let manualPeerId: UUID?
    public var isSelected: Bool
    public var statusText: String
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

    public var volume: Float {
        didSet {
            mixer.volume = volume
            settings.volume = volume
        }
    }

    public var isMuted = false {
        didSet { mixer.isMuted = isMuted }
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
    private var mixer: PlayoutMixer { engine.mixer }

    private var manualPeers: [ManualPeer]
    private var selectedAddresses: Set<String>
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
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        lastError = nil
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
        if password.isEmpty { return }
        // PBKDF2 at 100k iterations takes ~50-100 ms — off the main actor.
        let pw = password
        Task.detached(priority: .userInitiated) { [engine] in
            engine.setPassword(pw)
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
        if selected {
            selectedAddresses.insert(entry.addressString)
        } else {
            selectedAddresses.remove(entry.addressString)
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
            unicast.append(peer.address)
            if selectedAddresses.contains(peer.addressString) {
                allowed.insert(peer.address)
                tracked.append(peer.audioEndpoint)
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
        updateSummary()
        updateConnectionDetails()
    }

    private func updateConnectionDetails() {
        var lines: [String] = []

        // Connected = selected peers whose heartbeat is currently healthy, like Windows.
        // The line set must stay structurally stable from tick to tick — every tracked peer
        // always gets a line, and the rate/buffer lines are always present — otherwise the
        // Form rows below shift every second and become impossible to tap.
        let health = heartbeat.allPeerHealth()
            .sorted { name(for: $0.audioEndpoint.address) < name(for: $1.audioEndpoint.address) }
        let healthyCount = health.filter { $0.state == .healthy }.count
        if healthyCount == 0 {
            lines.append("Not connected to any peer")
        } else {
            lines.append("Connected to \(healthyCount) peer\(healthyCount == 1 ? "" : "s")")
        }
        for peerHealth in health {
            let peerName = name(for: peerHealth.audioEndpoint.address)
            let status: String
            switch peerHealth.state {
            case .healthy: status = peerHealth.rttMs.map { "ping \($0) ms" } ?? "ping pending"
            case .stale: status = "connection unstable"
            case .unreachable: status = "not responding"
            case .unknown: status = "waiting for a reply"
            }
            lines.append("\(peerName): \(status)")
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
            guard let endpoint = entry.audioEndpoint, entry.isSelected else { continue }
            if engine.isAudioFlowing(from: endpoint.address, within: 1.5) {
                nowAudible.insert(endpoint.address)
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
        return peers.first { $0.addressString == addressString }?.name ?? addressString
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
            let selected = selectedAddresses.contains(peer.addressString)
            entries.append(PeerListEntry(
                id: "d-\(peer.addressString)",
                name: peer.name,
                addressString: peer.addressString,
                audioEndpoint: peer.audioEndpoint,
                source: .discovered,
                manualPeerId: nil,
                isSelected: selected,
                statusText: statusText(address: peer.address, selected: selected)))
            seenAddresses.insert(peer.addressString)
        }

        for peer in manualPeers {
            let resolved = manualResolved[peer.id] ?? []
            guard let endpoint = resolved.first else {
                entries.append(PeerListEntry(
                    id: "m-\(peer.id)",
                    name: peer.displayName,
                    addressString: peer.host,
                    audioEndpoint: nil,
                    source: .manual,
                    manualPeerId: peer.id,
                    isSelected: selectedAddresses.contains(peer.host),
                    statusText: isRunning ? "Resolving…" : "—"))
                continue
            }
            if seenAddresses.contains(endpoint.addressString) { continue } // merged with discovery row
            let selected = selectedAddresses.contains(endpoint.addressString) || selectedAddresses.contains(peer.host)
            entries.append(PeerListEntry(
                id: "m-\(peer.id)",
                name: peer.displayName,
                addressString: endpoint.addressString,
                audioEndpoint: endpoint,
                source: .manual,
                manualPeerId: peer.id,
                isSelected: selected,
                statusText: statusText(address: endpoint.address, selected: selected)))
        }

        peers = entries
    }

    private func statusText(address: UInt32, selected: Bool) -> String {
        guard isRunning else { return "—" }
        guard selected else { return "Not selected" }

        var parts: [String] = []
        if let format = engine.activeFormat(from: address), engine.isAudioFlowing(from: address, within: 1.5) {
            parts.append("Receiving \(format.codec == .opus ? "Opus" : "PCM") \(Int(format.frameDurationMs.rounded())) ms frames")
        } else {
            parts.append("No audio")
        }

        switch engine.peerSecurityStatus(address: address) {
        case .secure: parts.append("encrypted link")
        case .passwordMismatch: parts.append("password does not match")
        case .peerNeedsUpdate: parts.append("peer app needs update")
        case .unknown: break
        }

        let health = heartbeat.allPeerHealth().first { $0.audioEndpoint.address == address }
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
