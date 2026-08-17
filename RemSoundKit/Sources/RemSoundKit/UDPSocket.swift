import Darwin
import Foundation

/// IPv4 UDP endpoint. The whole RemSound protocol is IPv4 (matching the Windows app's
/// AF_INET sockets), so we store the raw network-order address + host-order port.
public struct UDPEndpoint: Hashable, Sendable, CustomStringConvertible {
    /// IPv4 address in network byte order.
    public let address: UInt32
    /// Port in host byte order.
    public let port: UInt16

    public init(address: UInt32, port: UInt16) {
        self.address = address
        self.port = port
    }

    public init?(host: String, port: UInt16) {
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return nil }
        self.address = addr.s_addr
        self.port = port
    }

    public var addressString: String {
        var addr = in_addr(s_addr: address)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    public var description: String { "\(addressString):\(port)" }

    var sockaddr: sockaddr_in {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = in_addr(s_addr: address)
        return sa
    }

    /// Resolves a hostname or dotted-quad to IPv4 endpoints (DNS for relay hostnames,
    /// MagicDNS names, etc.). Blocking — call off the main thread.
    public static func resolve(host: String, port: UInt16) -> [UDPEndpoint] {
        if let direct = UDPEndpoint(host: host, port: port) { return [direct] }
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var endpoints: [UDPEndpoint] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if info.pointee.ai_family == AF_INET, let sa = info.pointee.ai_addr {
                let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ep = UDPEndpoint(address: sin.sin_addr.s_addr, port: port)
                if !endpoints.contains(ep) { endpoints.append(ep) }
            }
            cursor = info.pointee.ai_next
        }
        return endpoints
    }
}

/// Minimal blocking-recv UDP socket with a dedicated drain thread, mirroring the Windows
/// `NetworkListener` design: one fixed receive buffer reused across calls, packets handed up
/// as (buffer, length, remote) — the callback must copy anything it keeps.
public final class UDPSocket {
    /// `kernelArrivalNs` is the datagram's arrival time as stamped by the kernel
    /// (`SO_TIMESTAMP`), in nanoseconds on the **wall clock**, or 0 when the kernel did not
    /// attach one. It exists because timing packets on this thread measures the thread, not
    /// the network: when iOS throttles a backgrounded app the receive thread is descheduled
    /// while datagrams pile up in the socket buffer, and reading them in a burst then looks
    /// like one enormous network gap. Measured on a 5G link, that artefact drove the latency
    /// auto-tune to its 200 ms ceiling for traffic that had arrived evenly spaced.
    /// Callers that mix this with a local clock must not subtract one from the other.
    public typealias PacketHandler = (_ buffer: [UInt8], _ length: Int, _ remote: UDPEndpoint,
                                      _ kernelArrivalNs: UInt64) -> Void

    private var fd: Int32 = -1
    private var thread: Thread?
    private let onPacket: PacketHandler
    private let onDiagnostic: ((String) -> Void)?
    private let lock = NSLock()

    public init(onPacket: @escaping PacketHandler, onDiagnostic: ((String) -> Void)? = nil) {
        self.onPacket = onPacket
        self.onDiagnostic = onDiagnostic
    }

    /// The locally-bound port (useful when binding port 0).
    public private(set) var boundPort: UInt16 = 0

    /// Bind and start the receive thread. `port` 0 lets the OS pick.
    /// Broadcast permission is needed to SEND broadcast announcements (discovery).
    public func start(port: UInt16, enableBroadcast: Bool = false, reuseAddress: Bool = true) throws {
        stop()
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var one: Int32 = 1
        if reuseAddress {
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        if enableBroadcast {
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        // 1 MB kernel receive buffer — same rationale as the Windows receiver: ride out
        // short render-thread or scheduler stalls without the kernel dropping datagrams.
        var bufSize: Int32 = 1024 * 1024
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        // Ask the kernel to stamp each datagram with its arrival time (see PacketHandler).
        // Best-effort: if this fails, `receiveLoop` reports 0 and callers fall back to their
        // own clock, which is what the code did before this existed.
        if setsockopt(sock, SOL_SOCKET, SO_TIMESTAMP, &one, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            onDiagnostic?("SO_TIMESTAMP unavailable (errno \(errno)) — arrival gaps fall back to the receive thread's clock")
        }

        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &sa) { ptr in
            ptr.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(sock)
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }

        // Recover the actual bound port (when asked for 0).
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { saPtr in
                _ = getsockname(sock, saPtr, &boundLen)
            }
        }
        boundPort = UInt16(bigEndian: bound.sin_port)

        lock.lock()
        fd = sock
        lock.unlock()

        let receiveThread = Thread { [weak self] in self?.receiveLoop(socket: sock) }
        receiveThread.name = "RemSound.UDPReceive"
        // Network drain feeds the audio path; raise priority above default UI work.
        receiveThread.qualityOfService = .userInteractive
        receiveThread.start()
        thread = receiveThread
        onDiagnostic?("UDP socket bound to :\(boundPort)")
    }

    public func stop() {
        lock.lock()
        let sock = fd
        fd = -1
        lock.unlock()
        if sock >= 0 {
            close(sock) // unblocks the recvfrom in the receive thread
        }
        thread = nil
    }

    deinit { stop() }

