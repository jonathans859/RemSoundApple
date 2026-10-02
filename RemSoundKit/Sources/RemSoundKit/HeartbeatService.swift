import Foundation

public enum PeerHealthState: Sendable {
    case unknown
    case healthy
    case stale
    case unreachable
}

public struct PeerHealth: Sendable {
    public let audioEndpoint: UDPEndpoint
    public let state: PeerHealthState
    public let rttMs: Int?
}

/// Bidirectional UDP heartbeat, wire-compatible with the Windows `HeartbeatService`
/// single-port model: pings ride the audio port via the shared socket, pongs echo the
/// originator's monotonic timestamp verbatim so RTT needs no clock sync between peers.
/// 1 Hz cadence doubles as the NAT keepalive — which is also what claims our slot on the
/// public relay (v1 pairwise mode) so reflected audio can reach us.
public final class HeartbeatService {
    public static let pingInterval: TimeInterval = 1.0
    public static let healthyWindow: TimeInterval = 2.0
    public static let unreachableWindow: TimeInterval = 5.0

    /// Outbound transport. REQUIRED — wire to the receiver's main UDP socket so heartbeats
    /// share the socket (and NAT pinhole) that audio arrives on.
    public var sendTransport: ((_ data: [UInt8], _ to: UDPEndpoint) -> Bool)?
    public var onDiagnostic: ((String) -> Void)?

    private let lock = NSLock()
    private var peers: [UDPEndpoint: PeerState] = [:]
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "RemSound.Heartbeat")
    private var sequence: UInt32 = 0
    private let startTime = DispatchTime.now()
    /// The originator timestamps of our recent pings. A pong only counts when it answers one
    /// of them — "count a pong only if it answers one of your own recent pings", which stops
    /// mattering only if nobody else's pongs can reach us. Through a server they can: a
    /// member's pong is fanned out to the whole group, carrying the clock of whoever pinged,
    /// so crediting it blindly would compute a round trip from somebody else's clock. One
    /// ping a second and a 5 s unreachable window, so eight is ample.
    private var recentPingTicks: [Int64] = []
    private static let recentPingMemory = 8

    public init() {}

    private var monotonicMs: Int64 {
        Int64((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        // 200 ms leeway lets the kernel coalesce this wakeup with the other periodic timers
        // and the audio callbacks (battery). Ample headroom: the health windows are 2 s / 5 s.
        t.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval,
                   leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.sendPings() }
        t.resume()
        timer = t
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// Replace the tracked peer set (each endpoint is the peer's audio port).
    public func setTrackedPeers(_ audioEndpoints: [UDPEndpoint]) {
        lock.lock()
        defer { lock.unlock() }
        let desired = Set(audioEndpoints)
        for key in peers.keys where !desired.contains(key) {
            peers.removeValue(forKey: key)
        }
        for ep in desired where peers[ep] == nil {
            peers[ep] = PeerState()
        }
    }

    public func allPeerHealth() -> [PeerHealth] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return peers.map { endpoint, state in snapshotHealthLocked(endpoint: endpoint, state: state, now: now) }
    }

    private func snapshotHealthLocked(endpoint: UDPEndpoint, state: PeerState, now: Date) -> PeerHealth {
        guard let lastPong = state.lastPong else {
            if let firstPing = state.firstPingSent, now.timeIntervalSince(firstPing) > Self.unreachableWindow {
                return PeerHealth(audioEndpoint: endpoint, state: .unreachable, rttMs: nil)
            }
            return PeerHealth(audioEndpoint: endpoint, state: .unknown, rttMs: nil)
        }
        let age = now.timeIntervalSince(lastPong)
        let healthState: PeerHealthState = age <= Self.healthyWindow
            ? .healthy
            : (age <= Self.unreachableWindow ? .stale : .unreachable)
        return PeerHealth(audioEndpoint: endpoint, state: healthState, rttMs: state.rttEwmaMs)
    }

    private func sendPings() {
        guard let transport = sendTransport else { return }
        lock.lock()
        let targets = Array(peers.keys)
        let now = Date()
        for state in peers.values where state.firstPingSent == nil {
            state.firstPingSent = now
        }
        sequence &+= 1
        let seq = sequence
        let tick = monotonicMs
        recentPingTicks.append(tick)
        if recentPingTicks.count > Self.recentPingMemory { recentPingTicks.removeFirst() }
        lock.unlock()

        // streamId 0xFFFF marks heartbeats, same as the Windows sender.
        var packet = RemPacket.writeHeader(type: .heartbeat, streamId: 0xFFFF, sequence: seq)
        packet.append(RemPacket.writeHeartbeatPayload(kind: .ping, originatorTickMs: tick))
        let bytes = [UInt8](packet)
        for target in targets {
            _ = transport(bytes, target)
        }
    }

    /// Feed the payload of a heartbeat that arrived on the shared audio socket. `remote` is
    /// whoever it is from — the datagram's source for an ordinary heartbeat, or a group
    /// member's stand-in address for one that came through a server (whose pong therefore
    /// goes back the same way, wrapped by the group client on its way out).
    public func handleHeartbeatPayload(_ payload: ArraySlice<UInt8>, remote: UDPEndpoint) {
        guard let (kind, originatorTickMs) = RemPacket.readHeartbeat(payload) else { return }

        if kind == .ping {
            lock.lock()
            sequence &+= 1
            let seq = sequence
            lock.unlock()
            // Echo the originator's timestamp back as a Pong, to wherever the ping came from
            // (works for LAN-direct and relay-return alike).
            var reply = RemPacket.writeHeader(type: .heartbeat, streamId: 0xFFFF, sequence: seq)
            reply.append(RemPacket.writeHeartbeatPayload(kind: .pong, originatorTickMs: originatorTickMs))
            _ = sendTransport?([UInt8](reply), remote)
            return
        }

        // Pong: RTT against our own clock; match tracked peers by IP only (the pong's source
        // port is the peer's outbound/NAT port, not its audio port).
        let rtt = Int(max(0, monotonicMs - originatorTickMs))
        let now = Date()
        lock.lock()
        guard recentPingTicks.contains(originatorTickMs) else {
            lock.unlock()
            return // answers somebody else's ping (see recentPingTicks)
        }
        for (endpoint, state) in peers where endpoint.address == remote.address {
            state.rttEwmaMs = state.rttEwmaMs.map { Int(Double($0) * 0.7 + Double(rtt) * 0.3) } ?? rtt
            state.lastPong = now
        }
        lock.unlock()
    }

    /// Test seam: one round of pings without waiting out the 1 Hz timer.
    func sendPingsForTesting() { sendPings() }

    private final class PeerState {
        var firstPingSent: Date?
        var lastPong: Date?
        var rttEwmaMs: Int?
    }
}
