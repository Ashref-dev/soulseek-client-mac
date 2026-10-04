import Foundation
import Darwin
import SoulseekCore

public enum PortMappingStatus: Sendable, Equatable {
    case idle, disabled, mapping
    case mapped(method: String, port: UInt16, externalAddress: String?)
    case unavailable(String)
}

/// Opens the listening port on the home router with NAT-PMP (Apple and most modern routers) or UPnP IGD,
/// so peers can connect to us directly. Mappings are leased and renewed; they are removed on disconnect.
actor PortMapper {
    enum Method: Sendable {
        case natPMP(gateway: String)
        case upnp(control: URL, service: String, client: String)
    }

    let port: UInt16
    private(set) var method: Method?
    private(set) var renewalSeconds: Double = 1800
    static let lease: UInt32 = 3600

    init(port: UInt16) { self.port = port }

    func map(natPMP: Bool = true, upnp: Bool = true) async -> PortMappingStatus {
        guard port > 0 else { return .unavailable("Invalid listening port.") }
        guard natPMP || upnp else { return .disabled }
        if natPMP, let gateway = await Self.defaultGateway(), let external = await Self.natPMP(gateway: gateway, port: port, lifetime: Self.lease) {
            method = .natPMP(gateway: gateway)
            renewalSeconds = Double(external.lifetime) / 2
            return .mapped(method: "NAT-PMP", port: external.port, externalAddress: await Self.natPMPAddress(gateway: gateway))
        }
        if upnp, let device = await Self.discoverUPnP(), await Self.upnpAdd(device: device, port: port) {
            method = .upnp(control: device.control, service: device.service, client: device.client)
            return .mapped(method: "UPnP", port: port, externalAddress: await Self.upnpExternalAddress(device: device))
        }
        method = nil
        let protocols = [natPMP ? "NAT-PMP" : nil, upnp ? "UPnP" : nil].compactMap { $0 }.joined(separator: " or ")
        return .unavailable("No valid mapping acknowledgment from \(protocols). This does not prove your router is incompatible. Check firewall, VPN and router settings, or forward TCP port \(port) manually.")
    }

    func unmap() async {
        switch method {
        case .natPMP(let gateway): _ = await Self.natPMP(gateway: gateway, port: port, lifetime: 0)
        case .upnp(let control, let service, let client):
            _ = await Self.soap(UPnPDevice(control: control, service: service, client: client), action: "DeletePortMapping",
                                arguments: [("NewRemoteHost", ""), ("NewExternalPort", "\(port)"), ("NewProtocol", "TCP")])
        case nil: break
        }
        method = nil
    }

    // MARK: NAT-PMP (RFC 6886)

    static func natPMP(gateway: String, port: UInt16, lifetime: UInt32) async -> (port: UInt16, lifetime: UInt32)? {
        guard port > 0 else { return nil }
        var request = Data([0, 2, 0, 0])
        request.append(contentsOf: port.bigEndianBytes); request.append(contentsOf: (lifetime == 0 ? 0 : port).bigEndianBytes)
        request.append(contentsOf: lifetime.bigEndianBytes)
        guard let reply = await UDP.exchange(host: gateway, port: 5351, payload: request, expect: 16) else { return nil }
        if lifetime > 0, reply.count == 16, reply[0] == 0, reply[1] == 130, reply.uint16(at: 2) == 0,
           reply.uint16(at: 8) == port, reply.uint16(at: 10) != port {
            var deletion = Data([0, 2, 0, 0]); deletion.append(contentsOf: port.bigEndianBytes)
            deletion.append(contentsOf: UInt16(0).bigEndianBytes); deletion.append(contentsOf: UInt32(0).bigEndianBytes)
            _ = await UDP.exchange(host: gateway, port: 5351, payload: deletion, expect: 16)
            return nil
        }
        guard validNATPMPReply(reply, port: port, deleting: lifetime == 0) else { return nil }
        return (reply.uint16(at: 10), reply[12..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }
    static func validNATPMPReply(_ reply: Data, port: UInt16, deleting: Bool) -> Bool {
        guard port > 0, reply.count == 16, reply[0] == 0, reply[1] == 130, reply.uint16(at: 2) == 0,
              reply.uint16(at: 8) == port, reply.uint16(at: 10) == (deleting ? 0 : port) else { return false }
        let lifetime = reply[12..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return deleting ? lifetime == 0 : lifetime > 0
    }

    static func natPMPAddress(gateway: String) async -> String? {
        guard let reply = await UDP.exchange(host: gateway, port: 5351, payload: Data([0, 0]), expect: 12),
              reply.count == 12, reply[0] == 0, reply[1] == 128, reply.uint16(at: 2) == 0 else { return nil }
        return reply[8..<12].map(String.init).joined(separator: ".")
    }

    static func defaultGateway() async -> String? {
        await UDP.blocking {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            process.arguments = ["-n", "get", "default"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let line = output.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("gateway:") }
            guard let value = line?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                  value.split(separator: ".").count == 4 else { return nil }
            return value
        }
    }

    // MARK: UPnP IGD

    struct UPnPDevice: Sendable {
        let control: URL
        let service: String
        let client: String
    }

    static func discoverUPnP() async -> UPnPDevice? {
        let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        let replies = await UDP.collect(host: "239.255.255.250", port: 1900, payload: Data(search.utf8), seconds: 2.5)
        var locations: [URL] = []
        for (reply, sender) in replies {
            let text = String(decoding: reply, as: UTF8.self)
            guard let line = text.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("location:") }),
                  let url = URL(string: line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)),
                  isDeviceURL(url, host: sender), !locations.contains(url) else { continue }
            locations.append(url)
            if locations.count == 4 { break }
        }
        for location in locations {
            guard let host = location.host, let data = await fetch(location, limit: 256 * 1024),
                  let service = UPnPDescription.read(data, location: location),
                  let client = await UDP.localAddress(toward: host) else { continue }
            return UPnPDevice(control: service.control, service: service.type, client: client)
        }
        return nil
    }

    /// Router URLs must point back at the device that answered discovery, so a hostile reply on the
    /// local network can't make Arpeggio send requests anywhere else.
    static func isDeviceURL(_ url: URL, host: String) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host == host && url.user == nil && url.password == nil && url.fragment == nil && (url.port.map { (1...65535).contains($0) } ?? true)
    }

    static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 10
        return configuration
    }(), delegate: NoRedirects(), delegateQueue: nil)

    static func fetch(_ url: URL, limit: Int) async -> Data? {
        await boundedResponse(URLRequest(url: url), limit: limit)
    }
    static func boundedResponse(_ request: URLRequest, limit: Int, allowLeaseFault: Bool = false) async -> Data? {
        guard limit > 0, limit <= 256 * 1024,
              let (bytes, response) = try? await session.bytes(for: request), let status = (response as? HTTPURLResponse)?.statusCode,
              status == 200 || (allowLeaseFault && status == 500) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch { return nil }
        if status == 500, SOAPResponse.faultCode(data) != 725 { return nil }
        return data
    }

    static func upnpAdd(device: UPnPDevice, port: UInt16) async -> Bool {
        guard port > 0 else { return false }
        for lease in [lease, 0] {
            guard let response = await soap(device, action: "AddPortMapping", arguments: [
                ("NewRemoteHost", ""), ("NewExternalPort", "\(port)"), ("NewProtocol", "TCP"), ("NewInternalPort", "\(port)"),
                ("NewInternalClient", device.client), ("NewEnabled", "1"), ("NewPortMappingDescription", "Arpeggio"),
                ("NewLeaseDuration", "\(lease)")], allowLeaseFault: lease > 0) else { return false }
            if SOAPResponse.accepts(Data(response.utf8), action: "AddPortMapping", service: device.service) { return true }
            guard lease > 0, SOAPResponse.faultCode(Data(response.utf8)) == 725 else { return false }
        }
        return false
    }

    static func upnpExternalAddress(device: UPnPDevice) async -> String? {
        (await soap(device, action: "GetExternalIPAddress", arguments: []))?.between("<NewExternalIPAddress>", "</NewExternalIPAddress>")
    }

    static func soap(_ device: UPnPDevice, action: String, arguments: [(String, String)], allowLeaseFault: Bool = false) async -> String? {
        guard UPnPDescription.allowedTypes.contains(device.service), ["AddPortMapping", "DeletePortMapping", "GetExternalIPAddress"].contains(action) else { return nil }
        let body = arguments.map { "<\($0.0)>\(Self.xmlEscape($0.1))</\($0.0)>" }.joined()
        let envelope = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(device.service)">\(body)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: device.control, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(device.service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(envelope.utf8)
        guard let data = await boundedResponse(request, limit: 64 * 1024, allowLeaseFault: allowLeaseFault),
              SOAPResponse.accepts(data, action: action, service: device.service) || (allowLeaseFault && SOAPResponse.faultCode(data) == 725),
              let reply = String(data: data, encoding: .utf8) else { return nil }
        return reply
    }
    static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Small blocking UDP helpers run off the cooperative thread pool.
