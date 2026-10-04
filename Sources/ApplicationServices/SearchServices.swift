import Foundation
import SoulseekCore

extension AppModel {
    public func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !shuttingDown else { return }
        let previous = searchToken
        searchRevision &+= 1; let revision = searchRevision
        batchTask?.cancel(); batchTask = nil; searchStopTask?.cancel(); searchStopTask = nil
        results = []; buffered = []; resultIDs = []; searching = true; searchToken = nil
        if let previous { await session.retireSearch(previous) }
        do {
            let token = await session.nextToken()
            guard revision == searchRevision, !shuttingDown else { return }
            searchToken = token
            _ = try await session.search(query: text, token: token)
            guard revision == searchRevision, !shuttingDown else { await session.retireSearch(token); return }
            scheduleSearchStop(revision: revision)
            let item = SearchHistory(query: text)
            history.insert(item, at: 0); history = Array(history.prefix(100))
            try await database.put(item, collection: "history", id: item.id)
        } catch {
            guard revision == searchRevision else { return }
            self.error = error.localizedDescription; searching = false
        }
    }

    public func stopSearch() {
        let previous = searchToken
        searching = false; searchToken = nil; searchRevision &+= 1
        searchStopTask?.cancel(); searchStopTask = nil
        batchTask?.cancel(); batchTask = nil; flushResults()
        if let previous { Task { await session.retireSearch(previous) } }
    }

    public func clearSearch() {
        stopSearch()
        results = []; buffered = []; resultIDs = []; query = ""
    }

    func scheduleSearchStop(revision: UInt64) {
        let idle = settings.searchAutoStopSeconds
        guard idle > 0 else { return }
        let started = Date(); lastSearchActivity = started
        searchStopTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.searchRevision == revision, self.searching else { return }
                if SearchAutoStop.shouldStop(started: started, lastActivity: self.lastSearchActivity, now: Date(), idleSeconds: idle) {
                    self.stopSearch(); return
                }
            }
        }
    }
}
