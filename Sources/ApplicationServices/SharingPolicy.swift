import Foundation
import SoulseekCore

/// Only fresh server observations constitute evidence. Missing, stale and timed-out counts are unknown.
actor SharingPolicy {
    struct Observation: Sendable { let files: UInt32; let date: Date }
    private var observations: [String: Observation] = [:]
    private var requests: [String: Date] = [:]
    private var messages: [String: Date] = [:]
    private var revision: UInt64 = 0
    private struct Request: Sendable { let id: UUID; let task: Task<Void, Never> }
    private var inFlight: [String: Request] = [:]
    private let maximumInFlight: Int
    init(maximumInFlight: Int = 32) { self.maximumInFlight = max(1, min(32, maximumInFlight)) }

    func reset() {
        revision &+= 1; observations.removeAll(); requests.removeAll()
        for request in inFlight.values { request.task.cancel() }
    }
    func requestState() -> (count: Int, generation: UInt64) { (inFlight.count, revision) }
    func observe(user: String, files: UInt32, now: Date = Date()) {
        if observations.count >= 4096 { observations.removeAll() }
        observations[user] = Observation(files: files, date: now)
    }
    static func allows(required: Bool, files: UInt32?) -> Bool { !required || files != 0 }
    func permits(user: String, required: Bool, timeout: Duration = .seconds(2), now: Date = Date(),
                 request: @escaping @Sendable () async -> Void) async -> Bool {
        guard required else { return true }
        if let value = observations[user], Date().timeIntervalSince(value.date) < 60 {
            return Self.allows(required: true, files: value.files)
        }
        let owner = revision
        if inFlight[user] == nil, inFlight.count < maximumInFlight,
           requests[user].map({ now.timeIntervalSince($0) >= 3 }) ?? true {
            if requests.count >= 4096 { requests.removeAll() }
            requests[user] = now
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                if !Task.isCancelled, await self.revision == owner { await request() }
                await self.finishRequest(user: user, id: id)
            }
            inFlight[user] = Request(id: id, task: task)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !Task.isCancelled, revision == owner {
            if let value = observations[user], Date().timeIntervalSince(value.date) < 60 { return value.files > 0 }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return true }
        }
        return true
    }
    private func finishRequest(user: String, id: UUID) {
        guard inFlight[user]?.id == id else { return }
        inFlight.removeValue(forKey: user)
    }
    func shouldNotify(account: String, user: String, now: Date = Date()) -> Bool {
        let key = account + "\u{1F}" + user
        guard messages[key].map({ now.timeIntervalSince($0) >= 3600 }) ?? true else { return false }
        if messages.count >= 4096 { messages = messages.filter { now.timeIntervalSince($0.value) < 3600 } }
        guard messages.count < 4096 else { return false }
        messages[key] = now; return true
    }
}

extension AppModel {
    func sharingPermits(_ user: String) async -> Bool {
        let revision = loginRevision
        let account = activeAccount
        let generation = activeSessionGeneration
        guard !Task.isCancelled else { return false }
        let allowed = await sharingPolicy.permits(user: user, required: settings.requiresSharing) { [session] in
            guard let generation else { return }
            var writer = WireWriter(); writer.string(user)
            try? await session.send(code: 36, payload: writer.data, generation: generation)
        }
        guard revision == loginRevision, !shuttingDown, !Task.isCancelled else { return false }
        if !settings.requiresSharing { return true }
        if !allowed, await sharingPolicy.shouldNotify(account: account, user: user) {
            let message = String(settings.sharingMessage.prefix(1000))
            if !message.isEmpty { await sendMessage(to: user, text: message) }
        }
        return allowed
    }
}