enum UDP {
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    static func exchange(host: String, port: UInt16, payload: Data, expect: Int) async -> Data? {
        await blocking {
            for timeout in [0.25, 0.5, 1.0] {
                if let reply = receive(host: host, port: port, payload: payload, seconds: timeout, all: false).first,
                   reply.1 == host, reply.0.count >= expect { return reply.0 }
            }
            return nil
        }
    }

    static func collect(host: String, port: UInt16, payload: Data, seconds: Double) async -> [(Data, String)] {
        await blocking { receive(host: host, port: port, payload: payload, seconds: seconds, all: true) }
    }

    static func localAddress(toward host: String) async -> String? {
        await blocking {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var remote = sockaddr_in(host: host, port: 9)
            guard withUnsafePointer(to: &remote, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return nil }
            var local = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard withUnsafeMutablePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    private static func receive(host: String, port: UInt16, payload: Data, seconds: Double, all: Bool) -> [(Data, String)] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(host: host, port: port)
        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
        guard sent == payload.count else { return [] }
        var replies: [(Data, String)] = []
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline, replies.count < 32 {
            var sender = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
            if count > 0 {
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sender.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
                let senderHost = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !all, (senderHost != host || UInt16(bigEndian: sender.sin_port) != port) { continue }
                replies.append((Data(buffer[0..<count]), senderHost))
                if !all { break }
            }
        }
        return replies
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

private extension sockaddr_in {
    init(host: String, port: UInt16) {
        self.init()
        sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin_family = sa_family_t(AF_INET)
        sin_port = port.bigEndian
        inet_pton(AF_INET, host, &sin_addr)
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian, Array.init) }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 { UInt16(self[startIndex + offset]) << 8 | UInt16(self[startIndex + offset + 1]) }
}

private extension String {
    func between(_ start: String, _ end: String) -> String? {
        guard let lower = range(of: start), let upper = range(of: end, range: lower.upperBound..<endIndex) else { return nil }
        return String(self[lower.upperBound..<upper.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AppModel {
    func mapListeningPort() {
        guard settings.mapsPorts else { portMapping = .disabled; return }
        guard !settings.isLocalServer else { portMapping = .unavailable("Local fixture connection. Router discovery skipped; external reachability unverified."); return }
        let port = settings.listeningPort
        let revision = loginRevision
        portMapping = .mapping
        Task { [weak self] in
            guard let self else { return }
            let mapper = PortMapper(port: port)
            let status = await mapper.map(natPMP: self.settings.usesNATPMP, upnp: self.settings.usesUPnP)
            guard revision == self.loginRevision, self.connection == .connected else { await mapper.unmap(); return }
            self.portMapper = mapper; self.portMapping = status
            if case .mapped(let method, let external, let address) = status {
                self.log("Router acknowledged \(method) mapping (external \(address ?? "address unknown"):\(external)). External reachability is unverified.")
                self.scheduleMappingRenewal(revision: revision, seconds: await mapper.renewalSeconds)
            } else if case .unavailable(let reason) = status { self.log(reason) }
        }
    }

    private func scheduleMappingRenewal(revision: UInt64, seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, revision == self.loginRevision, self.connection == .connected else { return }
            self.mapListeningPort()
        }
    }

    func removePortMapping(resetStatus: Bool = true) async {
        let mapper = portMapper; portMapper = nil
        await mapper?.unmap()
        if resetStatus { portMapping = settings.mapsPorts ? .idle : .disabled }
    }
}
