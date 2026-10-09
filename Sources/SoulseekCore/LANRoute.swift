import Foundation
import Darwin

/// Peers behind the same router as us. The server only knows public addresses, and many home and office
/// routers refuse connections from inside the network to their own public address (no NAT hairpin), so two
/// clients on one network could never reach each other. When the server reports a peer at our own public
/// address, we look for its listening port on the local subnet instead.
enum LANRoute {
    /// Whether `host` is an address on the public internet, as opposed to loopback or a private range.
    static func isPublic(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, let second) where (16...31).contains(second): return false
        case (100, let second) where (64...127).contains(second): return false
        default: return parts[0] < 224
        }
    }

    /// Our IPv4 addresses on active Wi-Fi and Ethernet interfaces with their netmasks.
    static func localNetworks() -> [(address: UInt32, mask: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var output: [(UInt32, UInt32)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name).hasPrefix("en"),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let mask = entry.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard !isPublic(string(ip)) else { continue }
            output.append((ip, netmask))
        }
        return output
    }

    /// Hosts to try: every address of each local subnet, capped at the /22 around us so a scan stays quick.
    static func candidates(networks: [(address: UInt32, mask: UInt32)]) -> [UInt32] {
        var seen = Set<UInt32>(), output: [UInt32] = []
        for (address, mask) in networks {
            let effective = mask | 0xFFFF_FC00
            let base = address & effective, broadcast = base | ~effective
            guard broadcast > base + 1 else { continue }
            for host in (base + 1)..<broadcast where seen.insert(host).inserted { output.append(host) }
        }
        return output
    }

    static func string(_ value: UInt32) -> String {
        [(value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255].map(String.init).joined(separator: ".")
    }

    /// Hosts on the local network accepting TCP on `port`, found with non-blocking connects polled together
    /// in batches on a background thread. `excluding` drops our own listener when the port is ours.
    static func scan(port: UInt16, excluding: Set<String> = [], timeoutMilliseconds: Int32 = 500) async -> [String] {
        let hosts = candidates(networks: localNetworks()).map(string).filter { !excluding.contains($0) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var found: [String] = []
                for start in stride(from: 0, to: hosts.count, by: 256) {
                    found += probe(Array(hosts[start..<min(hosts.count, start + 256)]), port: port, timeoutMilliseconds: timeoutMilliseconds)
                }
                continuation.resume(returning: found.sorted())
            }
        }
    }

    /// Starts a non-blocking connect to every host, then polls them all until each settles or time runs out.
    /// Sockets only detect listeners and are closed right away.
    static func probe(_ hosts: [String], port: UInt16, timeoutMilliseconds: Int32) -> [String] {
        var pending: [(fd: Int32, host: String)] = [], found: [String] = []
        defer { for item in pending { close(item.fd) } }
        for host in hosts {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { close(fd); continue }
            let started = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if started == 0 { found.append(host); close(fd) }
            else if errno == EINPROGRESS { pending.append((fd, host)) }
            else { close(fd) }
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
        while !pending.isEmpty {
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            guard remaining > 0 else { break }
            var polls = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            guard poll(&polls, nfds_t(polls.count), remaining) > 0 else { break }
            var still: [(fd: Int32, host: String)] = []
            for (index, item) in pending.enumerated() {
                guard polls[index].revents != 0 else { still.append(item); continue }
                var failure: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(item.fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0 { found.append(item.host) }
                close(item.fd)
            }
            pending = still
        }
        return found
    }
}

extension SoulseekSession {
    /// Where to dial a peer the server placed at `host`. Peers at our own public address are looked up on the
    /// local network; everyone else, and peers we cannot find locally, keep the server's address.
    func route(user: String, host: String, port: UInt16) async -> String {
        guard let publicAddress, host == publicAddress, LANRoute.isPublic(host) else { return host }
        if let cached = lanHosts[user], cached.port == port { return cached.host }
        if let miss = lanMisses[user], miss.port == port, miss.date.timeIntervalSinceNow > -60 { return host }
        let ownPort = listener?.port?.rawValue
        let own = Set(LANRoute.localNetworks().map { LANRoute.string($0.address) })
        let found = await LANRoute.scan(port: port, excluding: port == ownPort ? own : [])
        guard let local = found.first else {
            lanMisses[user] = (port, Date())
            await report("\(user) shares your public address but wasn’t found on the local network.")
            return host
        }
        lanHosts[user] = (local, port)
        await report("Reaching \(user) on the local network (same router).")
        return local
    }
}
