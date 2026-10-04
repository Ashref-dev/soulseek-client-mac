import Foundation
import Network
import Testing
import SoulseekCore
@testable import ArpeggioServices

private actor RouterHTTPFixture {
    let listener: NWListener
    var requests = 0
    private let replies: [Data]
    private var sockets: [TCPConnection] = []
    private init(listener: NWListener, replies: [Data]) { self.listener = listener; self.replies = replies }
    static func start(_ replies: [Data]) async throws -> RouterHTTPFixture {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let fixture = RouterHTTPFixture(listener: listener, replies: replies)
        listener.newConnectionHandler = { connection in Task { await fixture.handle(TCPConnection(incoming: connection)) } }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; ready.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "arpeggio.tests.http"))
        }
        return fixture
    }
    func url() throws -> URL {
        guard let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/control") else { throw ProtocolError.invalid("Fixture missing URL") }
        return url
    }
    func handle(_ socket: TCPConnection) async {
        sockets.append(socket)
        defer { socket.cancel() }
        do {
            try await socket.start(); _ = try await socket.receive(timeout: 5)
            let index = requests; requests += 1
            guard !replies.isEmpty else { return }
            try await socket.send(replies[min(index, replies.count - 1)])
        } catch { }
    }
    func stop() { listener.cancel(); for socket in sockets { socket.cancel() }; sockets.removeAll() }
    static func response(status: Int = 200, body: String, headers: String = "") -> Data {
        let bytes = Data(body.utf8)
        return Data("HTTP/1.1 \(status) Fixture\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\(headers)\r\n".utf8) + bytes
    }
}

@Test func routerHTTPBoundsBodiesAndNeverFollowsRedirects() async throws {
    let target = try await RouterHTTPFixture.start([RouterHTTPFixture.response(body: "not reachable through redirect")])
    let destination = try await target.url()
    let redirect = try await RouterHTTPFixture.start([RouterHTTPFixture.response(status: 302, body: "", headers: "Location: \(destination.absoluteString)\r\n")])
    #expect(await PortMapper.fetch(try await redirect.url(), limit: 100) == nil)
    #expect(await target.requests == 0)
    let oversized = try await RouterHTTPFixture.start([RouterHTTPFixture.response(body: String(repeating: "x", count: 4097))])
    #expect(await PortMapper.fetch(try await oversized.url(), limit: 4096) == nil)
    #expect(await PortMapper.fetch(destination, limit: -1) == nil)
    #expect(await target.requests == 0)
    await redirect.stop(); await target.stop(); await oversized.stop()
}

@Test func upnpPermanentLeaseFallbackRequiresSpecific725Fault() async throws {
    let service = "urn:schemas-upnp-org:service:WANIPConnection:1"
    let fault = "<s:Envelope xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'><s:Body><s:Fault><detail><UPnPError><errorCode>725</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
    let success = "<s:Envelope xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'><s:Body><u:AddPortMappingResponse xmlns:u='\(service)'/></s:Body></s:Envelope>"
    let fixture = try await RouterHTTPFixture.start([RouterHTTPFixture.response(status: 500, body: fault), RouterHTTPFixture.response(body: success)])
    #expect(await PortMapper.upnpAdd(device: PortMapper.UPnPDevice(control: try await fixture.url(), service: service, client: "127.0.0.1"), port: 2234))
    #expect(await fixture.requests == 2)
    let denied = try await RouterHTTPFixture.start([RouterHTTPFixture.response(status: 500, body: fault.replacingOccurrences(of: "725", with: "718"))])
    #expect(await PortMapper.upnpAdd(device: PortMapper.UPnPDevice(control: try await denied.url(), service: service, client: "127.0.0.1"), port: 2234) == false)
    #expect(await denied.requests == 1)
    await fixture.stop(); await denied.stop()
}
