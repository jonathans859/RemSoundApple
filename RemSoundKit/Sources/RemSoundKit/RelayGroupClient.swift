import Foundation

/// Something worth telling the user (or the log) about the server we are on. The client
/// reports; `ReceiverController` decides what gets announced and what only reaches the
/// Diagnostics panel.
public enum RelayGroupEvent: Sendable {
    case connecting(UDPEndpoint)
    case joined(others: Int)
    /// No roster for `RelayGroup.rosterAliveFor` — the group is cold and we are an ordinary
    /// pair client again.
    case wentCold
    case left
    case memberJoined(name: String)
    case memberLeft(name: String)
    case memberRenamed(from: String, to: String)
    case memberTickedUs(name: String)
    case memberUntickedUs(name: String)
    case pairedWithOrdinaryChanged(Bool)
    case serverFull(count: Int, maximum: Int)
    /// A hello was due but we have no password, so there is no group to join.
    case needsPassword

    /// What to say out loud, for the few of these a person actually needs to hear. nil for
    /// the rest, which only reach the Diagnostics panel — a screen-reader user arrowing
    /// through the app does not want a sentence every time somebody's name changes.
    public var announcement: String? {
        switch self {
        case .joined(let others):
            return others == 0
                ? "Joined the group on the server. Nobody else here is using your password yet."
                : "Joined the group on the server with \(others) other\(others == 1 ? "" : "s")."
        case .memberTickedUs(let name):
            return "\(name) has ticked you."
        case .memberUntickedUs(let name):
            return "\(name) has unticked you."
        case .wentCold:
            return "The server has stopped answering. Its people are no longer listed."
        case .serverFull(let count, let maximum):
            return "The server is full, \(count) of \(maximum). You cannot join its group."
        case .needsPassword:
            return "Set a password to join a group. A server puts everyone on the same password together."
        case .connecting, .left, .memberJoined, .memberLeft, .memberRenamed,
             .pairedWithOrdinaryChanged:
            return nil
        }
    }

    public var message: String {
        switch self {
        case .connecting(let server):
            return "connecting to the server at \(server)"
        case .joined(let others):
            return "joined the group — \(others) other\(others == 1 ? "" : "s") on this password"
        case .wentCold:
            return "no member list for \(Int(RelayGroup.rosterAliveFor)) s — talking to the server as an ordinary pair again"
        case .left:
            return "left the server"
        case .memberJoined(let name):
            return "\(name) joined the group"
        case .memberLeft(let name):
            return "\(name) left the group"
        case .memberRenamed(let from, let to):
            return "\(from) is now called \(to)"
        case .memberTickedUs(let name):
            return "\(name) has ticked you"
        case .memberUntickedUs(let name):
            return "\(name) has unticked you"
        case .pairedWithOrdinaryChanged(let paired):
            return paired
                ? "a phone or older app on the server is paired with us — it is in the server list, and our audio reaches it once it is ticked"
                : "no longer paired with a phone or older app on the server"
        case .serverFull(let count, let maximum):
            return "the server is full (\(count) of \(maximum)) — this device cannot join its group"
        case .needsPassword:
            return "set a password to join a group — the server puts everyone on the same password together"
        }
    }
}

