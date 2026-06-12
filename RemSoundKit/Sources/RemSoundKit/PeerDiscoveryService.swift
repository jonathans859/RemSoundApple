import Foundation

/// JSON shape of a discovery announcement. Must match the C# `DiscoveryMessage` record
/// exactly — System.Text.Json matches property names case-SENSITIVELY on deserialize,
/// hence the PascalCase keys. Internal (not private) so tests can pin the wire shape.
struct DiscoveryMessage: Codable {
    let InstanceId: UUID
    let Name: String
    let AudioPort: Int
    let CanSend: Bool
    let CanReceive: Bool
}

/// A peer seen via discovery announcements. Mirrors `RemSound.Core.PeerAnnouncement`,
/// except that one instance keeps ALL the source addresses it announces from. A multi-homed
/// peer (LAN + VPN, e.g. Tailscale) announces from several addresses at once; the Windows
/// model of one address per instance makes the stored peer flap between paths on every
/// alternating announcement, which churns the allow-list, heartbeat state, and row identity.
public struct PeerAnnouncement: Identifiable, Hashable, Sendable {
    public let instanceId: UUID
    public let name: String
    public let audioPort: UInt16
    public let canSend: Bool
    public let canReceive: Bool
    public let lastSeenUtc: Date
    /// All live IPv4 source addresses (network byte order), first-seen first. Never empty.
    public let addresses: [UInt32]

    public var id: UUID { instanceId }

    /// Primary (oldest still-live) address — the stable display identity.
    public var address: UInt32 { addresses[0] }

    public var addressString: String {
        UDPEndpoint(address: address, port: 0).addressString
    }

    public var addressStrings: [String] {
        addresses.map { UDPEndpoint(address: $0, port: 0).addressString }
    }

    public var displayName: String { "\(name) at \(addressString)" }

    public var audioEndpoint: UDPEndpoint { UDPEndpoint(address: address, port: audioPort) }

    public var audioEndpoints: [UDPEndpoint] {
        addresses.map { UDPEndpoint(address: $0, port: audioPort) }
    }
}

/// UDP peer discovery, wire-compatible with the Windows `PeerDiscoveryService`:
/// JSON announcements on UDP 47821 every 1.5 s, peers expire after 8 s. Announcements go out
/// by LAN broadcast AND by unicast to known peer IPs (broadcast doesn't traverse VPNs like
/// Tailscale). Receiving an announcement auto-adds the source IP to the unicast targets so
/// discovery becomes bidirectional even if only one side knew the other's address.
///
/// Note for iOS: broadcast send/receive can be restricted (multicast entitlement). All
/// failures here are swallowed — discovery is convenience; manual peers and unicast
/// announcements still work, and the Windows side auto-discovers us from our unicast.
public final class PeerDiscoveryService {
    public static let defaultDiscoveryPort: UInt16 = 47821
    private static let announceInterval: TimeInterval = 1.5
    private static let peerExpirySeconds: TimeInterval = 8

    /// Mutable per-instance state behind `PeerAnnouncement` snapshots: each announce path
    /// (source address) expires independently, and `addressOrder` keeps the primary stable.
    private struct PeerRecord {
        var name: String
        var audioPort: UInt16
        var canSend: Bool
        var canReceive: Bool
        var addressOrder: [UInt32]
        var lastSeenByAddress: [UInt32: Date]
    }

