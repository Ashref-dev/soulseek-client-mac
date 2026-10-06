import Foundation
import Network

extension SoulseekSession {
    func startListener(port: UInt16) async throws {
        guard port >= 1024, let endpoint = NWEndpoint.Port(rawValue: port) else { throw ProtocolError.invalid("Choose a listening port between 1024 and 65535 in Settings › Account.") }
        let listener = try NWListener(using: .tcp, on: endpoint)
        let attempt = generation
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(TCPConnection(incoming: connection), generation: attempt) }
        }
        self.listener = listener
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; ready.resume()
                case .failed:
                    listener.stateUpdateHandler = nil; listener.cancel()
                    ready.resume(throwing: ProtocolError.invalid("Listening port \(port) is unavailable. Choose a different port in Settings › Account."))
                case .cancelled: listener.stateUpdateHandler = nil; ready.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "tn.ashref.arpeggio.listener"))
        }
    }
    func report(_ text: String) async { await emit(.diagnostic(text)) }
    func takePendingPeerMessages(_ user: String) -> [PendingPeerMessage] {
        (pending.removeValue(forKey: user) ?? []).filter { $0.lease?.isValid != false }
    }
    func accept(_ socket: TCPConnection, generation attempt: UInt64) async {
        guard attempt == generation else { socket.cancel(); return }
        guard incomingHandshakes < 32 else { socket.cancel(); return }
        incomingHandshakes += 1
        defer { incomingHandshakes -= 1 }
        do {
            try await socket.start()
            let connection = FramedConnection(socket)
            let (code, payload) = try await connection.read(narrow: true, timeout: 20)
            try requireGeneration(attempt)
            var reader = WireReader(payload)
            if code == 1 {
                let user = try reader.string(); let type = try reader.string(); _ = try reader.uint()
                guard !user.isEmpty, user.utf8.count <= 256 else { throw ProtocolError.invalid("Invalid peer identity.") }
                try await attach(connection, user: user, type: type, initiated: false)
            } else if code == 0 {
                let id = try reader.uint()
                guard let (user, type) = rendezvous[id] else { throw ProtocolError.invalid("Unknown callback token.") }
                if type == "F" { fulfillFile(id, connection: connection) }
                else { rendezvous.removeValue(forKey: id); try await attach(connection, user: user, type: type, initiated: false) }
            } else { throw ProtocolError.invalid("Unknown peer handshake.") }
        } catch { socket.cancel(); logger.debug("Incoming peer rejected: \(error.localizedDescription, privacy: .public)") }
    }
    func connectPeer(user: String, host: String, port: UInt16, type: String, callback: UInt32?, generation expected: UInt64? = nil) async {
        let attempt = expected ?? generation
        guard attempt == generation else { return }
        let dial = "\(attempt)\u{1F}\(user)\u{1F}\(type)\u{1F}\(callback.map(String.init) ?? "direct")"
        guard peerDials.count < 32, peerDials.insert(dial).inserted else { return }
        defer { peerDials.remove(dial); peerDialSockets.removeValue(forKey: dial) }
        do {
            let socket = try TCPConnection(host: host, port: port)
            peerDialSockets[dial] = socket
            do {
                try await socket.start()
                try requireGeneration(attempt)
                let connection = FramedConnection(socket)
                var writer = WireWriter()
                if let callback { writer.uint(callback) }
                else { writer.string(username); writer.string(type); writer.uint(0) }
                try await connection.send(code: callback == nil ? 1 : 0, payload: writer.data, narrow: true)
                try requireGeneration(attempt)
                try await attach(connection, user: user, type: type, initiated: true)
            } catch { socket.cancel(); throw error }
        } catch {
            guard attempt == generation else { return }
            if let callback {
                var writer = WireWriter(); writer.uint(callback); writer.string(user)
                try? await send(code: 1001, payload: writer.data)
            } else if type == "P", let id = rendezvous.first(where: { $0.value.0 == user && $0.value.1 == "P" })?.key {
                var writer = WireWriter(); writer.uint(id); writer.string(user); writer.string("P")
                try? await send(code: 18, payload: writer.data)
            }
            logger.debug("Peer connection failed: \(error.localizedDescription, privacy: .public)")
            if attempt == generation { await report("Peer connection failed: \(error.localizedDescription)") }
        }
    }
    func attach(_ connection: FramedConnection, user: String, type: String, initiated: Bool) async throws {
        let attempt = generation
        switch type {
        case "P":
            if let previous = peers[user] {
                let preferred = username < user
                guard initiated == preferred, peerDirections[user] != preferred else { connection.socket.cancel(); return }
                previous.socket.cancel(); peerTasks[user]?.cancel()
            }
            guard peers.count < 128 else { connection.socket.cancel(); return }
            peers[user] = connection; peerDirections[user] = initiated; connecting.remove(user)
#if DEBUG
            await report("Peer messaging ready: \(user), outgoing=\(initiated)")
#endif
            rendezvous = rendezvous.filter { $0.value.0 != user || $0.value.1 != "P" }
            logger.debug("Peer messaging connection established")
            for message in takePendingPeerMessages(user) {
                do { try await connection.send(code: message.code, payload: message.payload, lease: message.lease) }
                catch is CancellationError { if message.lease?.isValid != false { throw CancellationError() } }
            }
            try requireGeneration(attempt)
            peerTasks[user] = Task { await self.readPeer(connection, user: user, generation: attempt) }
        case "F":
            guard fileConnections.count < 40 else { connection.socket.cancel(); return }
            fileConnections[ObjectIdentifier(connection)] = connection
            await emit(.fileConnection(user, connection))
        case "D":
            guard distributed == nil else { connection.socket.cancel(); return }
            distributed = connection
            peerTasks["D:" + user]?.cancel()
            peerTasks["D:" + user] = Task { await self.readDistributed(connection, user: user, generation: attempt) }
            try await send(code: 71, payload: Data([0]))
        default: connection.socket.cancel()
        }
    }
    func readPeer(_ connection: FramedConnection, user: String, generation attempt: UInt64) async {
        do {
            while !Task.isCancelled {
                let (code, payload) = try await connection.read(peer: true, budget: peerReceiveBudget) { code in
                    try await self.admitPeerResponse(code, user: user, connection: connection, generation: attempt)
                }
#if DEBUG
                if [36, 37, 40, 41, 43, 44, 46, 50, 51].contains(code) { await report("Peer control \(code) from \(user), bytes=\(payload.count)") }
#endif
                try requireGeneration(attempt)
                switch code {
                case 9:
                    guard !activeSearches.isEmpty else { continue }
                    let (id, results) = try PeerCodec.search(payload, allowedTokens: activeSearches)
                    guard activeSearches.contains(id), results.allSatisfy({ $0.user == user }) else { continue }
                    await emit(.search(id, results))
                case 5:
                    guard expectedLibraries.remove(user) != nil else { continue }
                    await emit(.library(try PeerCodec.library(user: user, data: payload, limits: .large)))
                case 16:
                    guard expectedUserInfo.remove(user) != nil else { continue }
                    var reader = WireReader(payload); let description = try reader.string()
                    guard description.utf8.count <= 16_384 else { throw ProtocolError.oversized }
                    let hasPicture = try reader.byte() != 0
                    let picture = try hasPicture ? reader.bytes(reader.count(limit: 8_000_000)) : nil
                    await emit(.userInfo(user, description, picture))
                case 37:
                    var reader = WireReader(try Zlib.inflate(payload, limit: LibraryLimits.large.expandedBytes))
                    let token = try reader.uint()
                    guard expectedFolders[user]?.remove(token) != nil else { throw ProtocolError.invalid("Unrequested folder response.") }
                    await emit(.peerMessage(user, code, payload))
                case 4, 15, 36, 40, 41, 43, 44, 46, 50, 51:
                    await emit(.peerMessage(user, code, payload))
                default: break
                }
            }
        } catch {
            if !Task.isCancelled, peers[user] === connection {
                peers.removeValue(forKey: user); peerTasks.removeValue(forKey: user)
                peerDirections.removeValue(forKey: user); addresses.removeValue(forKey: user)
                expectedLibraries.remove(user); expectedUserInfo.remove(user)
                expectedFolders.removeValue(forKey: user)
                await emit(.peerUnavailable(user))
            }
            if !Task.isCancelled, attempt == generation { await report("Peer messaging ended: \(error.localizedDescription)") }
            connection.socket.cancel()
        }
    }
    func admitPeerResponse(_ code: UInt32, user: String, connection: FramedConnection, generation attempt: UInt64) throws {
        try requireGeneration(attempt)
        guard peers[user] === connection else { throw CancellationError() }
        switch code {
        case 5: guard expectedLibraries.contains(user) else { throw ProtocolError.invalid("Unrequested library response.") }
        case 37: guard expectedFolders[user]?.isEmpty == false else { throw ProtocolError.invalid("Unrequested folder response.") }
        case 16: guard expectedUserInfo.contains(user) else { throw ProtocolError.invalid("Unrequested user information.") }
        default: break
        }
    }
    func readDistributed(_ connection: FramedConnection, user: String, generation attempt: UInt64) async {
        do {
            while !Task.isCancelled {
                let (code, payload) = try await connection.read(narrow: true)
                try requireGeneration(attempt)
                var reader = WireReader(payload)
                switch code {
                case 3: try await distributedSearch(&reader)
                case 4:
                    let level = try reader.uint()
                    var writer = WireWriter(); writer.uint(try PeerCodec.nextBranchLevel(level))
                    try await send(code: 126, payload: writer.data)
                case 5:
                    let root = try reader.string(); var writer = WireWriter(); writer.string(root)
                    try await send(code: 127, payload: writer.data)
                case 93:
                    if try reader.byte() == 3 { try await distributedSearch(&reader) }
                default: break
                }
            }
        } catch {
            connection.socket.cancel()
            if distributed === connection {
                distributed = nil; peerTasks.removeValue(forKey: "D:" + user)
                try? await send(code: 71, payload: Data([1]))
            }
        }
    }
}
