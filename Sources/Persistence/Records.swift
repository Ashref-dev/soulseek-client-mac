import Foundation

public struct AppSettings: Codable, Sendable {
    public static let soulseekHost = "server.slsknet.org"
    public static let soulseekPort: UInt16 = 2242
    public var username = ""
    public var server = Self.soulseekHost
    public var port: UInt16 = Self.soulseekPort
    public var listeningPort: UInt16 = 2234
    public var downloadDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Arpeggio").path
    public var downloadSlots = 3
    public var uploadSlots = 2
    public var uploadLimitKB: Int?
    public var downloadLimitKB: Int?
    public var appearance = "system"
    public var compact = false
    public var notifications = true
    public var sharedFolders: [ShareFolder] = []
    public var shareExclusions: [String]?
    public init() {}
    public var serverEndpoint: String { "\(server):\(port)" }
    public var isLocalServer: Bool { ["localhost", "127.0.0.1", "::1"].contains(server.lowercased()) }
    public mutating func useSoulseekServer() { server = Self.soulseekHost; port = Self.soulseekPort }
}

public struct ShareFolder: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var buddyOnly: Bool
    public init(path: String, buddyOnly: Bool = false) { self.path = path; self.buddyOnly = buddyOnly }
}

public struct UserRecord: Codable, Sendable, Identifiable {
    public var id: String { username }
    public var username: String
    public var note = ""
    public var trusted = false
    public var ignored = false
    public var lastSeen: Date?
    public var country: String?
    public var averageSpeed: UInt32?
    public var sharedFiles: UInt32?
    public init(username: String) { self.username = username }
}

public struct WishlistEntry: Codable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var query: String
    public var enabled = true
    public var lastChecked: Date?
    public var matches = 0
    public var seen: Set<String> = []
    public init(query: String) { self.query = query }
}

public struct ChatMessage: Codable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var user: String
    public var text: String
    public var date: Date
    public var outgoing: Bool
    public var room: String?
    public var account: String?
    public init(user: String, text: String, date: Date = Date(), outgoing: Bool, room: String? = nil) {
        self.user = user; self.text = text; self.date = date; self.outgoing = outgoing; self.room = room
    }
}
