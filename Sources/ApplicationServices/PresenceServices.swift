import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SoulseekCore
import TransferEngine

public enum Presence: Sendable, Equatable { case offline, available, away }

extension AppModel {
    public var presence: Presence {
        guard connection == .connected else { return .offline }
        return awayNow ? .away : .available
    }

    public var activeUploads: Int { transfers.filter { $0.upload && $0.status == .transferring }.count }
    public var uploadSpeed: Double { transfers.filter { $0.upload && $0.status == .transferring }.reduce(0) { $0 + $1.speed } }
    public var downloadSpeed: Double { transfers.filter { !$0.upload && $0.status == .transferring }.reduce(0) { $0 + $1.speed } }

    public func setAway(_ away: Bool) async {
        settings.away = away; autoAway = false
        await applyPresence()
        await saveSettings()
    }

    func applyPresence() async {
        awayNow = settings.isAway || autoAway
        guard connection == .connected, let generation = activeSessionGeneration else { return }
        var writer = WireWriter(); writer.uint(awayNow ? 1 : 2)
        do { try await session.send(code: 28, payload: writer.data, generation: generation) } catch { log(error.localizedDescription) }
    }

    func startIdleMonitor() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await self?.checkIdle()
            }
        }
    }

    func checkIdle() async {
        let anyInput = CGEventType(rawValue: ~0) ?? .mouseMoved
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let away = settings.goesAwayWhenIdle && !settings.isAway && idle >= Double(settings.idleAwayMinutes * 60)
        guard away != autoAway else { return }
        autoAway = away
        await applyPresence()
    }

    var profilePictureURL: URL { dataDirectory.appendingPathComponent("profile-picture.jpg") }

    public func setProfilePicture(from url: URL) {
        guard let data = Self.normalizedPicture(at: url) else { error = "That image couldn’t be read. Choose a JPEG, PNG or HEIC picture."; return }
        do {
            try data.write(to: profilePictureURL, options: .atomic)
            profilePicture = data
        } catch { self.error = error.localizedDescription }
    }

    public func clearProfilePicture() {
        try? FileManager.default.removeItem(at: profilePictureURL)
        profilePicture = nil
    }

    func loadProfilePicture() {
        profilePicture = try? Data(contentsOf: profilePictureURL)
    }

    /// JPEG no larger than 512 px, small enough to send to every peer that asks.
    nonisolated static func normalizedPicture(at url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 512]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    func userInfoReply() -> Data {
        var writer = WireWriter()
        writer.string(settings.profileDescription ?? "")
        if let picture = profilePicture {
            writer.byte(1); writer.uint(UInt32(picture.count)); writer.bytes(picture)
        } else { writer.byte(0) }
        let queued = transfers.filter { $0.upload && $0.status == .queued }.count
        writer.uint(UInt32(clamping: settings.uploadSlots)); writer.uint(UInt32(clamping: queued))
        writer.byte(activeUploads < settings.uploadSlots ? 1 : 0)
        return writer.data
    }

    func recordReceivedSearch(user: String, query: String, results: Int) {
        receivedSearchTotal += 1
        receivedBuffer.append(ReceivedSearch(user: user, query: String(query.prefix(200)), results: results, date: Date()))
        if receivedBuffer.count > 300 { receivedBuffer.removeFirst(receivedBuffer.count - 300) }
        guard receivedFlushTask == nil else { return }
        receivedFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.receivedSearches = Array((self.receivedBuffer.reversed() + self.receivedSearches).prefix(300))
            self.receivedBuffer.removeAll(); self.receivedFlushTask = nil
        }
    }

    public func clearReceivedSearches() { receivedSearches = []; receivedBuffer = [] }

    func ingestStatistics(_ transfers: [Transfer]) async {
        do {
            if let totals = try await database.get(TransferStatistics.self, collection: "statistics", id: "main") { statistics = totals }
        } catch { log("storage error: Saved statistics are unavailable; existing totals have been preserved.") }
    }

    func loadStatistics(history: [Transfer]) async {
        await ingestStatistics(history)
    }

    func saveStatistics() async {
        await ingestStatistics(transfers)
    }
}