/// Being one person among several on a RemSound server.
///
/// **The one rule that keeps old and new together:** until the server has sent a member
/// list, this behaves exactly as the app did before it existed — ordinary (version 1)
/// packets, address checks echoed, pairing through the server's two ordinary slots.
/// Everything else switches on only once a roster has arrived within
/// `RelayGroup.rosterAliveFor`, and switches straight back off if they stop.
///
/// What it does when it is on: says hello to the server every `RelayGroup.helloInterval`
/// with our name, our password fingerprint as the group tag, and the client ids of the
/// people the user has ticked; wraps everything we send to that server in group framing; and
/// turns every group-framed packet coming back into an ordinary packet credited to a
/// **stand-in address** of that member's own, drawn from the reserved 240.0.0.0/5 block.
/// That last part is what makes the rest of the app work unchanged: a session, a row, a
/// heartbeat, a volume, a password check are all per address in this port, so each is now
/// per person. Windows does exactly the same, and calls it an implementation detail rather
/// than protocol — it is.
///
/// Thread-safety: `handleInbound` runs on the socket's receive thread, `route` on whichever
/// thread is sending (the capture thread, for microphone audio), and the rest on the main
/// actor. One lock covers all of it; every critical section is a dictionary lookup or two,
/// and no callback or syscall is ever made while holding it.
public final class RelayGroupClient {
    /// What `handleInbound` made of an arriving packet.
    public enum Inbound {
        /// Not group-framed, or not from the server we are connected to: handle it exactly
        /// as before.
        case notGroup
        /// Server bookkeeping (a roster, "the server is full", our own packet echoed): there
        /// is nothing else to do with it.
        case consumed
        /// A group member's packet. The payload starts at `payloadOffset`, and everything
        /// downstream should treat it as an ordinary packet from `source`.
        case delivered(header: RemPacket.Header, payloadOffset: Int, source: UDPEndpoint)
    }

    /// One person in our group, as the rest of the app sees them.
    public struct Member: Hashable, Sendable, Identifiable {
        public let id: RelayClientId
        /// The name they gave in their hello, or "" before a roster has named them.
        public let name: String
        /// The stand-in address this member is known by here (240.0.0.0/5, never a real
        /// peer). Deliberately not shown to the user — a person on a server has no address
        /// of their own, and showing a made-up one is a lie.
        public let endpoint: UDPEndpoint
        /// The server they are behind.
        public let server: UDPEndpoint
        /// The server says this member has ticked us. Sound needs both ticks, so this is
        /// what lets the UI say "waiting for them to tick you" instead of going quiet.
        public let ticksUs: Bool
    }

    public let clientId: RelayClientId

    /// Must go **straight to the socket** — what this sends is already group-framed and must
    /// not be routed again. Wire it before `connect`.
    public var rawTransport: ((_ data: [UInt8], _ to: UDPEndpoint) -> Bool)?
    /// Every event, for the Diagnostics panel and the announcements.
    public var onEvent: ((RelayGroupEvent) -> Void)?
    /// The group or its members changed: rebuild the rows.
    public var onChanged: (() -> Void)?

    private let lock = NSLock()
    private var server: UDPEndpoint?
    private var displayName = ""
    private var groupTag: [UInt8]?
    private var ticked: Set<RelayClientId> = []
    private var pairPartnerTicked = false
    private var inGroup = false
    private var pairedWithOrdinary = false
    private var lastRoster = Date.distantPast
    private var lastHello = Date.distantPast
    private var membersById: [RelayClientId: MemberState] = [:]
    private var memberIdByAddress: [UInt32: RelayClientId] = [:]
    /// The sequence of the last heartbeat we wrapped for the group. One ping is addressed to
    /// every tracked peer, and every member is a tracked peer, so without this the identical
    /// datagram goes to the server once per member — and the server fans each copy out to
    /// the whole group, which every member then pongs. Quadratic traffic for one ping.
    private var lastWrappedHeartbeatSequence: UInt32?
    private var warnedNoPassword = false

    private struct MemberState {
        var name: String
        var ticksUs: Bool
        /// A roster has actually named this member. A member created from an arriving packet
        /// before the first roster has not been.
        var listed: Bool
        let endpoint: UDPEndpoint
    }

    public init(clientId: RelayClientId) {
        self.clientId = clientId
    }

    // MARK: - What the app tells us

    /// Our name as the others see it, and our password fingerprint. **A nil fingerprint is
    /// "no password", and there is no group to join without one** — the server groups by
    /// that tag and nothing else, so a client with no password can only pair.
    public func setIdentity(name: String, passwordFingerprint: [UInt8]?) {
        let tag = passwordFingerprint?.count == RelayGroup.groupTagSize ? passwordFingerprint : nil
        lock.lock()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = trimmed != displayName || tag != groupTag
        displayName = trimmed
        // A new password is a new group: drop the ticks and let the new group's list arrive,
        // exactly as the spec requires (section 9). Holding them would keep sending ids that
        // mean nothing in the group we are about to land in.
        if tag != groupTag {
            ticked.removeAll()
            pairPartnerTicked = false
            warnedNoPassword = false
        }
        groupTag = tag
        if changed { lastHello = .distantPast }
        lock.unlock()
        if changed { tick() }
    }

