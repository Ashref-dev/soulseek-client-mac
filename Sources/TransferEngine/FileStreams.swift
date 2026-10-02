import Foundation
import SoulseekCore

extension TransferEngine {
    func download(_ id: String, connection: FramedConnection, attempt: UUID) async throws {
        defer {
            connection.socket.cancel()
            if sockets[id] === connection.socket { sockets.removeValue(forKey: id) }
            Task { await session.releaseFileConnection(connection) }
        }
        guard attempts[id] == attempt, connected else { connection.socket.cancel(); throw CancellationError() }
        guard let item = transfers.first(where: { $0.id == id }), let partialPath = item.partial, let destinationPath = item.destination else { throw FileSafetyError.unsafePath }
        let partial = URL(fileURLWithPath: partialPath)
        let destination = URL(fileURLWithPath: destinationPath)
        guard partial.resolvingSymlinksInPath().path == partial.path,
              destination.deletingLastPathComponent().resolvingSymlinksInPath() == destination.deletingLastPathComponent() else { throw FileSafetyError.symbolicLink }
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw ProtocolError.invalid("Could not create the partial download file.") }
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        guard offset <= item.file.size else { throw FileSafetyError.sizeMismatch }
        sockets[id] = connection.socket
        var header = WireWriter(); header.ulong(offset)
        try await connection.socket.send(header.data)
        var received = offset
        let started = ContinuousClock.now
        var lastUpdate = ContinuousClock.now
        var lastCount = received
        await progress(id, bytes: received, speed: 0, attempt: attempt)
        while received < item.file.size {
            try Task.checkCancellation()
            let count = Int(min(65_536, item.file.size - received))
            let bytes = try await connection.exact(count, timeout: 120)
            try requireAttempt(id, attempt: attempt)
            try handle.write(contentsOf: bytes)
            received += UInt64(bytes.count)
            try await throttle(bytes: received - offset, since: started, upload: false)
            try requireAttempt(id, attempt: attempt)
            let elapsed = lastUpdate.duration(to: .now).seconds
            if elapsed >= 0.25 {
                await progress(id, bytes: received, speed: Double(received - lastCount) / elapsed, attempt: attempt)
                lastUpdate = .now; lastCount = received
            }
        }
        try requireAttempt(id, attempt: attempt); try handle.synchronize()
        try FileManager.default.moveItem(at: partial, to: destination)
        await complete(id, bytes: received, attempt: attempt)
    }
    func upload(_ id: String, connection: FramedConnection, attempt: UUID) async throws {
        defer {
            connection.socket.cancel()
            if sockets[id] === connection.socket { sockets.removeValue(forKey: id) }
            Task { await session.releaseFileConnection(connection) }
        }
        guard let item = transfers.first(where: { $0.id == id }), let source = uploadSources[id] else { throw ProtocolError.invalid("File is no longer shared.") }
        guard let authorizer = uploadAuthorizer, await authorizer(item.user, item.file, source), attempts[id] == attempt, connected else { connection.socket.cancel(); throw CancellationError() }
        guard source.resolvingSymlinksInPath() == source else { throw FileSafetyError.symbolicLink }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, UInt64(values.fileSize ?? 0) == item.file.size else { throw FileSafetyError.sizeMismatch }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        sockets[id] = connection.socket
        var reader = WireReader(try await connection.exact(8, timeout: 30)); let offset = try reader.ulong()
        try requireAttempt(id, attempt: attempt)
        guard offset <= item.file.size else { throw FileSafetyError.sizeMismatch }
        try handle.seek(toOffset: offset)
        var sent = offset
        let started = ContinuousClock.now
        var lastUpdate = ContinuousClock.now; var lastCount = sent
        while sent < item.file.size {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: Int(min(65_536, item.file.size - sent))), !data.isEmpty else { throw ProtocolError.truncated }
            try await connection.socket.send(data)
            try requireAttempt(id, attempt: attempt)
            sent += UInt64(data.count)
            try await throttle(bytes: sent - offset, since: started, upload: true)
            try requireAttempt(id, attempt: attempt)
            let elapsed = lastUpdate.duration(to: .now).seconds
            if elapsed >= 0.25 {
                await progress(id, bytes: sent, speed: Double(sent - lastCount) / elapsed, attempt: attempt)
                lastUpdate = .now; lastCount = sent
            }
        }
        do { _ = try await connection.socket.receive(timeout: 30) } catch ProtocolError.disconnected { }
        try requireAttempt(id, attempt: attempt)
        await complete(id, bytes: sent, attempt: attempt)
    }
    func requireAttempt(_ id: String, attempt: UUID) throws {
        try Task.checkCancellation()
        guard connected, attempts[id] == attempt else { throw CancellationError() }
    }
    func progress(_ id: String, bytes: UInt64, speed: Double, attempt: UUID) async {
        guard attempts[id] == attempt, let index = transfers.firstIndex(where: { $0.id == id }), ![.paused, .cancelled].contains(transfers[index].status) else { return }
        transfers[index].status = .transferring; transfers[index].transferred = bytes; transfers[index].speed = speed
        publish()
    }
    func complete(_ id: String, bytes: UInt64, attempt: UUID) async {
        guard attempts[id] == attempt, let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].status == .transferring else { return }
        transfers[index].status = .completed; transfers[index].transferred = bytes; transfers[index].speed = 0
        attempts.removeValue(forKey: id); tasks.removeValue(forKey: id); await save(transfers[index]); publish()
    }
    func throttle(bytes: UInt64, since start: ContinuousClock.Instant, upload: Bool) async throws {
        let limit = upload ? uploadLimit : downloadLimit
        guard limit > 0 else { return }
        let active = max(1, transfers.filter { $0.upload == upload && $0.status == .transferring }.count)
        let expected = Double(bytes) * Double(active) / limit
        let elapsed = start.duration(to: .now).seconds
        if expected > elapsed { try await Task.sleep(for: .seconds(expected - elapsed)) }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