    private let instanceId = UUID()
    private let lock = NSLock()
    private var peers: [UUID: PeerRecord] = [:]
    private var socket: UDPSocket?
    private var announceTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "RemSound.Discovery")

    private var audioPort: UInt16 = RemPacket.defaultPort
    private var displayName: String = "Apple device"
    private var unicastTargets: [UInt32] = []

    /// Fired (on an arbitrary queue) whenever the visible peer set changes.
    public var onPeersChanged: (() -> Void)?
    public var onDiagnostic: ((String) -> Void)?

    public init() {}

    public var currentPeers: [PeerAnnouncement] {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked()
        return peers.map { id, record in
            PeerAnnouncement(
                instanceId: id,
                name: record.name,
                audioPort: record.audioPort,
                canSend: record.canSend,
                canReceive: record.canReceive,
                lastSeenUtc: record.lastSeenByAddress.values.max() ?? .distantPast,
                addresses: record.addressOrder)
        }.sorted {
            $0.name == $1.name ? $0.addressString < $1.addressString : $0.name < $1.name
        }
    }

    public func start(displayName: String, audioPort: UInt16) {
        stop()
        self.displayName = displayName
        self.audioPort = audioPort

        let sock = UDPSocket(onPacket: { [weak self] buffer, length, remote in
            self?.handleAnnouncement(buffer: buffer, length: length, remote: remote)
        }, onDiagnostic: { [weak self] msg in self?.onDiagnostic?("discovery: \(msg)") })
        do {
            try sock.start(port: Self.defaultDiscoveryPort, enableBroadcast: true)
        } catch {
            // Port already in use or sandbox restriction — discovery is best-effort.
            onDiagnostic?("discovery: bind failed: \(error)")
            return
        }
        socket = sock

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: Self.announceInterval)
        timer.setEventHandler { [weak self] in self?.sendAnnouncement() }
        timer.resume()
        announceTimer = timer
    }

    public func stop() {
        announceTimer?.cancel()
        announceTimer = nil
        socket?.stop()
        socket = nil
    }

    /// Replace the set of IPs that announcements are unicast to (manual/remembered peers).
    public func setUnicastPeerAddresses(_ addresses: [UInt32]) {
        lock.lock()
        unicastTargets = Array(Set(addresses))
        lock.unlock()
        timerQueue.async { [weak self] in self?.sendAnnouncement() }
    }

    private func addUnicastTarget(_ address: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if !unicastTargets.contains(address) {
            unicastTargets.append(address)
        }
    }

    // MARK: - Wire format

    private func sendAnnouncement() {
        guard let socket else { return }
        let message = DiscoveryMessage(
            InstanceId: instanceId, Name: displayName, AudioPort: Int(audioPort),
            CanSend: true, CanReceive: true)
        guard let json = try? JSONEncoder().encode(message) else { return }

        for target in NetworkInterfaces.broadcastAddresses(port: Self.defaultDiscoveryPort) {
            socket.send(json, to: target) // best-effort; may fail on iOS without entitlement
        }
        lock.lock()
        let unicast = unicastTargets
        lock.unlock()
        for address in unicast {
            socket.send(json, to: UDPEndpoint(address: address, port: Self.defaultDiscoveryPort))
        }
    }

    // Internal (not private) so tests can drive the multi-address bookkeeping without sockets.
    func handleAnnouncement(buffer: [UInt8], length: Int, remote: UDPEndpoint) {
        let data = Data(buffer[0..<length])
        guard let message = try? JSONDecoder().decode(DiscoveryMessage.self, from: data) else { return }
        // Our own broadcasts come back to us; the InstanceId check filters them out.
        guard message.InstanceId != instanceId else { return }

        let trimmedName = message.Name.trimmingCharacters(in: .whitespaces)
        let name = trimmedName.isEmpty ? remote.addressString : trimmedName
        let audioPort = UInt16(clamping: message.AudioPort)
        let now = Date()

        // Announce back the way it came — makes discovery bidirectional over VPNs.
        addUnicastTarget(remote.address)

        var changed = false
        lock.lock()
        if var existing = peers[message.InstanceId] {
            changed = existing.name != name
                || existing.audioPort != audioPort
                || existing.canSend != message.CanSend
                || existing.canReceive != message.CanReceive
            existing.name = name
            existing.audioPort = audioPort
            existing.canSend = message.CanSend
            existing.canReceive = message.CanReceive
            if existing.lastSeenByAddress[remote.address] == nil {
                existing.addressOrder.append(remote.address)
                changed = true // new path for a known peer — allow-list etc. must re-feed
            }
            existing.lastSeenByAddress[remote.address] = now
            peers[message.InstanceId] = existing
        } else {
            peers[message.InstanceId] = PeerRecord(
                name: name,
                audioPort: audioPort,
                canSend: message.CanSend,
                canReceive: message.CanReceive,
                addressOrder: [remote.address],
                lastSeenByAddress: [remote.address: now])
            changed = true
        }
        pruneExpiredLocked()
        lock.unlock()

        if changed { onPeersChanged?() }
    }

    private func pruneExpiredLocked() {
        let cutoff = Date().addingTimeInterval(-Self.peerExpirySeconds)
        for (id, record) in peers {
            var updated = record
            updated.addressOrder.removeAll { (updated.lastSeenByAddress[$0] ?? .distantPast) < cutoff }
            updated.lastSeenByAddress = updated.lastSeenByAddress.filter { $0.value >= cutoff }
            if updated.addressOrder.isEmpty {
                peers.removeValue(forKey: id)
            } else if updated.addressOrder.count != record.addressOrder.count {
                peers[id] = updated
            }
        }
    }
}
