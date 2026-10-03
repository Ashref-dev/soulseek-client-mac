import Foundation
import SoulseekCore

extension AppModel {
    public func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !shuttingDown else { return }
        let previous = searchToken
        searchRevision &+= 1; let revision = searchRevision
        batchTask?.cancel(); batchTask = nil
        results = []; buffered = []; resultIDs = []; searching = true; searchToken = nil
        if let previous { await session.retireSearch(previous) }
        do {
            let token = await session.nextToken()
            guard revision == searchRevision, !shuttingDown else { return }
            searchToken = token
            _ = try await session.search(query: text, token: token)
            guard revision == searchRevision, !shuttingDown else { await session.retireSearch(token); return }
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
        batchTask?.cancel(); batchTask = nil; flushResults()
        if let previous { Task { await session.retireSearch(previous) } }
    }
}
