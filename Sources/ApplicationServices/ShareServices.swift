import Foundation
import SoulseekCore
import ShareIndexer

extension AppModel {
    public func rescanShares() async {
        guard !shuttingDown else { return }
        guard !indexing else { rescanPending = true; return }
        indexing = true
        repeat {
            rescanPending = false
            let folders = settings.sharedFolders
            let exclusions = settings.shareExclusions ?? []
            let index = shareIndex
            let task = Task { await index.scan(folders: folders.map { (URL(fileURLWithPath: $0.path), $0.buddyOnly) }, exclusions: exclusions) }
            shareScanTask = task
            let count = await task.value
            guard !shuttingDown else { indexing = false; return }
            sharedCount = count.0; sharedBytes = count.1
            sharedLibrary = await shareIndex.library(allowPrivate: true, configuredFolders: currentShareFolders)
            shareErrors = await shareIndex.errors
            indexedFolders = folders; indexedExclusions = exclusions
            do { try await database.put(RemoteLibrary(user: "local", folders: sharedLibrary), collection: "share-index", id: "local") }
            catch { self.error = error.localizedDescription }
        } while rescanPending || indexedFolders != settings.sharedFolders || indexedExclusions != (settings.shareExclusions ?? [])
        indexing = false; shareScanTask = nil
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
                    self.shareChangeTask?.cancel()
                    self.shareChangeTask = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(1.5)); try Task.checkCancellation() } catch { return }
                        await self?.rescanShares()
                    }
                }
            }
        } catch { log("File watching unavailable. Automatic rescans will run every two minutes.") }
    }

    var currentShareFolders: [(URL, Bool)] { settings.sharedFolders.map { (URL(fileURLWithPath: $0.path), $0.buddyOnly) } }

    func authorizeUpload(user: String, file: SharedFile, url: URL) async -> Bool {
        guard !shuttingDown, !users.contains(where: { $0.username == user && $0.ignored }) else { return false }
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
