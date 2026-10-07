import Foundation
import Testing
import Persistence
import SoulseekCore
import TransferEngine
@testable import ArpeggioServices

private struct FrozenTransfer: Decodable {
    let id: String
    let user: String
    let file: SharedFile
    let upload: Bool
    let status: String
    let transferred: UInt64
    let speed: Double
    let queuePosition: UInt32
    let destination: String?
    let partial: String?
    let error: String?
    let retries: Int
    let date: Date
    let token: UInt32?
    let preview: Bool?
    let bytesMoved: UInt64?
}

private struct FrozenSettings: Decodable {
    let username: String
    let server: String
    let port: UInt16
    let listeningPort: UInt16
    let downloadDirectory: String
    let downloadSlots: Int
    let uploadSlots: Int
    let appearance: String
    let compact: Bool
    let notifications: Bool
    let sharedFolders: [ShareFolder]
}

private struct FrozenStatistics: Decodable {
    let since: Date
    let downloadedBytes: UInt64
    let uploadedBytes: UInt64
    let downloadsCompleted: Int
    let uploadsCompleted: Int
    let peakDownloadSpeed: Double
    let peakUploadSpeed: Double
    let sources: Set<String>
    let listeners: Set<String>
}

struct DurabilityCompatibilityTests {
    @Test func frozenOldDecodersReadNewRecordsAndSavedPorts() throws {
        var item = Transfer(user: "fixture", file: SharedFile(path: "song", size: 100)); item.bytesMoved = 20; item.accountingPeakSpeed = 99
        item.runtimeState = TransferRuntimeState(holdsLocalSlot: false, localSlotsInUse: 3, localSlots: 3,
            connected: true, directionSuspended: false, queueWait: .localSlots, peerBlockedUntil: nil,
            pendingRetry: TransferRetrySchedule(identity: UUID(), deadline: Date()))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let old = try decoder.decode(FrozenTransfer.self, from: encoder.encode(item))
        #expect(old.id == item.id && old.bytesMoved == 20 && old.status == "queued")
        let rawValues: Set<String> = ["queued", "negotiating", "transferring", "paused", "completed", "failed", "cancelled"]
        for value in rawValues { #expect(TransferStatus(rawValue: value) != nil) }
        for port in [UInt16(2234), 61147, 65535, 1] {
            var settings = AppSettings(); settings.listeningPort = port
            let bytes = try encoder.encode(settings)
            #expect(try decoder.decode(FrozenSettings.self, from: bytes).listeningPort == port)
            #expect(try decoder.decode(AppSettings.self, from: bytes).listeningPort == port)
        }
        var totals = LifetimeStatistics(since: Date(timeIntervalSince1970: 5)); totals.downloadedBytes = 23; totals.listeners = ["fixture"]
        let bytes = try encoder.encode(totals)
        let oldTotals = try decoder.decode(FrozenStatistics.self, from: bytes)
        #expect(oldTotals.since == totals.since && oldTotals.downloadedBytes == 23 && oldTotals.listeners == ["fixture"])
        #expect(try decoder.decode(TransferStatistics.self, from: bytes).since == totals.since)
    }

    @Test @MainActor func explicitValidImportResolvesRecoveryWithAtomicRawBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        let broken = Data("malformed original \n".utf8)
        try await model.database.putRaw(broken, collection: "settings", id: "main")
        await model.start()
        var settings = AppSettings(); settings.username = "synthetic"; settings.listeningPort = 2234
        let export = ConfigurationExport(settings: settings, users: [], wishlist: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let url = root.appendingPathComponent("import.json")
        try encoder.encode(export).write(to: url)
        try await model.importConfiguration(from: url)
        #expect(model.settingsRecovery == nil)
        #expect(model.settings.listeningPort == 2234 && model.settings.username == "synthetic")
        let backupID = try #require(model.settingsRecoveryBackupID)
        #expect(try await model.database.raw(collection: "settings-recovery-backups", id: backupID) == broken)
        let persisted = try #require(try await model.database.get(AppSettings.self, collection: "settings", id: "main"))
        #expect(persisted.username == "synthetic" && persisted.listeningPort == 2234)
        await model.shutdown()
    }
}