    /// Fire-and-forget UDP send. Returns true when the datagram was handed to the kernel.
    @discardableResult
    public func send(_ data: [UInt8], to endpoint: UDPEndpoint) -> Bool {
        lock.lock()
        let sock = fd
        lock.unlock()
        guard sock >= 0 else { return false }
        var sa = endpoint.sockaddr
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &sa) { ptr in
                ptr.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { saPtr in
                    sendto(sock, bytes.baseAddress, bytes.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }

    @discardableResult
    public func send(_ data: Data, to endpoint: UDPEndpoint) -> Bool {
        send([UInt8](data), to: endpoint)
    }

    // Darwin's CMSG_* helpers are function-like macros, which Swift does not import, so the
    // control-message arithmetic is spelled out here. Darwin aligns control data to 4 bytes
    // (__DARWIN_ALIGN32), NOT to the pointer size — using MemoryLayout<cmsghdr>.stride would
    // be right by luck on 64-bit and wrong in principle.
    private static let cmsgAlign = 4
    private static func align32(_ n: Int) -> Int { (n + cmsgAlign - 1) & ~(cmsgAlign - 1) }
    private static var cmsgHeaderSize: Int { align32(MemoryLayout<cmsghdr>.size) }
    private static func cmsgLen(_ payload: Int) -> Int { cmsgHeaderSize + payload }
    private static func cmsgSpace(_ payload: Int) -> Int { cmsgHeaderSize + align32(payload) }

    private func receiveLoop(socket sock: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        // msghdr / iovec / sockaddr / control block live on the heap for the whole loop rather
        // than as locals captured by the `withUnsafeMutableBytes` closure: passing `&local` to
        // recvmsg from inside a closure that also mutates that same local is exactly the
        // overlapping-access pattern Swift's exclusivity checking exists to reject.
        let controlCapacity = Self.cmsgSpace(MemoryLayout<timeval>.size)
        let controlPtr = UnsafeMutableRawPointer.allocate(byteCount: controlCapacity, alignment: 8)
        let msgPtr = UnsafeMutablePointer<msghdr>.allocate(capacity: 1)
        let iovPtr = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
        let fromPtr = UnsafeMutablePointer<sockaddr_in>.allocate(capacity: 1)
        msgPtr.initialize(to: msghdr())
        iovPtr.initialize(to: iovec())
        fromPtr.initialize(to: sockaddr_in())
        defer {
            msgPtr.deinitialize(count: 1)
            iovPtr.deinitialize(count: 1)
            fromPtr.deinitialize(count: 1)
            msgPtr.deallocate()
            iovPtr.deallocate()
            fromPtr.deallocate()
            controlPtr.deallocate()
        }

        while true {
            let received = buffer.withUnsafeMutableBytes { bytes -> Int in
                iovPtr.pointee.iov_base = bytes.baseAddress
                iovPtr.pointee.iov_len = bytes.count
                msgPtr.pointee.msg_name = UnsafeMutableRawPointer(fromPtr)
                msgPtr.pointee.msg_namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
                msgPtr.pointee.msg_iov = iovPtr
                msgPtr.pointee.msg_iovlen = 1
                msgPtr.pointee.msg_control = controlPtr
                msgPtr.pointee.msg_controllen = socklen_t(controlCapacity)
                msgPtr.pointee.msg_flags = 0
                return recvmsg(sock, msgPtr, 0)
            }
            if received <= 0 {
                // Socket closed (stop()) or fatal error — exit the thread.
                if received < 0 && (errno == EINTR) { continue }
                break
            }
            let from = fromPtr.pointee
            let remote = UDPEndpoint(address: from.sin_addr.s_addr, port: UInt16(bigEndian: from.sin_port))
            let arrival = Self.kernelArrivalNs(control: controlPtr,
                                               controlLen: Int(msgPtr.pointee.msg_controllen))
            onPacket(buffer, received, remote, arrival)
        }
    }

    /// Pull the kernel's arrival timestamp out of the control buffer, or 0 when absent.
    /// Only the first control message is examined — SO_TIMESTAMP is the only one requested.
    static func kernelArrivalNs(control: UnsafeRawPointer, controlLen: Int) -> UInt64 {
        guard controlLen >= cmsgLen(MemoryLayout<timeval>.size) else { return 0 }
        // loadUnaligned: control data carries no alignment guarantee for these structs, and a
        // misaligned typed load is undefined behaviour.
        let header = control.loadUnaligned(as: cmsghdr.self)
        guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_TIMESTAMP,
              Int(header.cmsg_len) >= cmsgLen(MemoryLayout<timeval>.size) else { return 0 }
        let tv = (control + cmsgHeaderSize).loadUnaligned(as: timeval.self)
        guard tv.tv_sec > 0 else { return 0 }
        return UInt64(tv.tv_sec) &* 1_000_000_000 &+ UInt64(max(0, tv.tv_usec)) &* 1_000
    }
}

/// Local IPv4 interface enumeration — used for subnet broadcast addresses (discovery) and
/// self-identification.
public enum NetworkInterfaces {
    /// Subnet-directed broadcast addresses of all up, non-loopback IPv4 interfaces, plus the
    /// limited broadcast 255.255.255.255.
    public static func broadcastAddresses(port: UInt16) -> [UDPEndpoint] {
        var result: Set<UDPEndpoint> = [UDPEndpoint(address: INADDR_BROADCAST.bigEndian, port: port)]
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return Array(result) }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard let maskPtr = ifa.pointee.ifa_netmask else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let broadcast = sin.sin_addr.s_addr | ~mask.sin_addr.s_addr
            result.insert(UDPEndpoint(address: broadcast, port: port))
        }
        return Array(result)
    }

    /// Local (non-loopback) IPv4 addresses, network byte order — used to ignore our own
    /// discovery announcements echoed back by the network.
    public static func localAddresses() -> Set<UInt32> {
        var result: Set<UInt32> = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return result }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            result.insert(sin.sin_addr.s_addr)
        }
        return result
    }
}
