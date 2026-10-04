import Foundation
import Network
import SoulseekCore

public actor MockSoulseekServer {
    let listener: NWListener
    var clients: [String: FramedConnection] = [:]
    var ports: [String: UInt32] = [:]
    var shares: [String: UInt32] = [:]
    var messageID: UInt32 = 0
    var rooms: [String: Set<String>] = [:]
    public var trace: [String] = []
    let loginDelay: Duration
    let forceIndirect: Set<String>
    private init(listener: NWListener, loginDelay: Duration, forceIndirect: Set<String>) {
        self.listener = listener; self.loginDelay = loginDelay; self.forceIndirect = forceIndirect
    }
    public static func start(loginDelay: Duration = .zero, forceIndirect: Set<String> = []) async throws -> MockSoulseekServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = MockSoulseekServer(listener: listener, loginDelay: loginDelay, forceIndirect: forceIndirect)
        listener.newConnectionHandler = { connection in
            Task { await server.handle(TCPConnection(incoming: connection)) }
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; ready.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "arpeggio.tests.server"))
        }
        return server
    }
    public func port() throws -> UInt16 {
        guard let port = listener.port else { throw ProtocolError.invalid("Fixture listener missing port.") }
        return port.rawValue
    }
    public func stop() { listener.cancel(); for client in clients.values { client.socket.cancel() }; clients.removeAll() }
    func handle(_ socket: TCPConnection) async {
        let connection = FramedConnection(socket)
        var user = ""
        do {
            try await socket.start()
            while true {
                let (code, payload) = try await connection.read()
                trace.append("\(user):\(code)")
                var reader = WireReader(payload)
                switch code {
                case 1:
                    user = try reader.string(); _ = try reader.string()
                    if loginDelay > .zero { try await Task.sleep(for: loginDelay) }
                    clients[user] = connection
                    var response = WireWriter(); response.byte(1); response.string("Fixture server")
                    response.uint(0x7f000001); response.string(""); response.byte(0)
                    try await connection.send(code: 1, payload: response.data)
                    var interval = WireWriter(); interval.uint(60)
                    try await connection.send(code: 104, payload: interval.data)
                case 2: ports[user] = try reader.uint()
                case 35:
                    _ = try reader.uint(); shares[user] = try reader.uint()
                case 36:
                    let target = try reader.string()
                    if let files = shares[target] {
                        var response = WireWriter(); response.string(target); response.uint(0); response.uint(0); response.uint(0); response.uint(files)
                        try await connection.send(code: 36, payload: response.data)
                    }
                case 3:
                    let target = try reader.string()
                    var response = WireWriter(); response.string(target); response.uint(0x7f000001)
                    response.uint(forceIndirect.contains(target) ? 1 : (ports[target] ?? 0)); response.uint(0); response.byte(0); response.byte(0)
                    try await connection.send(code: 3, payload: response.data)
                case 18:
                    let token = try reader.uint(); let target = try reader.string(); let type = try reader.string()
                    if let peer = clients[target] {
                        var response = WireWriter(); response.string(user); response.string(type); response.uint(0x7f000001)
                        response.uint(ports[user] ?? 0); response.uint(token); response.byte(0); response.uint(0); response.uint(0)
                        try await peer.send(code: 18, payload: response.data)
                    }
                case 26, 103:
                    let token = try reader.uint(); let query = try reader.string()
                    for (target, client) in clients where target != user {
                        var request = WireWriter(); request.string(user); request.uint(token); request.string(query)
                        try await client.send(code: 26, payload: request.data)
                    }
                case 22:
                    let target = try reader.string(); let text = try reader.string(); messageID += 1
                    var message = WireWriter(); message.uint(messageID); message.uint(UInt32(Date().timeIntervalSince1970))
                    message.string(user); message.string(text); message.byte(1)
                    try await clients[target]?.send(code: 22, payload: message.data)
                case 64:
                    var response = WireWriter(); response.uint(1); response.string("Arpeggio Test Room"); response.uint(1); response.uint(2)
                    try await connection.send(code: 64, payload: response.data)
                case 14:
                    let room = try reader.string(); rooms[room, default: []].insert(user)
                    var response = WireWriter(); response.string(room); response.uint(UInt32(rooms[room, default: []].count))
                    for member in rooms[room, default: []].sorted() { response.string(member) }
                    try await connection.send(code: 14, payload: response.data)
                case 13:
                    let room = try reader.string(); let text = try reader.string()
                    var response = WireWriter(); response.string(room); response.string(user); response.string(text)
                    for member in rooms[room, default: []] { try await clients[member]?.send(code: 13, payload: response.data) }
                default: break
                }
            }
        } catch { trace.append("\(user):error:\(error.localizedDescription)"); socket.cancel(); clients.removeValue(forKey: user) }
    }
}
