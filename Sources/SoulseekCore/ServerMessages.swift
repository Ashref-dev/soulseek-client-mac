import Foundation

extension SoulseekSession {
    func readServer(_ connection: FramedConnection, generation attempt: UInt64) async {
        do {
            while !Task.isCancelled {
                let (code, payload) = try await connection.read()
                try requireGeneration(attempt)
                do { try await handleServer(code, payload) }
                catch { logger.warning("Malformed server message \(code): \(error.localizedDescription, privacy: .public)") }
            }
        } catch {
            if !Task.isCancelled, attempt == generation {
                serverTask = nil
                await disconnect(); await emit(.state(.failed("The server connection closed. \(error.localizedDescription)")))
            }
        }
    }
    func handleServer(_ code: UInt32, _ payload: Data) async throws {
        var reader = WireReader(payload)
        switch code {
        case 3:
            let user = try reader.string(); let ip = try reader.uint(); let port = try reader.uint()
            guard port > 0, port <= UInt16.max, ip != 0 else {
                failAddress(user, error: ProtocolError.invalid("This user is offline.")); await expirePeer(user); return
            }
            let host = Self.ipString(ip)
            addresses[user] = (host, UInt16(port))
            for waiter in addressWaiters.removeValue(forKey: user) ?? [] { waiter.resume(returning: (host, UInt16(port))) }
            if connecting.contains(user) {
                let attempt = generation
                Task { await self.connectPeer(user: user, host: host, port: UInt16(port), type: "P", callback: nil, generation: attempt) }
            }
        case 18:
            let user = try reader.string(); let type = try reader.string()
            let ip = try reader.uint(); let port = try reader.uint(); let id = try reader.uint()
            guard port > 0, port <= UInt16.max else { return }
            let attempt = generation
            Task { await self.connectPeer(user: user, host: Self.ipString(ip), port: UInt16(port), type: type, callback: id, generation: attempt) }
        case 22:
            let id = try reader.uint(); let date = try reader.uint(); let user = try reader.string(); let text = try reader.string()
            await emit(.privateMessage(id: id, user: user, text: text, timestamp: date))
        case 13:
            let room = try reader.string(); let user = try reader.string(); let text = try reader.string()
            await emit(.roomMessage(room: room, user: user, text: text))
        case 14:
            let room = try reader.string(); let count = try reader.count(limit: 100_000)
            var users = [String](); for _ in 0..<count { users.append(try reader.string()) }
            await emit(.roomJoined(room, users))
        case 7:
            let user = try reader.string(); let status = try reader.uint(); await emit(.userStatus(user, status))
        case 5:
            let user = try reader.string()
            guard try reader.byte() != 0 else { await emit(.userStatus(user, 0)); return }
            let status = try reader.uint(); let speed = try reader.uint()
            _ = try reader.uint(); _ = try reader.uint()
            let files = try reader.uint(); _ = try reader.uint()
            let country = reader.remaining > 0 ? try reader.string() : nil
            await emit(.userStatus(user, status)); await emit(.userStats(user, speed, files, country))
        case 36:
            let user = try reader.string(); let speed = try reader.uint()
            _ = try reader.uint(); _ = try reader.uint()
            let files = try reader.uint()
            await emit(.userStats(user, speed, files, nil))
        case 16, 17:
            let room = try reader.string(); let user = try reader.string()
            await emit(.roomMembership(room, user, code == 16))
            if code == 16 { await emit(.userStatus(user, try reader.uint())) }
        case 92: await emit(.privileges(try reader.uint()))
        case 26:
            let user = try reader.string(); let id = try reader.uint(); let query = try reader.string()
            await emit(.searchRequest(user, id, query))
        case 64:
            let count = try reader.count(limit: 100_000)
            var names = [String](); for _ in 0..<count { names.append(try reader.string()) }
            let counts = try reader.count(limit: 100_000)
            var rooms: [(String, UInt32)] = []
            for index in 0..<counts { let users = try reader.uint(); if index < names.count { rooms.append((names[index], users)) } }
            await emit(.roomList(rooms))
        case 93:
            let distributedCode = try reader.byte()
            if distributedCode == 3 { try await distributedSearch(&reader) }
        case 102:
            let count = try reader.count(limit: 10)
            if count > 0 {
                let user = try reader.string(); let ip = try reader.uint(); let port = try reader.uint()
                if port > 0, port <= UInt16.max {
                    let attempt = generation
                    Task { await self.connectPeer(user: user, host: Self.ipString(ip), port: UInt16(port), type: "D", callback: nil, generation: attempt) }
                }
            }
        case 104: await emit(.wishlistInterval(try reader.uint()))
        case 41:
            await emit(.diagnostic("This account connected from another client. Disconnect the other client before reconnecting."))
            serverTask = nil; await disconnect()
        case 1001:
            let id = try reader.uint()
            if let (user, _) = rendezvous.removeValue(forKey: id) { await expirePeer(user) }
        default: break
        }
    }
    func distributedSearch(_ reader: inout WireReader) async throws {
        _ = try reader.uint()
        let user = try reader.string(); let id = try reader.uint(); let query = try reader.string()
        if user != username { await emit(.searchRequest(user, id, query)) }
    }
    static func ipString(_ value: UInt32) -> String {
        [(value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255].map(String.init).joined(separator: ".")
    }
}
