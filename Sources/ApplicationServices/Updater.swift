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
    public var errorDescription: String? {
        switch self {
        case .noAsset: "The release has no Arpeggio download attached."
        case .unreadable: "The downloaded update couldn’t be opened."
        case .wrongApp: "The downloaded update isn’t Arpeggio."
        case .notNewer: "The downloaded update isn’t newer than this version."
        case .untrusted: "The update isn’t signed by the same developer as this copy, so it wasn’t installed."
        case .notWritable: "Arpeggio can’t replace itself in this folder. Move it to Applications and try again."
        }
    }
}

/// Updates from GitHub Releases. A release is installed only when its code signature satisfies the
/// designated requirement of the copy being replaced, so only builds from the same signing identity apply.
public enum Updater {
    public static let repository = "Ashref-dev/soulseek-client-mac"
    public static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

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
        guard let asset = payload.assets.first(where: { $0.name.hasPrefix("Arpeggio") && $0.name.hasSuffix(".zip") }) else { throw UpdateError.noAsset }
        return Release(version: payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), notes: payload.body ?? "",
                       asset: asset.browser_download_url, page: payload.html_url)
    }

    /// Semantic version comparison; a pre-release ("0.6.0-beta") sorts before its release.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> ([Int], Bool) {
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let core = trimmed.split(separator: "-", maxSplits: 1)
            let numbers = core.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
            return ((numbers + [0, 0, 0]).prefix(3).map { $0 }, core.count > 1)
        }
        let (a, aPre) = parts(candidate), (b, bPre) = parts(current)
        if a != b { return a.lexicographicallyPrecedes(b) == false }
        return !aPre && bPre
    }

    /// Downloads, unpacks and verifies a release next to `current`, then swaps it in place.
    public static func install(_ release: Release, replacing current: URL, session: URLSession = .shared) async throws {
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable }
        let (archive, response) = try await session.download(from: release.asset)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let staging = parent.appendingPathComponent(".arpeggio-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging); try? FileManager.default.removeItem(at: archive) }
        try await unzip(archive, into: staging)
        let apps = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey]).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first,
              (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw UpdateError.unreadable }
        try verify(app, replacing: current)
        _ = try FileManager.default.replaceItemAt(current, withItemAt: app)
    }

    static func verify(_ candidate: URL, replacing current: URL) throws {
        guard let new = Bundle(url: candidate), let old = Bundle(url: current),
              new.bundleIdentifier == old.bundleIdentifier else { throw UpdateError.wrongApp }
        let newVersion = new.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let oldVersion = old.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(newVersion, than: oldVersion) else { throw UpdateError.notNewer }
        var installed: SecStaticCode?, requirement: SecRequirement?, downloaded: SecStaticCode?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &installed) == errSecSuccess, let installed,
              SecCodeCopyDesignatedRequirement(installed, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &downloaded) == errSecSuccess, let downloaded
        else { throw UpdateError.untrusted }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(downloaded, flags, requirement) == errSecSuccess else { throw UpdateError.untrusted }
    }

    static func unzip(_ archive: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                finished.terminationStatus == 0 ? continuation.resume() : continuation.resume(throwing: UpdateError.unreadable)
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// Reopens the app at `bundle` once this process has exited.
    public static func relaunch(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundle.path]
        try? process.run()
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

    /// Returns true when the new version is in place and the app should quit to relaunch.
    public func installUpdate(_ release: Release) async -> Bool {
        guard !installingUpdate, !shuttingDown else { return false }
        installingUpdate = true; updateRevision &+= 1
        update = .downloading(release)
        do {
            try await Updater.install(release, replacing: Bundle.main.bundleURL)
            update = .ready(release)
            Updater.relaunch(Bundle.main.bundleURL)
            return true
        } catch {
            installingUpdate = false
            update = .failed(error.localizedDescription)
            return false
        }
    }

    public func dismissUpdate() { guard !installingUpdate else { return }; updateRevision &+= 1; update = .idle }
}
