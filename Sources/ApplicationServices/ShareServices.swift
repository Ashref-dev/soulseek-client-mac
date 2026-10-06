import Foundation
import SoulseekCore
import ShareIndexer
import Persistence

extension AppModel {
    var shareConfigurationNeedsScan: Bool {
        settings.sharedFolders != (scanningFolders ?? indexedFolders) ||
        (settings.shareExclusions ?? []) != (scanningExclusions ?? indexedExclusions)
    }

    public func rescanShares(configurationOnly: Bool = false) async {
        guard !shuttingDown else { return }
        guard !indexing else {
            if !configurationOnly { rescanPending = true }
            return
        }
        if configurationOnly, !shareConfigurationNeedsScan { return }
        indexing = true
        defer { indexing = false; scanningFolders = nil; scanningExclusions = nil; shareScanTask = nil }
        repeat {
            rescanPending = false
            let folders = settings.sharedFolders
            let exclusions = settings.shareExclusions ?? []
            scanningFolders = folders; scanningExclusions = exclusions
            updateShareWatcher()
            let task = Task { await self.scanShares(self, folders, exclusions) }
            shareScanTask = task
            let count = await task.value
            guard !shuttingDown, !task.isCancelled, !Task.isCancelled else { return }
            sharedCount = count.0; sharedBytes = count.1
            sharedLibrary = await shareIndex.library(allowPrivate: true, configuredFolders: currentShareFolders)
            shareErrors = await shareIndex.errors
            shareSummaries = await shareIndex.summaries
            indexedFolders = folders; indexedExclusions = exclusions
            do { try await database.put(RemoteLibrary(user: "local", folders: sharedLibrary), collection: "share-index", id: "local") }
            catch { self.error = error.localizedDescription }
            do { try await database.put(shareIndex.metadataCache(), collection: "share-metadata", id: "local") }
            catch { self.error = error.localizedDescription }
        } while rescanPending || indexedFolders != settings.sharedFolders || indexedExclusions != (settings.shareExclusions ?? [])
        updateShareWatcher()
        await publishShares()
    }

    func updateShareWatcher() {
        let paths = settings.sharedFolders.map(\.path)
        guard paths != watchedPaths || (shareWatcher == nil && !paths.isEmpty) else { return }
        shareWatcher?.close(); shareWatcher = nil; watchedPaths = paths
        guard !paths.isEmpty, !shuttingDown else { return }
        do {
            shareWatcher = try ShareWatcher(folders: paths.map { URL(fileURLWithPath: $0) }, ignoring: [dataDirectory]) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.shuttingDown else { return }
                    self.scheduleShareRescan()
                }
            }
        } catch { log("File watching unavailable. Automatic rescans will run every two minutes.") }
    }

    @discardableResult
    func scheduleShareRescan(after delay: Duration = .seconds(1.5)) -> Task<Void, Never> {
        shareChangeTask?.cancel()
        shareChangeRevision &+= 1
        let revision = shareChangeRevision
        let task = Task { [weak self] in
            do { try await Task.sleep(for: delay); try Task.checkCancellation() }
            catch {
                if let self, self.shareChangeRevision == revision { self.shareChangeTask = nil }
                return
            }
            guard let self, !self.shuttingDown, self.shareChangeRevision == revision else { return }
            self.shareChangeTask = nil
            await self.rescanShares()
        }
        shareChangeTask = task
        return task
    }

    public func share(_ urls: [URL]) async {
        let existing = Set(settings.sharedFolders.map(\.path))
        let added = urls.map(\.standardizedFileURL.path).filter { !existing.contains($0) }
        guard !added.isEmpty else { return }
        settings.sharedFolders.append(contentsOf: added.map { ShareFolder(path: $0) })
        await saveSettings()
    }

    public func unshare(_ folder: ShareFolder) async {
        settings.sharedFolders.removeAll { $0.path == folder.path }
        await saveSettings()
    }

    public func setTrustedOnly(_ folder: ShareFolder, _ trustedOnly: Bool) async {
        guard let index = settings.sharedFolders.firstIndex(where: { $0.path == folder.path }) else { return }
        settings.sharedFolders[index].buddyOnly = trustedOnly
        await saveSettings()
    }

    public static var musicFolder: URL? {
        let url = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    var currentShareFolders: [(URL, Bool)] { settings.sharedFolders.map { (URL(fileURLWithPath: $0.path), $0.buddyOnly) } }

    func authorizeUpload(user: String, file: SharedFile, url: URL) async -> Bool {
        guard !shuttingDown, !users.contains(where: { $0.username == user && $0.ignored }) else { return false }
        guard await sharingPermits(user) else { return false }
        let roots = settings.sharedFolders.filter { url.path.hasPrefix(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path + "/") }
        guard let specific = roots.max(by: { $0.path.count < $1.path.count }) else { return false }
        if specific.buddyOnly, !users.contains(where: { $0.username == user && $0.trusted }) { return false }
        var trusted = false
        if users.contains(where: { $0.username == user && $0.trusted }) { trusted = await session.peerMatchesServerAddress(user) }
        guard let current = await shareIndex.resolve(file.path, allowPrivate: trusted, configuredFolders: currentShareFolders) else { return false }
        return current.localURL == url && current.file.size == file.size
    }

    func publishShares() async {
        guard connection == .connected, let generation = activeSessionGeneration else { return }
        let folders = await shareIndex.library(configuredFolders: currentShareFolders)
        var writer = WireWriter()
        writer.uint(UInt32(clamping: folders.count)); writer.uint(UInt32(clamping: folders.values.reduce(0) { $0 + $1.count }))
        do { try await session.send(code: 35, payload: writer.data, generation: generation) }
        catch { log(error.localizedDescription) }
    }
}
