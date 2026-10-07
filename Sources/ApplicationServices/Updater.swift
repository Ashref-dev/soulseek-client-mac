import Foundation
import Security

public struct Release: Sendable, Equatable {
    public let version: String
    public let notes: String
    public let asset: URL
    public let page: URL
}

public enum UpdateState: Sendable, Equatable {
    case idle, checking, upToDate
    case available(Release)
    case downloading(Release)
    case ready(Release)
    case failed(String)
}

public enum UpdateError: Error, LocalizedError {
    case noAsset, unreadable, wrongApp, notNewer, untrusted, notWritable
    case incompatible, unsafeArchive, timedOut, helperFailed, invalidReceipt
    public var errorDescription: String? {
        switch self {
        case .noAsset: "The release has no Arpeggio download attached."
        case .unreadable: "The downloaded update couldn’t be opened."
        case .wrongApp: "The downloaded update isn’t Arpeggio."
        case .notNewer: "The downloaded update isn’t newer than this version."
        case .untrusted: "The update isn’t signed by the same developer as this copy, so it wasn’t installed."
        case .notWritable: "Arpeggio can’t replace itself in this folder. Move it to Applications and try again."
        case .incompatible: "This update requires a different macOS version or processor. Arpeggio supports macOS 27 or later on Apple Silicon."
        case .unsafeArchive: "The update archive exceeds safety limits or contains unsafe entries."
        case .timedOut: "The update operation exceeded its safety deadline."
        case .helperFailed: "The update recovery helper could not start. The installed app was not changed."
        case .invalidReceipt: "The update startup receipt was invalid; recovery will retain the previous app."
        }
    }
}

public enum Updater {
    public static let repository = "Ashref-dev/soulseek-client-mac"
    public static var currentVersion: String { UpdateCompatibility.releaseVersion(.main) }

    public static func latest(session: URLSession = .shared) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Arpeggio/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }

    struct Payload: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    static func parse(_ data: Data) throws -> Release {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        guard UpdateVersion(version) != nil else { throw UpdateError.notNewer }
        let canonical = payload.assets.filter { $0.name == "Soulseek-Arpeggio-\(version).zip" }
        let legacy = payload.assets.filter { $0.name == "Arpeggio-\(version).zip" }
        let matches = canonical.isEmpty ? legacy : canonical
        guard matches.count == 1, let asset = matches.first else { throw UpdateError.noAsset }
        return Release(version: version, notes: payload.body ?? "",
                       asset: asset.browser_download_url, page: payload.html_url)
    }

    /// Semantic version comparison; a pre-release ("0.6.0-beta") sorts before its release.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = UpdateVersion(candidate), let b = UpdateVersion(current, legacy: true) else { return false }
        return a > b
    }

    @discardableResult
    public static func install(_ release: Release, replacing current: URL, session: URLSession = .shared) async throws -> URL {
        let parent = current.deletingLastPathComponent()
        guard current.pathExtension == "app", current.path == current.resolvingSymlinksInPath().path else { throw UpdateError.notWritable }
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable }
        let staging = parent.appendingPathComponent(".arpeggio-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: staging) } }
        let archive = staging.appendingPathComponent("download.zip")
        try await download(release.asset, to: archive, session: session)
        let appName = try UpdateArchive.validate(archive)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try await unzip(archive, into: unpacked)
        let app = unpacked.appendingPathComponent(appName, isDirectory: true)
        try UpdateCompatibility.validate(app, replacing: current, expectedVersion: release.version)
        let requirement = try UpdateTrust.verify(app, replacing: current)
        do { try await UpdateInstaller.prepare(staging: staging, candidate: app, current: current, requirement: requirement) }
        catch { handedOff = true; throw error }
        handedOff = true
        return current
    }

    static func verify(_ candidate: URL, replacing current: URL) throws {
        try UpdateCompatibility.validate(candidate, replacing: current)
        _ = try UpdateTrust.verify(candidate, replacing: current)
    }

    static func unzip(_ archive: URL, into directory: URL) async throws {
        _ = try UpdateArchive.validate(archive)
        try await UpdateProcess.run("/usr/bin/ditto", arguments: ["-x", "-k", "--norsrc", archive.path, directory.path])
    }

    static func download(_ asset: URL, to destination: URL, session: URLSession) async throws {
        guard asset.scheme == "https" else { throw UpdateError.unreadable }
        let request = URLRequest(url: asset, timeoutInterval: 30)
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= UpdateArchive.compressedLimit else { throw UpdateError.unsafeArchive }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw UpdateError.unreadable }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var count = 0, buffer = Data()
        let deadline = Date().addingTimeInterval(120)
        for try await byte in bytes {
            count += 1
            guard count <= UpdateArchive.compressedLimit else { throw UpdateError.unsafeArchive }
            guard Date() < deadline else { throw UpdateError.timedOut }
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count == 65_536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        try handle.write(contentsOf: buffer)
    }
}

extension AppModel {
    public var canUpdateInPlace: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func scheduleUpdateChecks() {
        updateTask?.cancel()
        guard settings.checksForUpdates, canUpdateInPlace else { return }
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.checkForUpdates(quietly: true)
                do { try await Task.sleep(for: .seconds(24 * 3600)) } catch { return }
            }
        }
    }

    public func checkForUpdates(quietly: Bool = false) async {
        guard !installingUpdate, !shuttingDown else { return }
        updateRevision &+= 1; let revision = updateRevision
        if !quietly { update = .checking }
        let result: Result<Release, Error>
        do { result = .success(try await Updater.latest()) } catch { result = .failure(error) }
        guard revision == updateRevision, !installingUpdate, !shuttingDown else { return }
        switch result {
        case .success(let release):
            update = Updater.isNewer(release.version, than: Updater.currentVersion) ? .available(release) : (quietly ? .idle : .upToDate)
        case .failure(let error):
            if !quietly { update = .failed("Couldn’t check for updates. \(error.localizedDescription)") }
        }
    }

    /// True means the acknowledged recovery helper is ready; quit to let it swap and launch.
    public func installUpdate(_ release: Release) async -> Bool {
        guard !installingUpdate, !shuttingDown else { return false }
        installingUpdate = true; updateRevision &+= 1
        update = .downloading(release)
        do {
            _ = try await Updater.install(release, replacing: Bundle.main.bundleURL)
            update = .ready(release)
            return true
        } catch {
            installingUpdate = false
            update = .failed(error.localizedDescription)
            return false
        }
    }

    public func dismissUpdate() { guard !installingUpdate else { return }; updateRevision &+= 1; update = .idle }
}
