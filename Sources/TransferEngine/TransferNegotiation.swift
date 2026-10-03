import Foundation
import SoulseekCore

extension TransferEngine {
    public func peerMessage(user: String, code: UInt32, payload: Data) async throws {
        var reader = WireReader(payload)
        switch code {
        case 40:
            let direction = try reader.uint(); let token = try reader.uint(); let path = try reader.string()
            guard direction == 1 else {
                var response = WireWriter(); response.uint(token); response.byte(0); response.string("Queued")
                try await session.peerSend(user: user, code: 41, payload: response.data); return
            }
            let size = try reader.ulong()
            guard let index = transfers.firstIndex(where: { !$0.upload && $0.user == user && $0.file.path == path && [.queued, .negotiating].contains($0.status) }) else {
                var response = WireWriter(); response.uint(token); response.byte(0); response.string("Cancelled")
                try await session.peerSend(user: user, code: 41, payload: response.data); return
            }
            guard size == transfers[index].file.size else { await fail(transfers[index].id, error: FileSafetyError.sizeMismatch); return }
            if let accepted = transfers[index].token {
                var response = WireWriter(); response.uint(token); response.byte(accepted == token ? 1 : 0)
                if accepted != token { response.string("Queued") }
                try await session.peerSend(user: user, code: 41, payload: response.data)
                return
            }
            let active = transfers.filter { !$0.upload && ($0.status == .transferring || ($0.status == .negotiating && $0.token != nil)) }.count
            guard active < downloadSlots else {
                var response = WireWriter(); response.uint(token); response.byte(0); response.string("Queued")
                try await session.peerSend(user: user, code: 41, payload: response.data); return
            }
            remoteQueued.remove(transfers[index].id)
            transfers[index].token = token; transfers[index].status = .negotiating
            let id = transfers[index].id
            startNegotiationDeadline(id, token: token); await save(transfers[index])
            guard transfers.contains(where: { $0.id == id && $0.token == token && $0.status == .negotiating }) else { return }
            var response = WireWriter(); response.uint(token); response.byte(1)
            try await session.peerSend(user: user, code: 41, payload: response.data); publish()
        case 41:
            let token = try reader.uint(); let allowed = try reader.byte() != 0
            guard let index = transfers.firstIndex(where: { $0.upload && $0.user == user && $0.token == token && $0.status == .negotiating }), tasks[transfers[index].id] == nil else { return }
            let transfer = transfers[index]
            if allowed {
                let attempt = UUID()
                transfers[index].status = .transferring; transfers[index].token = nil; attempts[transfer.id] = attempt
                negotiationTasks.removeValue(forKey: transfer.id)?.cancel()
                publish()
                tasks[transfer.id] = Task {
                    do {
                        guard let source = self.uploadSources[transfer.id], let authorizer = self.uploadAuthorizer,
                              await authorizer(user, transfer.file, source), self.attempts[transfer.id] == attempt else {
                            throw ProtocolError.invalid("File is no longer shared with this user.")
                        }
                        try Task.checkCancellation()
                        let connection = try await self.session.openFileConnection(user: user, transferToken: token)
                        guard self.attempts[transfer.id] == attempt else {
                            connection.socket.cancel(); await self.session.releaseFileConnection(connection); throw CancellationError()
                        }
                        try await self.upload(transfer.id, connection: connection, attempt: attempt)
                    } catch { await self.fail(transfer.id, error: error, attempt: attempt) }
                    await self.pumpUploads()
                }
            } else {
                let reason = try reader.string()
                if reason == "Queued", let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
                    transfers[index].status = .queued; uploadBlockedUntil[user] = Date().addingTimeInterval(60)
                    Task { try? await Task.sleep(for: .seconds(60)); await self.pumpUploads() }
                } else { await fail(transfer.id, error: ProtocolError.invalid(reason)) }
                await pumpUploads()
            }
        case 44:
            let path = try reader.string(); let position = try reader.uint()
            if let index = transfers.firstIndex(where: { !$0.upload && $0.user == user && $0.file.path == path && $0.status == .negotiating }) {
                transfers[index].queuePosition = position
                if transfers[index].token == nil {
                    remoteQueued.insert(transfers[index].id)
                    negotiationTasks.removeValue(forKey: transfers[index].id)?.cancel()
                }
                publish(); await pump()
            }
        case 46, 50:
            let path = try reader.string()
            let reason = code == 50 && reader.remaining > 0 ? try reader.string() : "The source interrupted this transfer. Retry to resume the partial file."
            if let item = transfers.first(where: { !$0.upload && $0.user == user && $0.file.path == path && [.negotiating, .transferring].contains($0.status) }) {
                await fail(item.id, error: ProtocolError.invalid(reason)); await pump()
            }
        case 51:
            let path = try reader.string()
            let position = transfers.filter { $0.upload && $0.status == .queued }.firstIndex(where: { $0.user == user && $0.file.path == path }).map { UInt32($0 + 1) } ?? 0
            var response = WireWriter(); response.string(path); response.uint(position)
            try await session.peerSend(user: user, code: 44, payload: response.data)
        default: break
        }
    }
    public func queueUpload(user: String, file: SharedFile, localURL: URL, start: Bool = true) async {
        guard transfers.filter({ $0.upload && [.queued, .negotiating, .transferring].contains($0.status) }).count < 1000 else { return }
        guard !transfers.contains(where: { $0.upload && $0.user == user && $0.file.path == file.path && [.queued, .negotiating, .transferring].contains($0.status) }) else { return }
        let item = Transfer(user: user, file: file, upload: true)
        transfers.append(item); uploadSources[item.id] = localURL
        await save(item); publish()
        if start { await pumpUploads() }
    }
    public func startQueuedUploads() async { await pumpUploads() }
    func pumpUploads() async {
        guard connected else { return }
        let active = transfers.filter { $0.upload && [.negotiating, .transferring].contains($0.status) }.count
        let queued = transfers.filter { $0.upload && $0.status == .queued && (uploadBlockedUntil[$0.user] ?? .distantPast) <= Date() }.prefix(max(0, uploadSlots - active))
        for item in queued {
            let token = await session.nextToken()
            guard connected, let index = transfers.firstIndex(where: { $0.id == item.id && $0.status == .queued }) else { continue }
            transfers[index].token = token; transfers[index].status = .negotiating
            startNegotiationDeadline(item.id, token: token)
            var request = WireWriter(); request.uint(1); request.uint(token); request.string(item.file.path); request.ulong(item.file.size)
            do { try await session.peerSend(user: item.user, code: 40, payload: request.data) }
            catch { await fail(item.id, error: error) }
        }
        publish()
    }
    public func acceptFile(user: String, connection: FramedConnection) async {
        do {
            var reader = WireReader(try await connection.exact(4, timeout: 30)); let token = try reader.uint()
            guard await session.fileMatchesServerAddress(user, connection: connection) else {
                connection.socket.cancel(); await session.releaseFileConnection(connection); return
            }
            guard connected, let index = transfers.firstIndex(where: { !$0.upload && $0.user == user && $0.token == token && $0.status == .negotiating }), tasks[transfers[index].id] == nil else {
                connection.socket.cancel(); await session.releaseFileConnection(connection); return
            }
            let item = transfers[index]; let attempt = UUID()
            transfers[index].status = .transferring; transfers[index].token = nil; attempts[item.id] = attempt
            negotiationTasks.removeValue(forKey: item.id)?.cancel()
            tasks[item.id] = Task {
                do { try await self.download(item.id, connection: connection, attempt: attempt) }
                catch { await self.fail(item.id, error: error, attempt: attempt) }
                await self.pump()
            }
        } catch { connection.socket.cancel(); await session.releaseFileConnection(connection) }
    }
}
