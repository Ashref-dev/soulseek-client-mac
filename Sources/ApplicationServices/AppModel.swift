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
    public var shareProgress = ShareScanProgress()
    public var downloadsSuspended = false
    public var uploadsSuspended = false
    public var portCheck: String?
    public internal(set) var externalPortCheck: ExternalPortCheck?
    public var sharedCount = 0
    public var sharedBytes: UInt64 = 0
    public var shareErrors: [String] = []
    public internal(set) var shareSummaries: [String: ShareRootSummary] = [:]
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
    public var notice: Notice?
    public internal(set) var downloadIndex: [String: Transfer] = [:]
    public internal(set) var awayNow = false
    public internal(set) var profilePicture: Data?
    public internal(set) var statistics = TransferStatistics()
    public internal(set) var receivedSearches: [ReceivedSearch] = []
    public internal(set) var receivedSearchTotal = 0
    public internal(set) var portMapping = PortMappingStatus.idle
    public internal(set) var update: UpdateState = .idle
    public internal(set) var menuBarExtraVisible = true
    public let playback = Playback()
    public var documentPreview: DocumentPreview?
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
    @ObservationIgnored var searchRevision: UInt64 = 0
    @ObservationIgnored var searchStopTask: Task<Void, Never>?
    @ObservationIgnored var lastSearchActivity = Date()
    @ObservationIgnored var wishlistTokens: [UInt32: String] = [:]
    @ObservationIgnored var wishlistSeconds: UInt32 = 0
    @ObservationIgnored var intentionallyOffline = true
    @ObservationIgnored var shareWatchTask: Task<Void, Never>?
    @ObservationIgnored var indexedFolders: [ShareFolder] = []
    @ObservationIgnored var indexedExclusions: [String] = []
    @ObservationIgnored var scanningFolders: [ShareFolder]?
    @ObservationIgnored var scanningExclusions: [String]?
    @ObservationIgnored var folderDownloads: [UInt32: (String, String)] = [:]
    @ObservationIgnored var notificationDates: [String: Date] = [:]
    @ObservationIgnored var loginRevision: UInt64 = 0
    @ObservationIgnored var reconnectAllowed = false
    @ObservationIgnored var credentials = CredentialWrites()
    @ObservationIgnored var loginSettingsSave: @MainActor @Sendable (AppModel) async -> Void = { model in
        await model.saveSettings()
    }
    @ObservationIgnored var playbackRevision: UInt64 = 0
    @ObservationIgnored var autoAway = false
    @ObservationIgnored var idleTask: Task<Void, Never>?
    @ObservationIgnored var statisticsSeen: [String: TransferStatistics.Progress] = [:]
    @ObservationIgnored var statisticsBaselined = false
    @ObservationIgnored var statisticsDirty = false
    @ObservationIgnored var statisticsTask: Task<Void, Never>?
    @ObservationIgnored var receivedBuffer: [ReceivedSearch] = []
    @ObservationIgnored var receivedFlushTask: Task<Void, Never>?
    @ObservationIgnored var portMapper: PortMapper?
    @ObservationIgnored var updateTask: Task<Void, Never>?
    @ObservationIgnored var updateRevision: UInt64 = 0
    @ObservationIgnored var installingUpdate = false
    @ObservationIgnored var credentialLookup: @Sendable (String) async throws -> String = { username in
        try await Task.detached(priority: .utility) { try Keychain.password(for: username) ?? "" }.value
    }
    @ObservationIgnored var shuttingDown = false
    @ObservationIgnored var startupConnectionAttempted = false
    @ObservationIgnored var rescanPending = false
    @ObservationIgnored var shareScanTask: Task<(Int, UInt64), Never>?
    @ObservationIgnored var scanShares: @MainActor @Sendable (AppModel, [ShareFolder], [String]) async -> (Int, UInt64) = { model, folders, exclusions in
        await model.shareIndex.scan(folders: folders.map { (URL(fileURLWithPath: $0.path), $0.buddyOnly) }, exclusions: exclusions)
    }
    @ObservationIgnored var initialShareTask: Task<Void, Never>?
    @ObservationIgnored var initialShareScan: @MainActor @Sendable (AppModel) async -> Void = { model in
        await model.rescanShares(configurationOnly: true)
    }
    @ObservationIgnored var activeSessionGeneration: UInt64?
    @ObservationIgnored var shareWatcher: ShareWatcher?
    @ObservationIgnored var shareChangeTask: Task<Void, Never>?
    @ObservationIgnored var shareChangeRevision: UInt64 = 0
    @ObservationIgnored var shareProgressTask: Task<Void, Never>?
    @ObservationIgnored let sharingPolicy = SharingPolicy()
    @ObservationIgnored var uploadRequestTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var uploadRequestUsers: [UUID: String] = [:]
    @ObservationIgnored var watchedPaths: [String] = []
    @ObservationIgnored var externalPortCheckTask: Task<ExternalPortCheck.Outcome, Never>?
    @ObservationIgnored var externalPortCheckRevision: UInt64 = 0
    @ObservationIgnored var externalPortProbe: @Sendable (UInt16) async -> ExternalPortCheck.Outcome = { port in
        await ExternalPortChecker().check(port: port)
    }
    public let dataDirectory: URL

    static var defaultDataDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arpeggio") }
    public init(dataDirectory: URL? = nil) throws {
        let root = dataDirectory ?? Self.defaultDataDirectory
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
            await transferEngine.setPreviewRoot(dataDirectory == Self.defaultDataDirectory ? Self.previewDirectory() : dataDirectory.appendingPathComponent("Previews", isDirectory: true))
            try await transferEngine.restore()
            await transferEngine.purgePreviewCache()
            await loadStatistics(history: await transferEngine.snapshot())
        } catch { self.error = error.localizedDescription }
        loadProfilePicture()
        awayNow = settings.isAway
        menuBarExtraVisible = settings.showsMenuBarIcon
        startIdleMonitor()
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await self?.saveStatistics()
            }
        }
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
                self.ingestStatistics(transfers)
                self.indexDownloads(transfers)
                self.playback.refresh(transfers)
                self.refreshDocumentPreview(transfers)
                let finished = transfers.filter { !$0.upload && !$0.isPreview && $0.status == .completed && !previous.contains($0.id) }
                if let first = finished.first { await self.notify(key: "downloads", title: "Download finished", text: first.file.name, minimumInterval: 5) }
                if !finished.isEmpty, self.settings.autoClearDownloads == true, self.playback.item?.transferID.map({ id in finished.contains { $0.id == id } }) != true {
                    Task { await transferEngine.clearFinished(upload: false) }
                }
            }
        }
        shareProgressTask = Task { [weak self, shareIndex] in
            for await progress in shareIndex.progress {
                guard let self, !Task.isCancelled else { return }
                if progress.revision >= self.shareProgress.revision { self.shareProgress = progress }
            }
        }
        await transferEngine.setUploadAuthorizer { [weak self] user, file, url in
            guard let self else { return false }
            return await self.authorizeUpload(user: user, file: file, url: url)
        }
        guard !shuttingDown else { return }
        if !settings.sharedFolders.isEmpty {
            initialShareTask = Task { [weak self] in
                guard let self, !Task.isCancelled, !self.shuttingDown else { return }
                do {
                    if let cache = try await self.database.all(ShareMetadataCache.self, collection: "share-metadata", limit: 1).first {
                        await self.shareIndex.restoreMetadataCache(cache)
                    }
                } catch { self.log("Share metadata cache unavailable; rebuilding metadata.") }
                guard !Task.isCancelled, !self.shuttingDown else { return }
                await self.initialShareScan(self)
            }
        }
        scheduleUpdateChecks()
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
            if menuBarExtraVisible != settings.showsMenuBarIcon { menuBarExtraVisible = settings.showsMenuBarIcon }
            await configureTransfers()
            if shareConfigurationNeedsScan { await rescanShares(configurationOnly: true) }
            await transferEngine.revalidateUploads()
        } catch { self.error = error.localizedDescription }
    }
    public func useSoulseekServer() async {
        settings.useSoulseekServer(); error = nil
        await saveSettings()
    }
    func configureTransfers() async {
        await transferEngine.configure(root: URL(fileURLWithPath: settings.downloadDirectory), downloads: settings.downloadSlots,
                                       uploads: settings.uploadSlots, downloadLimitKB: settings.downloadLimitKB ?? 0,
                                       uploadLimitKB: settings.uploadLimitKB ?? 0, layout: settings.downloadLayout,
                                       uploadQueueLimit: settings.uploadQueueLimit)
    }
    public func shutdown() async {
        guard !shuttingDown else { return }; shuttingDown = true
        intentionallyOffline = true; loginRevision &+= 1
        reconnectTask?.cancel(); reconnectTask = nil; wishlistTask?.cancel(); wishlistTask = nil
        batchTask?.cancel(); searchStopTask?.cancel(); shareWatchTask?.cancel(); shareScanTask?.cancel()
        initialShareTask?.cancel()
        shareProgressTask?.cancel()
        cancelExternalPortCheck()
        for task in uploadRequestTasks.values { task.cancel() }
        uploadRequestTasks.removeAll(); uploadRequestUsers.removeAll()
        idleTask?.cancel(); statisticsTask?.cancel(); updateTask?.cancel(); receivedFlushTask?.cancel()
        await abandonCurrentPreview(); playback.stop()
        await removePortMapping()
        shareChangeTask?.cancel(); shareWatcher?.close(); shareWatcher = nil
        await session.shutdown()
        await eventTask?.value
        await transferEngine.shutdown()
        transferTask?.cancel(); await transferTask?.value
        await transferEngine.purgePreviewCache()
        statisticsDirty = true; await saveStatistics()
        _ = await shareScanTask?.value
        await initialShareTask?.value
        shareScanTask = nil; initialShareTask = nil
        do { try await database.put(settings, collection: "settings", id: "main") } catch { log(error.localizedDescription) }
        await database.close()
    }
    public func login(password: String, remember: Bool = true, automatic: Bool = false) async {
        guard !shuttingDown else { return }
        error = nil
        loginRevision &+= 1; let revision = loginRevision
        activeSessionGeneration = nil
        let configuration = settings
        let credentialGeneration = await credentials.generation
        guard revision == loginRevision, !shuttingDown else { return }
        await sharingPolicy.reset()
        guard revision == loginRevision, !shuttingDown else { return }
        if !automatic { reconnectAllowed = false }
        intentionallyOffline = false
        do {
            try await session.connect(host: configuration.server, port: configuration.port, user: configuration.username,
                                      password: password, listeningPort: configuration.listeningPort)
            guard revision == loginRevision, !shuttingDown else { return }
            guard settings.username == configuration.username, settings.server == configuration.server,
                  settings.port == configuration.port, settings.listeningPort == configuration.listeningPort else {
                await disconnect(); error = "Account settings changed while signing in. Please reconnect."; return
            }
            let generation = await session.currentGeneration()
            guard revision == loginRevision, !shuttingDown else { return }
            activeAccount = configuration.username; reconnectAllowed = true
            activeSessionGeneration = generation
            if remember {
                do { try await credentials.save(password: password, for: configuration.username, ifGeneration: credentialGeneration) }
                catch {
                    if revision == loginRevision, !shuttingDown {
                        self.error = "Signed in, but couldn’t save the password in Keychain. You’ll need to enter it again when reconnecting."
                    }
                }
            }
            guard revision == loginRevision, !shuttingDown else { return }
            let loadedMessages = try await database.all(ChatMessage.self, collection: "messages").filter { $0.account == configuration.username }.sorted { $0.date < $1.date }
            guard revision == loginRevision, !shuttingDown else { return }
            messages = loadedMessages
            await loginSettingsSave(self)
            guard revision == loginRevision, !shuttingDown else { return }
            try await session.send(code: 64, generation: generation)
            guard revision == loginRevision, !shuttingDown else { return }
            try await session.send(code: 92, generation: generation)
            guard revision == loginRevision, !shuttingDown else { return }
            await publishShares()
            guard revision == loginRevision, !shuttingDown else { return }
            for user in users {
                try await watchUser(user.username, generation: generation)
                guard revision == loginRevision, !shuttingDown else { return }
            }
            await applyPresence()
            guard revision == loginRevision, !shuttingDown else { return }
            mapListeningPort()
            await requestNotifications()
        } catch { if revision == loginRevision, !shuttingDown { self.error = error.localizedDescription } }
    }
    public func savedPassword() async -> String {
        let username = settings.username
        do { return try await credentialLookup(username) }
        catch { self.error = error.localizedDescription; return "" }
    }
    public func connectAtLaunch() async {
        guard !startupConnectionAttempted, !Task.isCancelled, settings.connectsAutomatically,
              !settings.username.isEmpty, connection == .offline, !shuttingDown else { return }
        startupConnectionAttempted = true
        let account = (settings.username, settings.server, settings.port, settings.listeningPort, loginRevision)
        let result: Result<String, any Error>
        do { result = .success(try await credentialLookup(account.0)) }
        catch { result = .failure(error) }
        guard !Task.isCancelled, connection == .offline, !shuttingDown, settings.connectsAutomatically,
              account == (settings.username, settings.server, settings.port, settings.listeningPort, loginRevision) else { return }
        switch result {
        case .success(let password) where !password.isEmpty:
            await login(password: password, remember: false)
        case .success:
            error = "Automatic sign-in needs a saved password. Open Account and Server and Sign In with Remember password enabled. Your downloads and settings are still saved."
        case .failure(let failure):
            error = "Automatic sign-in stopped. \(failure.localizedDescription)"
        }
    }
    public func signOut() async {
        let user = settings.username
        await disconnect()
        do { try await credentials.delete(for: user) }
        catch { self.error = error.localizedDescription }
        settings.username = ""; activeAccount = ""; messages = []; unread = []
        await saveSettings()
    }
    public func disconnect() async {
        loginRevision &+= 1
        activeSessionGeneration = nil
        cancelExternalPortCheck()
        await sharingPolicy.reset()
        intentionallyOffline = true; reconnectAllowed = false
        reconnectTask?.cancel(); reconnectTask = nil; wishlistTask?.cancel(); wishlistTask = nil
        await session.disconnect(); await transferEngine.setConnected(false)
        await removePortMapping()
    }
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
    func watchUser(_ user: String, generation: UInt64? = nil) async throws {
        var writer = WireWriter(); writer.string(user)
        try await session.send(code: 5, payload: writer.data, generation: generation)
    }
}

/// Serializes Keychain writes so a save from a sign-in that started earlier can't recreate a password
/// that Sign Out has since deleted.
actor CredentialWrites {
    private(set) var generation: UInt64 = 0
    private let backend: Backend
    init(backend: Backend = .keychain) { self.backend = backend }
    func save(password: String, for user: String, ifGeneration expected: UInt64) throws {
        guard generation == expected else { return }
        try backend.save(password, user)
    }
    func delete(for user: String) throws {
        generation &+= 1
        try backend.delete(user)
    }
    struct Backend: Sendable {
        var save: @Sendable (String, String) throws -> Void
        var delete: @Sendable (String) throws -> Void
        static var keychain: Self {
            Self(save: { try Keychain.save(password: $0, for: $1) }, delete: { try Keychain.delete(for: $0) })
        }
    }
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
