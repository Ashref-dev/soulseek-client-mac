import Foundation
import Network
import CryptoKit
import OSLog

public actor SoulseekSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    let channel: EventChannel
    var generation: UInt64 = 0
    var server: FramedConnection?
    var serverTask: Task<Void, Never>?
    var listener: NWListener?
    var peers: [String: FramedConnection] = [:]
    var peerDirections: [String: Bool] = [:]
    var peerTasks: [String: Task<Void, Never>] = [:]
    var pending: [String: [(UInt32, Data)]] = [:]
    var addresses: [String: (String, UInt16)] = [:]
    var addressWaiters: [String: [CheckedContinuation<(String, UInt16), Error>]] = [:]
    var rendezvous: [UInt32: (String, String)] = [:]
    var fileWaiters: [UInt32: CheckedContinuation<FramedConnection, Error>] = [:]
    var keepaliveTask: Task<Void, Never>?
    var connecting: Set<String> = []
    var incomingHandshakes = 0
    var peerDials: Set<String> = []
    var peerDialSockets: [String: TCPConnection] = [:]
    var fileConnections: [ObjectIdentifier: FramedConnection] = [:]
    var distributed: FramedConnection?
    var expectedLibraries: Set<String> = []
    var expectedFolders: [String: Set<UInt32>] = [:]
    let peerReceiveBudget = ReceiveBudget()
    var activeSearches: Set<UInt32> = []
    var expectedUserInfo: Set<String> = []
    var username = ""
    var token: UInt32 = UInt32.random(in: 1000...UInt32.max / 2)
    let logger = Logger(subsystem: "tn.ashref.arpeggio", category: "Protocol")
    public init() {
        let channel = EventChannel(); self.channel = channel
        events = AsyncStream(unfolding: { await channel.next() }, onCancel: { Task { await channel.close() } })
    }
    public func currentGeneration() -> UInt64 { generation }
    func emit(_ event: SoulseekEvent) async { await channel.send(SessionEvent(generation: generation, account: username, event: event)) }
    public func nextToken() -> UInt32 { token &+= 1; return token }
    public func retireSearch(_ token: UInt32) { activeSearches.remove(token) }
    public func acknowledgeMessage(_ id: UInt32, generation expected: UInt64) async throws {
        var writer = WireWriter(); writer.uint(id); try await send(code: 23, payload: writer.data, generation: expected)
    }
    public func peerMatchesServerAddress(_ user: String) async -> Bool {
        guard let peer = peers[user], let remoteHost = peer.socket.remoteHost else { return false }
        do { return try await address(for: user).0 == remoteHost } catch { return false }
    }
    public func fileMatchesServerAddress(_ user: String, connection: FramedConnection) async -> Bool {
        guard let remoteHost = connection.socket.remoteHost else { return false }
        do { return try await address(for: user).0 == remoteHost } catch { return false }
    }
    public func connect(host: String, port: UInt16, user: String, password: String, listeningPort: UInt16) async throws {
        let attempt = generation &+ 1
        await disconnect()
        try requireGeneration(attempt)
        guard !password.isEmpty else { throw ProtocolError.invalid("Enter your Soulseek password.") }
        try LoginIdentity.validateUsername(user)
        username = user
        await emit(.state(.connecting))
        do {
            try requireGeneration(attempt)
            try await startListener(port: listeningPort)
            try requireGeneration(attempt)
            let socket = try TCPConnection(host: host, port: port)
            let connection = FramedConnection(socket)
            server = connection
            try await socket.start()
            try requireGeneration(attempt)
            var login = WireWriter()
            login.string(user); login.string(password); login.uint(177)
            login.string(Insecure.MD5.hash(data: Data((user + password).utf8)).map { String(format: "%02x", $0) }.joined())
            login.uint(1)
            try await connection.send(code: 1, payload: login.data)
            let (code, response) = try await connection.read(timeout: 20)
            try requireGeneration(attempt)
            guard code == 1 else { throw ProtocolError.invalid("Unexpected login response.") }
            var reader = WireReader(response)
            let success = try reader.byte() != 0
            let greeting = try reader.string()
            guard success else {
                let message: String
                switch greeting {
                case "INVALIDPASS": message = "Your Soulseek password wasn’t accepted. Passwords are case-sensitive."
                case "INVALIDUSERNAME": message = "That Soulseek username isn’t valid. Check the spelling and try again."
                case "EMPTYPASSWORD": message = "Enter your Soulseek password."
                case "SVRFULL": message = "The Soulseek server is full. Try again shortly."
                case "SVRPRIVATE": message = "The server is not accepting new accounts right now. Use an existing account or try again later."
                case "INVALIDVERSION": message = "The server rejected Arpeggio’s client version. Please report this compatibility issue."
                default: message = "Soulseek rejected sign-in: \(String(greeting.prefix(128)))"
                }
                throw ProtocolError.invalid(message)
            }
            var wait = WireWriter(); wait.uint(UInt32(listeningPort))
            try await connection.send(code: 2, payload: wait.data)
            try requireGeneration(attempt)
            try await connection.send(code: 71, payload: Data([1]))
            var branchRoot = WireWriter(); branchRoot.string(user)
            try await connection.send(code: 127, payload: branchRoot.data)
            var branchLevel = WireWriter(); branchLevel.uint(0)
            try await connection.send(code: 126, payload: branchLevel.data)
            try await connection.send(code: 100, payload: Data([0]))
            var status = WireWriter(); status.uint(2)
            try await connection.send(code: 28, payload: status.data)
            try requireGeneration(attempt)
            await emit(.state(.connected))
            try requireGeneration(attempt)
            serverTask = Task { [weak self] in await self?.readServer(connection, generation: attempt) }
            keepaliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)); try Task.checkCancellation(); try await self?.send(code: 32) }
                    catch { return }
                }
            }
        } catch {
            let message = error is ProtocolError || error is CancellationError ? error.localizedDescription : "Couldn’t connect to \(host):\(port). Check the configured server and your network connection."
            if attempt == generation {
                await disconnect()
                await emit(.diagnostic("Connection detail: \(error.localizedDescription)"))
                await emit(.state(.failed(message)))
            }
            throw ProtocolError.invalid(message)
        }
    }
    func requireGeneration(_ attempt: UInt64) throws { guard attempt == generation else { throw CancellationError() } }
    public func disconnect() async {
        generation &+= 1
        serverTask?.cancel(); serverTask = nil
        keepaliveTask?.cancel(); keepaliveTask = nil
        server?.socket.cancel(); server = nil
        listener?.cancel(); listener = nil
        for socket in peerDialSockets.values { socket.cancel() }
        peerDialSockets.removeAll(); peerDials.removeAll()
        distributed?.socket.cancel(); distributed = nil
        for connection in fileConnections.values { connection.socket.cancel() }
        fileConnections.removeAll(); expectedLibraries.removeAll(); activeSearches.removeAll(); expectedUserInfo.removeAll()
        expectedFolders.removeAll()
        for peer in peers.values { peer.socket.cancel() }
        for task in peerTasks.values { task.cancel() }
        peers.removeAll(); peerDirections.removeAll(); peerTasks.removeAll(); pending.removeAll(); connecting.removeAll(); rendezvous.removeAll(); addresses.removeAll()
        for waiters in addressWaiters.values { for waiter in waiters { waiter.resume(throwing: ProtocolError.disconnected) } }
        addressWaiters.removeAll()
        for waiter in fileWaiters.values { waiter.resume(throwing: ProtocolError.disconnected) }
        fileWaiters.removeAll()
        await emit(.state(.offline))
    }
    public func send(code: UInt32, payload: Data = Data(), generation expected: UInt64? = nil) async throws {
        if let expected { try requireGeneration(expected) }
        guard let server else { throw ProtocolError.disconnected }
        try await server.send(code: code, payload: payload)
    }
    public func search(query: String, wishlist: Bool = false, user: String? = nil, token suppliedToken: UInt32? = nil) async throws -> UInt32 {
        let id = suppliedToken ?? nextToken()
        activeSearches.insert(id)
        if activeSearches.count > 100 { activeSearches.remove(activeSearches.min() ?? id) }
        var writer = WireWriter()
        if let user { writer.string(user) }
        writer.uint(id); writer.string(query)
        try await send(code: user != nil ? 42 : wishlist ? 103 : 26, payload: writer.data)
        return id
    }
    public func peerSend(user: String, code: UInt32, payload: Data = Data()) async throws {
        guard !user.isEmpty, user.utf8.count <= 256 else { throw ProtocolError.invalid("Invalid username.") }
        if code == 4 { expectedLibraries.insert(user) }
        if code == 15 { expectedUserInfo.insert(user) }
        if code == 36 {
            var reader = WireReader(payload)
            let token = try reader.uint()
            guard expectedFolders[user, default: []].count < 100 else { throw ProtocolError.oversized }
            expectedFolders[user, default: []].insert(token)
            let attempt = generation
            Task {
                try? await Task.sleep(for: .seconds(30))
                guard attempt == self.generation else { return }
                self.expectedFolders[user]?.remove(token)
            }
        }
        if let peer = peers[user] { try await peer.send(code: code, payload: payload); return }
        guard server != nil else { throw ProtocolError.disconnected }
        guard pending.count < 128, pending[user, default: []].count < 100 else { throw ProtocolError.oversized }
        pending[user, default: []].append((code, payload))
        guard !connecting.contains(user) else { return }
        connecting.insert(user)
        let attempt = generation
        let id = nextToken(); rendezvous[id] = (user, "P")
        var address = WireWriter(); address.string(user)
        try await send(code: 3, payload: address.data)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, await self.generation == attempt else { return }; await self.expirePeer(user)
        }
    }
    func expirePeer(_ user: String) async {
        guard connecting.remove(user) != nil else { return }
        pending.removeValue(forKey: user)
        rendezvous = rendezvous.filter { $0.value.0 != user || $0.value.1 != "P" }
        await emit(.diagnostic("Couldn’t connect to \(user). They may be offline or unable to accept incoming connections."))
        await emit(.peerUnavailable(user))
    }
    public func openFileConnection(user: String, transferToken: UInt32) async throws -> FramedConnection {
        guard fileWaiters.count < 40 else { throw ProtocolError.oversized }
        let id = nextToken()
        rendezvous[id] = (user, "F")
        let connection: FramedConnection = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
            guard !Task.isCancelled else { waiter.resume(throwing: CancellationError()); return }
            fileWaiters[id] = waiter
            Task {
                do {
                    let address = try await self.address(for: user)
                    let socket = try TCPConnection(host: address.0, port: address.1)
                    do {
                        try await socket.start()
                        let direct = FramedConnection(socket)
                        var initPayload = WireWriter(); initPayload.string(self.username); initPayload.string("F"); initPayload.uint(0)
                        try await direct.send(code: 1, payload: initPayload.data, narrow: true)
                        self.fulfillFile(id, connection: direct)
                    } catch {
                        socket.cancel()
                        var indirect = WireWriter(); indirect.uint(id); indirect.string(user); indirect.string("F")
                        try await self.send(code: 18, payload: indirect.data)
                    }
                } catch { self.failFile(id, error: error) }
            }
            Task { try? await Task.sleep(for: .seconds(25)); self.failFile(id, error: ProtocolError.invalid("Couldn’t establish a file connection. Check port forwarding on both clients.")) }
            }
        } onCancel: { Task { await self.failFile(id, error: CancellationError()) } }
        do {
            try Task.checkCancellation()
            guard fileConnections.count < 40 else { throw ProtocolError.oversized }
            fileConnections[ObjectIdentifier(connection)] = connection
            var header = WireWriter(); header.uint(transferToken)
            try await connection.socket.send(header.data)
            return connection
        } catch { connection.socket.cancel(); fileConnections.removeValue(forKey: ObjectIdentifier(connection)); throw error }
    }
    public func releaseFileConnection(_ connection: FramedConnection) { fileConnections.removeValue(forKey: ObjectIdentifier(connection)) }
    public func shutdown() async {
        let readers = Array(peerTasks.values) + [serverTask].compactMap { $0 }
        await channel.close()
        await disconnect()
        for task in readers { await task.value }
    }
    func fulfillFile(_ id: UInt32, connection: FramedConnection) {
        rendezvous.removeValue(forKey: id)
        guard let waiter = fileWaiters.removeValue(forKey: id) else { connection.socket.cancel(); return }
        waiter.resume(returning: connection)
    }
    func failFile(_ id: UInt32, error: Error) {
        rendezvous.removeValue(forKey: id)
        fileWaiters.removeValue(forKey: id)?.resume(throwing: error)
    }
    func address(for user: String) async throws -> (String, UInt16) {
        if let address = addresses[user] { return address }
        return try await withCheckedThrowingContinuation { waiter in
            addressWaiters[user, default: []].append(waiter)
            Task {
                do { var writer = WireWriter(); writer.string(user); try await self.send(code: 3, payload: writer.data) }
                catch { self.failAddress(user, error: error) }
            }
            Task { try? await Task.sleep(for: .seconds(20)); self.failAddress(user, error: ProtocolError.invalid("User address lookup timed out.")) }
        }
    }
    func failAddress(_ user: String, error: Error) {
        for waiter in addressWaiters.removeValue(forKey: user) ?? [] { waiter.resume(throwing: error) }
    }
}
