import Foundation
import os

/// The receiver pipeline façade, mirroring the Windows `AudioReceiver`: owns the single UDP
/// socket on the audio port, routes packets to one `StreamSession` per (endpoint, streamId),
/// gates on the selected-peers allow-list, tracks per-peer security status from format-packet
/// fingerprints, and prunes idle sessions. Heartbeat packets are forwarded out via a hook
/// (single-port model — heartbeats share the audio socket).
public final class AudioReceiverEngine {
    public static let sessionIdleTimeout: TimeInterval = 4
    public static let maxLiveSessions = 32
    /// How long a path of a multi-homed peer must go silent before another path of the SAME
    /// peer may take its lane over (issue #8). Long enough that ordinary jitter never hands
    /// the lane back and forth, far shorter than `sessionIdleTimeout`, so a genuine path
    /// failover costs about a second rather than four.
    public static let pathHandoverSilence: TimeInterval = 1

    private let lock = NSLock()
    private var sessions: [SessionKey: StreamSession] = [:]
    private let decryptor = AudioDecryptor()
    private var socket: UDPSocket?
    private var pruneTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "RemSound.ReceiverMaintenance")

    /// Mix bus the audio output pulls from.
    public let mixer = PlayoutMixer()

    /// Packet-level telemetry (loss, reordering, inter-arrival gaps, the sender's Opus mode),
    /// aggregated across every session so the numbers survive streamId rotation and pruning.
    public let diagnostics = StreamDiagnostics()

    private struct SessionKey: Hashable {
        let endpoint: UDPEndpoint
        let streamId: UInt16
    }

    // Pushed by the app; read on the network thread.
    private var audioKey: [UInt8]?
    private var audioFingerprint: [UInt8]?
    /// nil = no filter (diagnostics only); empty = block everyone. Compared by IP only —
    /// incoming packets carry the sender's ephemeral source port, not its audio port.
    private var allowedSenderAddresses: Set<UInt32>?

    private var peerSecurity: [UInt32: PeerSecurityStatus] = [:]

    /// Address → peer identity, pushed by the app from discovery (issue #8). Without it the
    /// engine has no way to tell "the same machine on its LAN and its VPN address" from "two
    /// different senders", and a sender aimed at both addresses of one receiver gets its
    /// audio decoded twice and summed against itself at two path delays — comb filtering that
    /// sounds like a bad link rather than like an echo. Addresses absent from the map fall
    /// back to standing alone, which is exactly the old behaviour.
    private var peerIdentityByAddress: [UInt32: String] = [:]

    /// Group membership on a RemSound server, when the user has connected to one. It turns a
    /// group-framed packet into an ordinary one from the member who sent it, and sends what
    /// we address to a member through the server instead. nil (the default) is the
    /// pre-groups behaviour exactly.
    private var relayGroup: RelayGroupClient?
    /// Paths currently refused because another path of the same peer is carrying the lane.
    /// Only here to keep the diagnostic from repeating four times a second — the sender
    /// re-announces its format every 250 ms.
    private var suppressedDuplicatePaths: Set<SessionKey> = []

    public private(set) var bytesReceived: Int64 = 0
    public private(set) var bytesSent: Int64 = 0
    private var startDate: Date?

    /// Time since the listener was started, for the status panel.
    public var uptime: TimeInterval {
        startDate.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Heartbeat packets arriving on the audio socket land here, as the payload after the
    /// header and the peer they came from. A payload rather than the raw datagram because a
    /// heartbeat relayed through a server arrives group-framed, with 16 bytes of client id
    /// between the header and the payload, and `remote` is then that member's stand-in
    /// address rather than the server's. Wire BEFORE start().
    public var onHeartbeatReceived: ((_ payload: ArraySlice<UInt8>, _ remote: UDPEndpoint) -> Void)?
    /// Fired when a session opens/closes — drives UI refresh and connect/disconnect cues.
    public var onSessionsChanged: (() -> Void)?
    /// An address-proof challenge arrived from this endpoint (and has just been echoed).
    /// **Only a server sends one**, which is how the app can tell a user who typed a
    /// server's address into the add-a-peer box what they have actually got.
    public var onAddrCheckReceived: ((UDPEndpoint) -> Void)?
    /// Somebody we have NOT ticked is sending us audio, which means they have ticked us —
    /// the only signal there is on a network that somebody wants to connect, and what the
    /// "Accept connections from other peers" setting acts on (upstream
    /// `OnUnselectedSenderHeard`). The flag is whether the password fingerprint in their
    /// format packet is ours; false also when either side has no password, or the sender is
    /// too old to say. Fired on the network thread, at most once per
    /// `unselectedSenderInterval` for any one address, so a peer left sending cannot turn
    /// into a stream of questions. Wire BEFORE start().
    public var onUnselectedSenderHeard: ((_ remote: UDPEndpoint, _ samePassword: Bool) -> Void)?
    /// A tick proof (type 11) arrived, unopened — the app holds the key and the replay memory.
    /// At most one per address every `tickProofInterval` reaches it (a peer sends one every
    /// five), so a flood costs a dictionary lookup here, not a decryption there. Network thread.
    public var onTickProofReceived: ((_ payload: ArraySlice<UInt8>, _ remote: UDPEndpoint) -> Void)?
    public var onDiagnostic: ((String) -> Void)?

    public static let tickProofInterval: TimeInterval = 2
    /// Last tick proof passed on per address, under `lock`.
    private var tickProofNoted: [UInt32: Date] = [:]

    /// Addresses we answer address checks for — everyone we ping. nil answers everybody, which
    /// is only ever the state before the app has said who it talks to. Under `lock`.
    private var addrCheckEchoTargets: Set<UInt32>?
    /// Last address check handled per endpoint, under `lock`: at most one a second each.
    private var addrCheckLast: [UDPEndpoint: Date] = [:]
    public static let addrCheckInterval: TimeInterval = 1

    public static let unselectedSenderInterval: TimeInterval = 10
    /// Last report per address, under `lock`.
    private var unselectedSenderNoted: [UInt32: Date] = [:]

    /// Gate equivalent to the Windows "Receive audio" tick: when false the socket stays
    /// bound (heartbeats keep flowing) but Format/Audio packets are discarded pre-decode.
    /// Read on the network thread under `lock`; set via `setPlaybackEnabled`.
    private var playbackEnabled = true

    public init() {}

    // MARK: - Configuration

    public func setPassword(_ password: String) {
        let key = RemSoundCrypto.deriveKey(password: password)
        let fingerprint = RemSoundCrypto.fingerprint(password: password)
        setKeyMaterial(key: key, fingerprint: fingerprint)
    }

    /// Push pre-derived key material — lets the app run PBKDF2 once and share the result
    /// with the send engine instead of paying the ~100 ms derivation twice.
    public func setKeyMaterial(key: [UInt8]?, fingerprint: [UInt8]?) {
        lock.lock()
        audioKey = key
        audioFingerprint = fingerprint
        lock.unlock()
    }

    /// Mirrors Windows `AudioReceiver.SetPlaybackEnabled` (single-port model): disabling
    /// flips the gate FIRST — so in-flight packets on the network thread can't open a fresh
    /// session mid-teardown — then disposes every open session, so a later re-enable starts
    /// clean instead of draining stale audio. The socket and heartbeat routing are untouched.
    public func setPlaybackEnabled(_ enabled: Bool) {
        var closed: [StreamSession] = []
        lock.lock()
        let changed = playbackEnabled != enabled
        playbackEnabled = enabled
        if changed && !enabled {
            closed = Array(sessions.values)
            sessions.removeAll()
            suppressedDuplicatePaths.removeAll()
        }
        lock.unlock()
        guard changed else { return }
        for session in closed {
            mixer.removeSession(endpoint: session.endpoint, streamId: session.streamId)
        }
        onDiagnostic?(enabled ? "playback enabled" : "playback disabled — \(closed.count) session(s) closed")
        if !closed.isEmpty { onSessionsChanged?() }
    }

    public func setAllowedSenders(_ addresses: Set<UInt32>?) {
        var toClose: [StreamSession] = []
        lock.lock()
        allowedSenderAddresses = addresses
        if let addresses {
            for (key, session) in sessions where !addresses.contains(key.endpoint.address) {
                toClose.append(session)
                sessions.removeValue(forKey: key)
            }
            suppressedDuplicatePaths = suppressedDuplicatePaths.filter { addresses.contains($0.endpoint.address) }
        }
        lock.unlock()
        for session in toClose {
            mixer.removeSession(endpoint: session.endpoint, streamId: session.streamId)
            onDiagnostic?("session closed (sender no longer selected): \(session.endpoint) stream=\(session.streamId)")
        }
        if !toClose.isEmpty { onSessionsChanged?() }
    }

    /// Hand the engine the server-group client, which from then on sees every packet in and
    /// out of the audio socket. Set it once, before `start()`.
    public func setRelayGroup(_ client: RelayGroupClient?) {
        lock.lock()
        relayGroup = client
        lock.unlock()
    }

    /// Tell the engine which addresses belong to the same peer (issue #8). The app derives
    /// this from discovery — one identity per announced instance, and one per manual peer —
    /// and pushes it alongside the allow-list. Addresses not in the map each stand alone.
    public func setPeerAddressGroups(_ groups: [UInt32: String]) {
        lock.lock()
        peerIdentityByAddress = groups
        lock.unlock()
    }

    /// Who this address belongs to. The address itself is the fallback identity, so an
    /// unmapped address is only ever grouped with itself.
    private func peerIdentityLocked(_ address: UInt32) -> String {
        peerIdentityByAddress[address] ?? "addr-\(address)"
    }

    public func peerSecurityStatus(address: UInt32) -> PeerSecurityStatus {
        lock.lock()
        defer { lock.unlock() }
        return peerSecurity[address] ?? .unknown
    }

    /// True when decoded audio from this address reached a playout buffer within `interval`
    /// — drives the connect/disconnect cues off the actual audio stream.
    public func isAudioFlowing(from address: UInt32, within interval: TimeInterval) -> Bool {
        let cutoff = Date().addingTimeInterval(-interval)
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.contains { $0.endpoint.address == address && $0.lastWriteTime >= cutoff }
    }

    /// Frame duration of the active stream, in ms, rounded **up** — the auto-tune's codec
    /// floor, so overestimating by half a millisecond is safer than rounding below the real
    /// frame size. With several senders this takes the largest frame (most conservative).
    /// nil when nothing is streaming.
    public var activeStreamFrameMs: Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !sessions.isEmpty else { return nil }
        var maxSamples = 0
        var sampleRate = SessionPlayout.mixSampleRate
        for session in sessions.values where session.format.frameSamplesPerChannel > maxSamples {
            maxSamples = session.format.frameSamplesPerChannel
            sampleRate = session.format.sampleRate > 0 ? session.format.sampleRate : SessionPlayout.mixSampleRate
        }
        guard maxSamples > 0 else { return nil }
        return (maxSamples * 1000 + sampleRate - 1) / sampleRate
    }

    /// Incremented every time a new session opens. A rise means the gap history the auto-tune
    /// samples spans a session boundary and must be discarded — a cross-session arrival gap
    /// would otherwise recommend an absurd target the new session could never arm at.
    public private(set) var sessionsOpenedCount: Int64 = 0

    /// Format of the freshest active session from this address (for "receiving Opus 10 ms…"
    /// status lines), or nil when nothing recent.
    public func activeFormat(from address: UInt32) -> AudioFormatInfo? {
        let cutoff = Date().addingTimeInterval(-Self.sessionIdleTimeout)
        lock.lock()
        defer { lock.unlock() }
        return sessions.values
            .filter { $0.endpoint.address == address && $0.lastWriteTime >= cutoff }
            .max { $0.lastWriteTime < $1.lastWriteTime }?
            .format
    }

    // MARK: - Lifecycle

    /// Bind the UDP socket. Heartbeats flow regardless of `playbackEnabled`.
    public func start(port: UInt16 = RemPacket.defaultPort) throws {
        guard socket == nil else { return }
        let sock = UDPSocket(onPacket: { [weak self] buffer, length, remote, kernelArrivalNs in
            self?.handleRawPacket(buffer: buffer, length: length, remote: remote, kernelArrivalNs: kernelArrivalNs)
        }, onDiagnostic: { [weak self] msg in self?.onDiagnostic?("network: \(msg)") })
        try sock.start(port: port)
        socket = sock
        startDate = Date()
        diagnostics.reset() // counters read against uptime, so a restart starts them clean

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        // 200 ms leeway so this idle-session prune coalesces with the other periodic timers
        // and audio callbacks (battery); the session idle timeout is seconds, so it is noise.
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.pruneIdleSessions() }
        timer.resume()
        pruneTimer = timer
    }

    public func stop() {
        pruneTimer?.cancel()
        pruneTimer = nil
        socket?.stop()
        socket = nil
        startDate = nil
        lock.lock()
        sessions.removeAll()
        suppressedDuplicatePaths.removeAll()
        lock.unlock()
        mixer.removeAllSessions()
    }

    /// Send bytes from the audio socket — heartbeat and microphone transport (single-port
    /// model: everything leaves from the same socket/NAT pinhole audio arrives on, which is
    /// also what claims our slot on the server's ordinary pair).
    ///
    /// When the user is in a group on a server, the group client gets first refusal: a
    /// packet addressed to a member goes to the server group-framed instead, and a packet
    /// addressed to the server goes in both forms where the protocol says it must.
    @discardableResult
    public func sendFromAudioSocket(_ data: [UInt8], to endpoint: UDPEndpoint) -> Bool {
        lock.lock()
        let group = relayGroup
        lock.unlock()
        if let group,
           group.route(data, to: endpoint, send: { [weak self] bytes, destination in
               self?.sendRawFromAudioSocket(bytes, to: destination) ?? false
           }) {
            return true
        }
        return sendRawFromAudioSocket(data, to: endpoint)
    }

    /// Straight to the socket, with no group routing. The group client's own packets (its
    /// hello, its bye) are already framed and must not be wrapped a second time, and an
    /// address-check echo has to leave exactly as it arrived.
    @discardableResult
    public func sendRawFromAudioSocket(_ data: [UInt8], to endpoint: UDPEndpoint) -> Bool {
        let sent = socket?.send(data, to: endpoint) ?? false
        if sent { bytesSent &+= Int64(data.count) }
        return sent
    }

    // MARK: - Packet path (network thread)

    /// What the packet turned out to be, after the group client has had its look.
    private enum Dispatch {
        case drop
        /// `source` is the peer it is from — the datagram's own source for an ordinary
        /// packet, or the member's stand-in address for one relayed through a server.
        case packet(header: RemPacket.Header, payloadStart: Int, source: UDPEndpoint)
    }

    private func dispatch(buffer: [UInt8], length: Int, remote: UDPEndpoint) -> Dispatch {
        lock.lock()
        let group = relayGroup
        lock.unlock()
        if let group {
            switch group.handleInbound(buffer, length: length, remote: remote) {
            case .consumed:
                return .drop // a roster, a "full", or our own packet coming back
            case .delivered(let header, let payloadStart, let source):
                return .packet(header: header, payloadStart: payloadStart, source: source)
            case .notGroup:
                break // an ordinary packet, or group framing from somewhere we are not
            }
        }
        guard let header = RemPacket.readHeader(buffer, length: length) else { return .drop }
        return .packet(header: header, payloadStart: RemPacket.headerSize, source: remote)
    }

    private func handleRawPacket(buffer: [UInt8], length: Int, remote: UDPEndpoint, kernelArrivalNs: UInt64) {
        bytesReceived &+= Int64(length)
        guard case .packet(let header, let payloadStart, let source) =
                dispatch(buffer: buffer, length: length, remote: remote) else { return }

        switch header.type {
        case .format:
            handleFormat(remote: source, streamId: header.streamId, payload: buffer[payloadStart..<length])
        case .audio:
            handleAudio(remote: source, streamId: header.streamId, sequence: header.sequence,
                        payload: buffer[payloadStart..<length], kernelArrivalNs: kernelArrivalNs)
        case .heartbeat:
            onHeartbeatReceived?(buffer[payloadStart..<length], source)
        case .addrCheck:
            // Relay address-proof: echo the packet back to its source, verbatim, from this
            // same socket. NOT gated on the allow-list — the challenge comes from the server,
            // which is a place rather than a selected peer, and refusing to echo costs us every
            // relayed stream (and, since server-v2.13, our place in any group at all).
            //
            // Back to `remote`, the datagram's real source, and raw: the echo proves THIS
            // address receives, so it must not be dressed up as group traffic (spec: "echo
            // address checks back exactly as they came, never in group framing"). Receiving
            // one is also the giveaway that an address is a server — only a server sends them.
            //
            // Gated since upstream 6.0 (`AddrCheckEchoGate`): answered only to an address we are
            // talking to, at most once a second each. Answering every check from anyone meant one
            // forged packet — A's address sent to B — bounced between two RemSound devices for
            // ever. A server only ever checks an address that has sent it something, and every
            // address we send to is one we ping, so the server we are on is always in the set.
            let decision = addrCheckDecision(for: remote)
            guard decision.fresh else { return }
            if decision.echo { sendRawFromAudioSocket(Array(buffer[0..<length]), to: remote) }
            onAddrCheckReceived?(remote)
        case .tickProof:
            noteTickProof(buffer[payloadStart..<length], from: source)
        case .keepAlive, .control:
            break // legacy / not handled in v1 — silently ignored, wire-safe
        case .lobbyHello, .lobbyRoster, .lobbyFull, .lobbyBye:
            // Group types, and they only ever arrive group-framed — in which case the group
            // client above consumed them. One of these in a version-1 header is nothing we
            // send or any server sends; drop it, wire-safe.
            break
        }
    }

    private func isSenderAllowed(_ remote: UDPEndpoint) -> Bool {
        guard let allowed = allowedSenderAddresses else { return true }
        return allowed.contains(remote.address)
    }

    private func handleFormat(remote: UDPEndpoint, streamId: UInt16, payload: ArraySlice<UInt8>) {
        guard let (format, fingerprint) = RemPacket.readFormat(payload) else { return }
        if let reason = format.unusableReason {
            noteUnusableFormat(from: remote, reason: reason)
            return
        }

        lock.lock()
        // Gate read under the lock: setPlaybackEnabled(false) flips it before disposing
        // sessions, so a packet racing the teardown can't open a fresh one.
        guard playbackEnabled else {
            lock.unlock()
            return
        }
        guard isSenderAllowed(remote) else {
            // Somebody sending us audio we have not asked for has ticked US. Format packets
            // carry the fingerprint and repeat every 250 ms, so this is the one place to
            // notice — audio packets would add nothing but volume.
            let now = Date()
            var report: Bool?
            if onUnselectedSenderHeard != nil,
               now.timeIntervalSince(unselectedSenderNoted[remote.address] ?? .distantPast)
                   >= Self.unselectedSenderInterval {
                // Anyone can put a source address on a format packet, so the memory is
                // capped: past 256 addresses the ones outside the window are forgotten.
                if unselectedSenderNoted.count >= 256 {
                    unselectedSenderNoted = unselectedSenderNoted.filter {
                        now.timeIntervalSince($0.value) < Self.unselectedSenderInterval
                    }
                }
                unselectedSenderNoted[remote.address] = now
                if let fingerprint, let mine = audioFingerprint {
                    report = RemSoundCrypto.fingerprintsEqual(fingerprint, mine)
                } else {
                    report = false
                }
            }
            lock.unlock()
            if let report { onUnselectedSenderHeard?(remote, report) }
            return
        }

        // Record whether this peer's password matches ours, from the advertised fingerprint
        // — the UI reads this to explain silence (mismatch / out-of-date peer).
        let myFingerprint = audioFingerprint
        let status: PeerSecurityStatus
        if let fingerprint {
            if let myFingerprint {
                status = RemSoundCrypto.fingerprintsEqual(fingerprint, myFingerprint) ? .secure : .passwordMismatch
            } else {
                status = .unknown
            }
        } else {
            status = .peerNeedsUpdate
        }
        peerSecurity[remote.address] = status

        let key = SessionKey(endpoint: remote, streamId: streamId)
        if let existing = sessions[key], existing.matchesFormat(format) {
            lock.unlock()
            return // same session; nothing to do
        }

        // Issue #8: one peer, one lane, two paths. A sender aimed at both a multi-homed
        // receiver's LAN and VPN addresses delivers the same audio twice from two different
        // source addresses; opening a session for each sums the stream against itself at two
        // path delays. The path that is already delivering keeps the lane; another path of
        // the same peer only takes over once that one has been silent for
        // `pathHandoverSilence`, so a genuine failover still works and a duplicate never
        // plays. Per lane, because BothIndependent really does send two concurrent lanes.
        let identity = peerIdentityLocked(remote.address)
        let handoverCutoff = Date().addingTimeInterval(-Self.pathHandoverSilence)
        let livePath = sessions.first {
            $0.key.endpoint.address != remote.address
                && peerIdentityLocked($0.key.endpoint.address) == identity
                && $0.value.format.lane == format.lane
                && $0.value.lastWriteTime >= handoverCutoff
        }
        if let livePath {
            let firstRefusal = suppressedDuplicatePaths.insert(key).inserted
            lock.unlock()
            if firstRefusal {
                onDiagnostic?("duplicate path ignored: \(remote) stream=\(streamId) — same peer already delivering from \(livePath.key.endpoint)")
            }
            return
        }
        suppressedDuplicatePaths.remove(key)

        let playout = mixer.getOrCreateSession(endpoint: remote, streamId: streamId)
        let isNew = sessions[key] == nil
        if isNew { sessionsOpenedCount &+= 1 }
        sessions[key] = StreamSession(
            endpoint: remote, streamId: streamId, format: format, playout: playout,
            decryptor: decryptor, diagnostics: diagnostics)

        // Supersede the peer's other sessions on this lane: a streamId rotation (the sender
        // rerolls it on codec changes and engine restarts), a new source port on the same
        // path, or the silent path this one has just taken over from. Matched on peer
        // identity, not endpoint equality, so all three collapse into one rule; lane-mismatched
        // sessions coexist (BothIndependent mode sends two concurrent lanes per peer).
        var superseded: [StreamSession] = []
        for (otherKey, other) in sessions
        where otherKey != key && peerIdentityLocked(otherKey.endpoint.address) == identity
            && other.format.lane == format.lane {
            superseded.append(other)
            sessions.removeValue(forKey: otherKey)
        }
        lock.unlock()

        for old in superseded {
            mixer.removeSession(endpoint: old.endpoint, streamId: old.streamId)
            onDiagnostic?("session superseded: \(old.endpoint) old=\(old.streamId) → \(remote) new=\(streamId)")
        }
        if isNew {
            onDiagnostic?("session opened: \(remote) stream=\(streamId) \(format.displayDescription)")
            onSessionsChanged?()
        } else {
            onDiagnostic?("stream format changed: \(remote) stream=\(streamId) \(format.displayDescription)")
        }
    }

    private func handleAudio(remote: UDPEndpoint, streamId: UInt16, sequence: UInt32,
                             payload: ArraySlice<UInt8>, kernelArrivalNs: UInt64) {
        lock.lock()
        guard playbackEnabled, isSenderAllowed(remote) else {
            lock.unlock()
            return
        }
        decryptor.ensureKey(audioKey)
        let session = sessions[SessionKey(endpoint: remote, streamId: streamId)]
        lock.unlock()

        guard let session else { return } // no Format seen yet — session opens on Format
        session.handleAudioPayload(sequence: sequence, payload: payload, kernelArrivalNs: kernelArrivalNs)
    }

    // MARK: - Maintenance

    private func pruneIdleSessions() {
        let now = Date()
        var removed: [StreamSession] = []
        lock.lock()
        for (key, session) in sessions
        where now.timeIntervalSince(session.lastWriteTime) > Self.sessionIdleTimeout {
            removed.append(session)
            sessions.removeValue(forKey: key)
        }
        // Hard-cap backstop: evict the idlest beyond maxLiveSessions.
        if sessions.count > Self.maxLiveSessions {
            let excess = sessions.count - Self.maxLiveSessions
            let idlest = sessions.sorted { $0.value.lastWriteTime < $1.value.lastWriteTime }.prefix(excess)
            for (key, session) in idlest {
                removed.append(session)
                sessions.removeValue(forKey: key)
            }
        }
        lock.unlock()

        for session in removed {
            mixer.removeSession(endpoint: session.endpoint, streamId: session.streamId)
            onDiagnostic?("session pruned (idle): \(session.endpoint) stream=\(session.streamId)")
        }
        if !removed.isEmpty { onSessionsChanged?() }
    }

    /// Who we answer address checks for: every address we ping (pushed by the app on every
    /// selection change). A server checks only addresses that send it something, so this
    /// MUST include the server we are on — without the echo, server-v2.13 lists us nowhere.
    public func setAddressCheckEchoTargets(_ addresses: Set<UInt32>?) {
        lock.lock()
        addrCheckEchoTargets = addresses
        lock.unlock()
    }

    /// `fresh`: not handled from this endpoint in the last second (a flood, or the same check
    /// twice, goes no further). `echo`: answer it — we are talking to that address.
    private func addrCheckDecision(for remote: UDPEndpoint) -> (fresh: Bool, echo: Bool) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if let last = addrCheckLast[remote], now.timeIntervalSince(last) < Self.addrCheckInterval {
            return (false, false)
        }
        if addrCheckLast.count >= 256 { addrCheckLast.removeAll() }
        addrCheckLast[remote] = now
        return (true, addrCheckEchoTargets?.contains(remote.address) ?? true)
    }

    private func noteTickProof(_ payload: ArraySlice<UInt8>, from remote: UDPEndpoint) {
        guard let handler = onTickProofReceived else { return }
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(tickProofNoted[remote.address] ?? .distantPast)
            >= Self.tickProofInterval
        if due {
            if tickProofNoted.count >= 1024 { tickProofNoted.removeAll() }
            tickProofNoted[remote.address] = now
        }
        lock.unlock()
        if due { handler(payload, remote) }
    }

    /// Last diagnostic for an unusable format, under `lock`. Rate-limited because a corrupted
    /// or spoofed stream re-announces its format four times a second.
    private var lastUnusableFormatNote = Date.distantPast

    private func noteUnusableFormat(from remote: UDPEndpoint, reason: String) {
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastUnusableFormatNote) >= 5
        if due { lastUnusableFormatNote = now }
        lock.unlock()
        if due { onDiagnostic?("format packet rejected from \(remote): \(reason)") }
    }

    // MARK: - Test seams

    /// Internal test seam: feed a packet as though the socket had delivered it from `remote`.
    /// The multi-path rules in `handleFormat` need two DIFFERENT source addresses, which no
    /// loopback test can produce (unlike the AddrCheck echo, which has to go over a real
    /// socket), so this is the only way to reach them.
    func handlePacketForTesting(_ packet: [UInt8], from remote: UDPEndpoint) {
        handleRawPacket(buffer: packet, length: packet.count, remote: remote, kernelArrivalNs: 0)
    }

    /// Internal test seam: the live session table.
    struct LiveSession: Equatable {
        let endpoint: UDPEndpoint
        let streamId: UInt16
        let lane: RenderRoute
    }

    var liveSessionsForTesting: [LiveSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.map {
            LiveSession(endpoint: $0.key.endpoint, streamId: $0.key.streamId, lane: $0.value.format.lane)
        }
    }
}
