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
    public var autoConnect: Bool?
    public var searchIdleSeconds: Int?
    public var onboardingVersion: Int?
    public var userFolders: Bool?
    public var fullRemotePaths: Bool?
    public var away: Bool?
    public var awayWhenIdle: Bool?
    public var idleMinutes: Int?
    public var profileDescription: String?
    public var portMapping: Bool?
    public var menuBarIcon: Bool?
    public var hideDockWhenClosed: Bool?
    public var queuedUploadsPerUser: Int?
    public var autoClearDownloads: Bool?
    public var checkForUpdates: Bool?
    public var requireSharing: Bool?
    public var sharingRequiredMessage: String?
    public var natPMPEnabled: Bool?
    public var upnpEnabled: Bool?
    public var statsCardAccount: Bool?
    public init() {}
    public var connectsAutomatically: Bool { autoConnect ?? true }
    public var downloadLayout: DownloadLayout { DownloadLayout(userFolders: userFolders ?? false, fullPaths: fullRemotePaths ?? false) }
    public var isAway: Bool { away ?? false }
    public var goesAwayWhenIdle: Bool { awayWhenIdle ?? true }
    public var idleAwayMinutes: Int { min(120, max(1, idleMinutes ?? 10)) }
    public var mapsPorts: Bool { portMapping ?? true }
    public var usesNATPMP: Bool { natPMPEnabled ?? true }
    public var usesUPnP: Bool { upnpEnabled ?? true }
    public var requiresSharing: Bool { requireSharing ?? false }
    public var sharingMessage: String { sharingRequiredMessage ?? "You must share files in order to download from me." }
    public var showsMenuBarIcon: Bool { menuBarIcon ?? true }
    public var uploadQueueLimit: Int { max(0, queuedUploadsPerUser ?? 200) }
    public var checksForUpdates: Bool { checkForUpdates ?? true }
    /// Shared statistics pictures and summaries leave the username out unless the person opts in.
    public var showsAccountOnStatsCard: Bool { statsCardAccount ?? false }
    /// Seconds without new results before a search ends; 0 keeps it open until stopped.
    public var searchAutoStopSeconds: Int { max(0, searchIdleSeconds ?? 15) }
    /// Bounds every field that becomes a number on the wire or a loop count, for settings read from files.
    public var isValid: Bool {
        (1...20).contains(downloadSlots) && (1...20).contains(uploadSlots) && port > 0 && listeningPort > 0 &&
        (0...1_000_000).contains(downloadLimitKB ?? 0) && (0...1_000_000).contains(uploadLimitKB ?? 0) &&
        (0...10_000).contains(queuedUploadsPerUser ?? 0) && (1...120).contains(idleMinutes ?? 10) &&
        (0...120).contains(searchIdleSeconds ?? 15) && !downloadDirectory.isEmpty && username.utf8.count <= 30 &&
        (profileDescription?.count ?? 0) <= 4000 && (sharingRequiredMessage?.utf8.count ?? 0) <= 1000
    }
    public var serverEndpoint: String { "\(server):\(port)" }
    public var isLocalServer: Bool { ["localhost", "127.0.0.1", "::1"].contains(server.lowercased()) }
    public mutating func useSoulseekServer() { server = Self.soulseekHost; port = Self.soulseekPort }
}

public struct DownloadLayout: Sendable, Equatable {
    public var userFolders: Bool
    public var fullPaths: Bool
    public init(userFolders: Bool = false, fullPaths: Bool = false) { self.userFolders = userFolders; self.fullPaths = fullPaths }
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