    /// Connect to a server: from now on we say hello every couple of seconds and its people
    /// fill the server list. Connecting to a different one leaves the first. **Nothing is
    /// joined without this** — a server is somewhere you go, not a person in your peer list.
    public func connect(to endpoint: UDPEndpoint) {
        lock.lock()
        if let current = self.server, current == endpoint {
            lock.unlock()
            return
        }
        let leaving = byeTargetLocked()
        forgetServerLocked()
        self.server = endpoint
        lock.unlock()
        if let leaving { sendBye(to: leaving) }
        onEvent?(.connecting(endpoint))
        onChanged?()
        tick()
    }

    /// Leave: say goodbye so the others see us go at once, and empty the list.
    public func disconnect() {
        lock.lock()
        let leaving = byeTargetLocked()
        forgetServerLocked()
        self.server = nil
        ticked.removeAll()
        pairPartnerTicked = false
        lock.unlock()
        if let leaving {
            sendBye(to: leaving)
            onEvent?(.left)
        }
        onChanged?()
    }

    /// The people the user has ticked, by client id, and whether the phone or older app we
    /// are paired with through the server is ticked. The ids go out in every hello: the
    /// server passes sound between two people only when each has ticked the other. The pair
    /// partner is ours to gate, because the server's ordinary pair slots work as they always
    /// have.
    public func setTicked(_ ids: Set<RelayClientId>, pairPartner: Bool) {
        lock.lock()
        guard ids != ticked || pairPartner != pairPartnerTicked else {
            lock.unlock()
            return
        }
        ticked = ids
        pairPartnerTicked = pairPartner
        lastHello = .distantPast // tell the server at once, not on the next 2 s tick
        lock.unlock()
        tick()
    }

    // MARK: - What the app asks

