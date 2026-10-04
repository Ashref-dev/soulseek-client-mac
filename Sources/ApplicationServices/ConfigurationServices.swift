import Foundation
import Persistence
import SoulseekCore

public struct ConfigurationExport: Codable, Sendable {
    public var format = 1
    public var exported = Date()
    public var settings: AppSettings
    public var users: [UserRecord]
    public var wishlist: [WishlistEntry]
}

extension AppModel {
    public func exportConfiguration(to url: URL) throws {
        let export = ConfigurationExport(settings: settings, users: users, wishlist: wishlist)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(export).write(to: url, options: .atomic)
    }

    public func importConfiguration(from url: URL) async throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let imported = try decoder.decode(ConfigurationExport.self, from: Data(contentsOf: url))
        guard imported.format == 1, imported.settings.isValid, imported.users.count <= 100_000, imported.wishlist.count <= 10_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var next = imported.settings
        if connection.isOnline { next.username = settings.username; next.server = settings.server; next.port = settings.port }
        settings = next
        for user in imported.users {
            if let index = users.firstIndex(where: { $0.username == user.username }) { users[index] = user } else { users.append(user) }
            try await database.put(user, collection: "users", id: user.username)
        }
        for entry in imported.wishlist where !wishlist.contains(where: { $0.query.caseInsensitiveCompare(entry.query) == .orderedSame }) {
            wishlist.append(entry)
            try await database.put(entry, collection: "wishlist", id: entry.id)
        }
        await saveSettings()
        notice = Notice(title: "Configuration imported", detail: "\(imported.users.count) users, \(imported.wishlist.count) wishlist searches", symbol: "square.and.arrow.down.fill")
    }

    public func clearSearchHistory() async {
        for item in history { try? await database.remove(collection: "history", id: item.id) }
        history = []
    }
}

extension ConnectionState {
    var isOnline: Bool { self == .connected || self == .connecting || self == .reconnecting }
}
