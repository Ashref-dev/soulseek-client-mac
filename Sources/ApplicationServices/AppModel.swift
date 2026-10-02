import Foundation
import Observation
import SoulseekCore
import Persistence
import ShareIndexer
import TransferEngine

@MainActor @Observable
public final class AppModel {
    public var settings = AppSettings()
    public var connection: ConnectionState = .offline
    public private(set) var activeAccount = ""
    public var query = ""
    public var results: [SearchResult] = []
    public var searching = false
    public var searchToken: UInt32?
    public var transfers: [Transfer] = []
    public var users: [UserRecord] = []
    public var userStatuses: [String: UInt32] = [:]
    public var wishlist: [WishlistEntry] = []
    public var messages: [ChatMessage] = []
    public var rooms: [RoomSummary] = []
    public var joinedRooms: [String: [String]] = [:]
    public var libraries: [String: RemoteLibrary] = [:]
    public var browsingUser: String?
    public var browseLoading = false
    public var sharedLibrary: [String: [SharedFile]] = [:]
    public var indexing = false
    public var sharedCount = 0
    public var sharedBytes: UInt64 = 0
    public var shareErrors: [String] = []
    public var error: String?
    public var diagnostics: [String] = []
    public var userDescriptions: [String: String] = [:]
    public var userPictures: [String: Data] = [:]
    public var userStatistics: [String: UserStatistics] = [:]
    public var privilegeSeconds: UInt32 = 0
    public var browseRevision = 0
    public var history: [SearchHistory] = []
    public var unread: Set<String> = []
    public var activeConversation: String?
    public let session: SoulseekSession
    public let database: Database
    public let shareIndex: ShareIndex
    public let transferEngine: TransferEngine
    @ObservationIgnored var eventTask: Task<Void, Never>?
    @ObservationIgnored var transferTask: Task<Void, Never>?
    @ObservationIgnored var batchTask: Task<Void, Never>?
    @ObservationIgnored var wishlistTask: Task<Void, Never>?
    @ObservationIgnored var reconnectTask: Task<Void, Never>?
    @ObservationIgnored var buffered: [SearchResult] = []
    @ObservationIgnored var resultIDs: Set<String> = []
    @ObservationIgnored var wishlistTokens: [UInt32: String] = [:]
    @ObservationIgnored var wishlistSeconds: UInt32 = 0
    @ObservationIgnored var intentionallyOffline = true
    @ObservationIgnored var shareWatchTask: Task<Void, Never>?
    @ObservationIgnored var indexedFolders: [ShareFolder] = []
    @ObservationIgnored var indexedExclusions: [String] = []
    @ObservationIgnored var folderDownloads: [UInt32: (String, String)] = [:]
    @ObservationIgnored var notificationDates: [String: Date] = [:]
    @ObservationIgnored var loginRevision: UInt64 = 0
    @ObservationIgnored var reconnectAllowed = false
    @ObservationIgnored var shuttingDown = false
    @ObservationIgnored var rescanPending = false
    @ObservationIgnored var shareScanTask: Task<(Int, UInt64), Never>?
    @ObservationIgnored var activeSessionGeneration: UInt64?
    @ObservationIgnored var shareWatcher: ShareWatcher?
    @ObservationIgnored var shareChangeTask: Task<Void, Never>?
    @ObservationIgnored var watchedPaths: [String] = []
    public let dataDirectory: URL