    public var connectedServer: UDPEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return server
    }

    /// True while a member list has arrived recently — the gate on all of this.
    public var isInGroup: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inGroup
    }

    /// The server's member list says we also hold one of its ordinary pair slots, with a
    /// partner on it. That partner is a phone or an older app which cannot say it has ticked
    /// us; being given the slot beside it is the same statement.
    public var isPairedWithOrdinary: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pairedWithOrdinary
    }

    /// Everyone in our group, us excepted, named first and in name order.
    public var members: [Member] {
        lock.lock()
        defer { lock.unlock() }
        guard let server = self.server else { return [] }
        return membersById
            .map { Member(id: $0.key, name: $0.value.name, endpoint: $0.value.endpoint,
                          server: server, ticksUs: $0.value.ticksUs) }
            .sorted {
                if $0.name.isEmpty != $1.name.isEmpty { return !$0.name.isEmpty }
                let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
                return byName == .orderedSame ? $0.id.hex < $1.id.hex : byName == .orderedAscending
            }
    }

    /// The member behind a stand-in address, or nil when it is not one of ours.
    public func member(at address: UInt32) -> Member? {
        lock.lock()
        defer { lock.unlock() }
        guard let server = self.server, let id = memberIdByAddress[address],
              let state = membersById[id] else { return nil }
        return Member(id: id, name: state.name, endpoint: state.endpoint, server: server,
                      ticksUs: state.ticksUs)
    }

    /// True for an address in 240.0.0.0/5, the reserved block member stand-ins come from.
    /// Nothing real is ever routed there, so a packet aimed at one must never reach the wire.
    public static func isMemberAddress(_ address: UInt32) -> Bool {
        let firstOctet = UInt32(bigEndian: address) >> 24
        return firstOctet >= 240 && firstOctet <= 247
    }

    // MARK: - The clock

    /// One turn of the clock: send the hello when it is due, and notice a server that has
    /// gone quiet. Called from the app's existing 1 Hz tick — no timer of its own.
    public func tick(now: Date = Date()) {
        var hello: (packet: [UInt8], server: UDPEndpoint)?
        var events: [RelayGroupEvent] = []
        var changed = false

        lock.lock()
        if let server = self.server {
            if let groupTag = self.groupTag {
                // Only count a hello as sent if there is something to send it with, or the
                // first one is lost and the next is two seconds away.
                if rawTransport != nil, now.timeIntervalSince(lastHello) >= RelayGroup.helloInterval {
                    lastHello = now
                    hello = (RelayGroup.helloPacket(clientId: clientId, name: displayName,
                                                    groupTag: groupTag,
                                                    ticked: Array(ticked)), server)
                }
            } else if !warnedNoPassword {
                warnedNoPassword = true
                events.append(.needsPassword)
            }
            // A member exists only because a member list said so. When the lists stop, the
            // group is cold AND everybody it was carrying goes with it — otherwise their
            // stand-in addresses keep routing audio at a server that is not there, and
            // (worse) a half-remembered member can never be listed again when it comes back,
            // because the only place a member is ever added is a roster that names a member
            // we have not already got. Upstream hit exactly this; `forgetServerLocked` is
            // deliberately the whole of the per-server state, not just the visible part.
            if inGroup, now.timeIntervalSince(lastRoster) > RelayGroup.rosterAliveFor {
                events.append(.wentCold)
                for member in membersById.values where member.listed {
                    events.append(.memberLeft(name: describe(member.name)))
                }
                forgetServerLocked()
                changed = true
            }
        }
        lock.unlock()

        if let hello { _ = rawTransport?(hello.packet, hello.server) }
        for event in events { onEvent?(event) }
        if changed { onChanged?() }
    }

    // MARK: - Inbound (network thread)

    /// A packet arrived on the audio socket. Group-framed packets from the server we are
    /// connected to are handled here; everything else is `notGroup` and takes the ordinary
    /// path untouched.
    public func handleInbound(_ buffer: [UInt8], length: Int, remote: UDPEndpoint) -> Inbound {
        guard length >= RelayGroup.headerSize, buffer.count >= RelayGroup.headerSize,
              buffer[4] == RelayGroup.version,
              let header = RelayGroup.readHeader(buffer, length: length)
        else { return .notGroup }

        lock.lock()
        guard let server = self.server, server == remote else {
            lock.unlock()
            return .notGroup
        }
        lock.unlock()

        switch header.type {
        case .lobbyRoster:
            if let roster = RelayGroup.readRoster(buffer[RelayGroup.headerSize..<length]) {
                applyRoster(roster, server: server)
            }
            return .consumed
        case .lobbyFull:
            if let full = RelayGroup.readFull(buffer[RelayGroup.headerSize..<length]) {
                onEvent?(.serverFull(count: full.count, maximum: full.maximum))
            }
            return .consumed
        case .lobbyHello, .lobbyBye:
            return .consumed // ours coming back, or another member's: not for us to read
        case .tickProof:
            return .consumed // never sent through a server — the member list says who ticked whom
        case .format, .audio, .heartbeat, .control, .keepAlive, .addrCheck:
            break
        }

        // Our own packet, or the server speaking with its all-zero id under a forwardable
        // type: never expected, never played.
        guard header.clientId != clientId, !header.clientId.isZero else { return .consumed }

        var isNew = false
        lock.lock()
        // Still connected to the same server? (The lock was dropped above.)
        guard self.server == remote else {
            lock.unlock()
            return .notGroup
        }
        let endpoint: UDPEndpoint
        if let existing = membersById[header.clientId] {
            endpoint = existing.endpoint
        } else {
            endpoint = allocateAddressLocked(for: header.clientId)
            membersById[header.clientId] = MemberState(name: "", ticksUs: false, listed: false,
                                                       endpoint: endpoint)
            memberIdByAddress[endpoint.address] = header.clientId
            isNew = true
        }
        lock.unlock()

        if isNew { onChanged?() }
        return .delivered(header: header.asOrdinary, payloadOffset: RelayGroup.headerSize,
                          source: endpoint)
    }

    private func applyRoster(_ roster: RelayGroup.Roster, server: UDPEndpoint) {
        var events: [RelayGroupEvent] = []
        var changed = false

        lock.lock()
        guard let current = self.server, current == server else {
            lock.unlock()
            return
        }
        lastRoster = Date()
        let joinedNow = !inGroup
        if joinedNow { changed = true }
        inGroup = true

        if pairedWithOrdinary != roster.pairedWithOrdinary {
            pairedWithOrdinary = roster.pairedWithOrdinary
            events.append(.pairedWithOrdinaryChanged(roster.pairedWithOrdinary))
            changed = true
        }

        // The server puts us in our own group's list; the rest of the app has no use for a
        // row representing this device.
        let listed = roster.members.filter { $0.id != clientId }
        if joinedNow { events.append(.joined(others: listed.count)) }

        for entry in listed {
            if var state = membersById[entry.id] {
                if !state.listed || state.name != entry.name {
                    if !state.listed {
                        events.append(.memberJoined(name: describe(entry.name)))
                    } else {
                        events.append(.memberRenamed(from: describe(state.name), to: describe(entry.name)))
                    }
                    state.name = entry.name
                    state.listed = true
                    changed = true
                }
                if state.ticksUs != entry.ticksUs {
                    events.append(entry.ticksUs
                        ? .memberTickedUs(name: describe(state.name))
                        : .memberUntickedUs(name: describe(state.name)))
                    state.ticksUs = entry.ticksUs
                    changed = true
                }
                membersById[entry.id] = state
            } else {
                let endpoint = allocateAddressLocked(for: entry.id)
                membersById[entry.id] = MemberState(name: entry.name, ticksUs: entry.ticksUs,
                                                    listed: true, endpoint: endpoint)
                memberIdByAddress[endpoint.address] = entry.id
                events.append(.memberJoined(name: describe(entry.name)))
                changed = true
            }
        }

        // Off the list means gone. Collected first, then removed: a dictionary being walked
        // is no place to delete from.
        let present = Set(listed.map(\.id))
        for (id, state) in membersById.filter({ !present.contains($0.key) }) {
            if state.listed { events.append(.memberLeft(name: describe(state.name))) }
            membersById.removeValue(forKey: id)
            memberIdByAddress.removeValue(forKey: state.endpoint.address)
            changed = true
        }
        lock.unlock()

        for event in events { onEvent?(event) }
        if changed { onChanged?() }
    }

    // MARK: - Outbound

    /// Decide whether a packet bound for `destination` travels through the server, and if so
    /// send it. Returns true when the packet was handled here — the caller must then not
    /// send it itself.
    ///
    /// The rules, from the spec's "Sending, once you're in a group":
    /// - everything goes to the server in group framing, once;
    /// - a heartbeat **also** goes in ordinary form, because that is what claims an ordinary
    ///   pair slot beside a phone or older app waiting for one, so we still reach somebody;
    /// - audio, formats and control packets also go in ordinary form while the roster says we
    ///   hold such a slot *and* the user has ticked that partner;
    /// - an address check is echoed exactly as it came, never group-framed;
    /// - a packet addressed to a member's stand-in address goes to the server (and so to the
    ///   group), and never, under any circumstances, onto the wire as addressed.
    @discardableResult
    public func route(_ packet: [UInt8], to destination: UDPEndpoint,
                      send: (_ data: [UInt8], _ to: UDPEndpoint) -> Bool) -> Bool {
        guard packet.count >= RemPacket.headerSize else { return false }
        let typeByte = packet[5]
        let isHeartbeat = typeByte == RemPacketType.heartbeat.rawValue
        let sequence = UInt32(packet[8]) | UInt32(packet[9]) << 8
            | UInt32(packet[10]) << 16 | UInt32(packet[11]) << 24

        lock.lock()
        let joined = self.inGroup
        let via = self.server
        let forMember = memberIdByAddress[destination.address] != nil
        let alsoOrdinary = pairedWithOrdinary && pairPartnerTicked
        // One ping is addressed to every tracked peer, and while we are on a server that
        // means every member AND the server itself — all the same datagram. Wrapping it once
        // per destination would put N identical copies on the server, each of which it fans
        // out to the whole group, each of which every member then pongs. One ping, one
        // group-framed copy; the ordinary copy below is a different packet with a different
        // job and is not affected.
        var suppressDuplicateWrap = false
        if isHeartbeat, joined {
            suppressDuplicateWrap = lastWrappedHeartbeatSequence == sequence
            lastWrappedHeartbeatSequence = sequence
        }
        lock.unlock()

        if forMember || Self.isMemberAddress(destination.address) {
            guard let server = via, joined, forMember, !suppressDuplicateWrap,
                  let wrapped = RelayGroup.wrap(packet, clientId: clientId)
            else {
                // A member we no longer know, or a group that has gone cold: dropped. A
                // 240.0.0.0/5 address is not a place; letting it reach the socket would send
                // this peer's audio to a stranger.
                return true
            }
            _ = send(wrapped, server)
            return true
        }

        guard let server = via, joined, destination == server else { return false }
        // The echo has to be byte-identical to the challenge, and the server reads it in
        // whichever framing it arrives in — but it is proof of *this address*, which is a v1
        // fact. Echo it exactly as it came.
        if typeByte == RemPacketType.addrCheck.rawValue { return false }
        if !suppressDuplicateWrap, let wrapped = RelayGroup.wrap(packet, clientId: clientId) {
            _ = send(wrapped, server)
        }
        if isHeartbeat || alsoOrdinary {
            _ = send(packet, destination)
        }
        return true
    }

    // MARK: - Bookkeeping

    /// Who to say goodbye to, if anyone: the server we are leaving, but only once we have
    /// actually said hello to it — a bye is accepted only from an endpoint the server has
    /// registered, and it is what frees our slot there straight away instead of after its
    /// 60 s idle timeout.
    private func byeTargetLocked() -> UDPEndpoint? {
        lastHello == .distantPast ? nil : server
    }

    private func sendBye(to server: UDPEndpoint) {
        _ = rawTransport?(RelayGroup.byePacket(clientId: clientId), server)
    }

    /// Everything that exists only because this server said so. Called when the server goes
    /// quiet and when we leave — **all of it, every time**: anything kept back becomes a
    /// member that can never be listed again.
    private func forgetServerLocked() {
        inGroup = false
        pairedWithOrdinary = false
        lastRoster = .distantPast
        lastHello = .distantPast
        membersById.removeAll()
        memberIdByAddress.removeAll()
        lastWrappedHeartbeatSequence = nil
    }

    /// The stand-in address for a member: 240.0.0.0/5 plus a hash of their client id, so the
    /// same person gets the same address every time (their volume, their name, anything else
    /// this port keys by address comes back with them). Two ids that hash alike take the next
    /// free address.
    private func allocateAddressLocked(for id: RelayClientId) -> UDPEndpoint {
        var value: UInt32 = 0xF000_0000 | (id.addressHash & 0x07FF_FFFF)
        for _ in 0...RelayGroup.maxTickedIds {
            let address = value.bigEndian
            if let holder = memberIdByAddress[address], holder != id {
                value = 0xF000_0000 | ((value &+ 1) & 0x07FF_FFFF)
                continue
            }
            return UDPEndpoint(address: address, port: RemPacket.defaultPort)
        }
        return UDPEndpoint(address: value.bigEndian, port: RemPacket.defaultPort)
    }

    private func describe(_ name: String) -> String {
        name.isEmpty ? "someone not yet named" : name
    }

    // MARK: - Test seams

    /// Put the last-roster clock back, so a server going quiet can be exercised without
    /// sitting through five seconds of silence. The timestamp is the only thing the silence
    /// itself changes.
    func backdateRosterForTesting(by interval: TimeInterval) {
        lock.lock()
        lastRoster -= interval
        lock.unlock()
    }

    /// Put the last-hello clock back, so the 2 s cadence can be exercised in one call.
    func backdateHelloForTesting(by interval: TimeInterval) {
        lock.lock()
        lastHello -= interval
        lock.unlock()
    }
}