    public init(dataDirectory: URL? = nil) throws {
        let root = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arpeggio")
        self.dataDirectory = root
        database = try Database(url: root.appendingPathComponent("arpeggio.sqlite"))
        session = SoulseekSession(); shareIndex = ShareIndex()
        transferEngine = TransferEngine(session: session, database: database, root: URL(fileURLWithPath: AppSettings().downloadDirectory))
    }
    public func start() async {
        do {
            settings = try await database.all(AppSettings.self, collection: "settings").first ?? AppSettings()
            activeAccount = settings.username
            users = try await database.all(UserRecord.self, collection: "users")
            wishlist = try await database.all(WishlistEntry.self, collection: "wishlist")
            messages = try await database.all(ChatMessage.self, collection: "messages").filter { $0.account == activeAccount }.sorted { $0.date < $1.date }
            history = try await database.all(SearchHistory.self, collection: "history")
            for library in try await database.all(RemoteLibrary.self, collection: "libraries", limit: 10) { libraries[library.user] = library }
            await configureTransfers()
            try await transferEngine.restore()
        } catch { self.error = error.localizedDescription }
        eventTask = Task { [weak self, session] in
            for await envelope in session.events {
                guard let self, !Task.isCancelled else { return }
                guard envelope.generation == (await session.currentGeneration()) else { continue }
                await self.handle(envelope.event, account: envelope.account, generation: envelope.generation)
            }
        }
        transferTask = Task { [weak self, transferEngine] in
            for await transfers in transferEngine.updates {
                guard let self else { return }
                let previous = Set(self.transfers.filter { $0.status == .completed }.map(\.id))
                self.transfers = transfers
                let finished = transfers.filter { !$0.upload && $0.status == .completed && !previous.contains($0.id) }
                if let first = finished.first { await self.notify(key: "downloads", title: "Download finished", text: first.file.name, minimumInterval: 5) }
            }
        }
        await rescanShares()
        await transferEngine.setUploadAuthorizer { [weak self] user, file, url in
            guard let self else { return false }
            return await self.authorizeUpload(user: user, file: file, url: url)
        }
        shareWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard let self, !Task.isCancelled else { return }
                if self.shareWatcher == nil, !self.settings.sharedFolders.isEmpty { await self.rescanShares() }
            }
        }
    }
    public func saveSettings() async {
        guard !shuttingDown else { return }
        do {
            await transferEngine.revalidateUploads()
            try await database.put(settings, collection: "settings", id: "main")
            await configureTransfers()
            if settings.sharedFolders != indexedFolders || (settings.shareExclusions ?? []) != indexedExclusions { await rescanShares() }
            await transferEngine.revalidateUploads()
        } catch { self.error = error.localizedDescription }
    }
    func configureTransfers() async {
        await transferEngine.configure(root: URL(fileURLWithPath: settings.downloadDirectory), downloads: settings.downloadSlots,
                                       uploads: settings.uploadSlots, downloadLimitKB: settings.downloadLimitKB ?? 0,
                                       uploadLimitKB: settings.uploadLimitKB ?? 0)
    }
    public func shutdown() async {
        guard !shuttingDown else { return }; shuttingDown = true
        intentionallyOffline = true; loginRevision &+= 1
        reconnectTask?.cancel(); reconnectTask = nil; wishlistTask?.cancel(); wishlistTask = nil
        batchTask?.cancel(); shareWatchTask?.cancel(); shareScanTask?.cancel()
        shareChangeTask?.cancel(); shareWatcher?.close(); shareWatcher = nil
        await session.shutdown()
        await eventTask?.value
        await transferEngine.shutdown()
        transferTask?.cancel(); await transferTask?.value
        _ = await shareScanTask?.value
        do { try await database.put(settings, collection: "settings", id: "main") } catch { log(error.localizedDescription) }
        await database.close()
    }
    public func login(password: String, remember: Bool = true, automatic: Bool = false) async {
        guard !shuttingDown else { return }
        loginRevision &+= 1; let revision = loginRevision
        activeSessionGeneration = nil
        let configuration = settings
        if !automatic { reconnectAllowed = false }
        intentionallyOffline = false
        do {
            try await session.connect(host: configuration.server, port: configuration.port, user: configuration.username,
                                      password: password, listeningPort: configuration.listeningPort)
            guard revision == loginRevision, !shuttingDown else { return }
            guard settings.username == configuration.username, settings.server == configuration.server, settings.port == configuration.port else {
                await disconnect(); error = "Account settings changed while signing in. Please reconnect."; return
            }
            activeAccount = configuration.username; reconnectAllowed = true
            activeSessionGeneration = await session.currentGeneration()
            guard revision == loginRevision else { return }
            messages = try await database.all(ChatMessage.self, collection: "messages").filter { $0.account == activeAccount }.sorted { $0.date < $1.date }
            guard revision == loginRevision else { return }
            if remember {
                do { try Keychain.save(password: password, for: configuration.username) }
                catch { self.error = "Signed in, but couldn’t save the password in Keychain. You’ll need to enter it again when reconnecting." }
            }
            await saveSettings()
            try await session.send(code: 64)
            try await session.send(code: 92)
            await requestNotifications()
            await publishShares()
            for user in users { try await watchUser(user.username) }
        } catch { if revision == loginRevision, !shuttingDown { self.error = error.localizedDescription } }
    }
    public func savedPassword() -> String {
        do { return try Keychain.password(for: settings.username) ?? "" }
        catch { self.error = error.localizedDescription; return "" }
    }
    public func disconnect() async {
        loginRevision &+= 1
        activeSessionGeneration = nil
        intentionallyOffline = true; reconnectAllowed = false
        reconnectTask?.cancel(); reconnectTask = nil; wishlistTask?.cancel(); wishlistTask = nil
        await session.disconnect(); await transferEngine.setConnected(false)
    }
    public func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        results = []; buffered = []; resultIDs = []; searching = true
        do {
            let token = await session.nextToken(); searchToken = token
            _ = try await session.search(query: text, token: token)
            let item = SearchHistory(query: text)
            history.insert(item, at: 0); history = Array(history.prefix(100))
            try await database.put(item, collection: "history", id: item.id)
        } catch { self.error = error.localizedDescription; searching = false }
    }
    public func stopSearch() { searching = false; searchToken = nil; flushResults() }
    public func download(_ items: [SearchResult]) async {
        do { try await transferEngine.enqueue(items) } catch { self.error = error.localizedDescription }
    }
    public func browse(_ user: String) async {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        browsingUser = name; browseLoading = true
        do { try await session.peerSend(user: name, code: 4) }
        catch { self.error = error.localizedDescription; browseLoading = false }
    }
    public func downloadFolder(user: String, folder: String) async {
        guard let library = libraries[user] else { return }
        let files = library.folders.filter { $0.key == folder || $0.key.hasPrefix(folder + "\\") }.values.flatMap { $0 }
        await download(files.map { SearchResult(user: user, file: $0, freeSlot: false, speed: 0, queue: 0) })
    }
    public func requestFolderDownload(user: String, folder: String) async {
        do {
            let token = await session.nextToken()
            folderDownloads[token] = (user, folder)
            var writer = WireWriter(); writer.uint(token); writer.string(folder)
            try await session.peerSend(user: user, code: 36, payload: writer.data)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                if self?.folderDownloads.removeValue(forKey: token) != nil { self?.error = "This user didn’t return the folder contents. Try browsing their files first." }
            }
        } catch { self.error = error.localizedDescription }
    }
    func log(_ text: String) { diagnostics.append(text); diagnostics = Array(diagnostics.suffix(200)) }
    func watchUser(_ user: String) async throws { var writer = WireWriter(); writer.string(user); try await session.send(code: 5, payload: writer.data) }
}

public struct RoomSummary: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let users: UInt32
    public init(name: String, users: UInt32) { self.name = name; self.users = users }
}
public struct SearchHistory: Codable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var query: String
    public var date = Date()
    public init(query: String) { self.query = query }
}
