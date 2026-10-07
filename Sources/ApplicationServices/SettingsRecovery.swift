import Foundation
import Persistence

public struct SettingsRecovery: Sendable, Equatable {
    public let originalBytes: Data
    public let reason: String
}

extension AppModel {
    func loadEssentialSettings() async {
        do {
            guard let data = try await database.raw(collection: "settings", id: "main") else { return }
            do {
                let saved = try JSONDecoder().decode(AppSettings.self, from: data)
                guard saved.isValid else { throw CocoaError(.fileReadCorruptFile) }
                settings = saved
            } catch {
                settingsRecovery = SettingsRecovery(originalBytes: data, reason: "Saved settings could not be read. Export a backup, then import a valid configuration or explicitly reset settings.")
                self.error = settingsRecovery?.reason
                log("storage error: Essential settings require explicit recovery.")
            }
        } catch { settingsRecovery = SettingsRecovery(originalBytes: Data(), reason: error.localizedDescription); self.error = error.localizedDescription; log("storage error: Essential settings could not be loaded.") }
    }

    public func backupSettingsRecovery(to url: URL) async throws {
        guard let recovery = settingsRecovery else { return }
        try recovery.originalBytes.write(to: url, options: .atomic)
    }

    func resolveSettingsRecovery(with next: AppSettings) async throws {
        guard next.isValid else { throw CocoaError(.fileReadCorruptFile) }
        let backupID = "\(Date().timeIntervalSince1970)-\(UUID().uuidString)"
        try await database.transaction { db in
            if let original = try db.raw(collection: "settings", id: "main") {
                try db.putRaw(original, collection: "settings-recovery-backups", id: backupID)
            }
            try db.put(next, collection: "settings", id: "main")
        }
        settings = next; settingsRecovery = nil; settingsRecoveryBackupID = backupID
        await configureTransfers()
    }

    public func resetSettingsRecovery() async throws {
        guard settingsRecovery != nil else { return }
        try await resolveSettingsRecovery(with: AppSettings())
    }

    public func removeTransfers(_ ids: Set<String>) async -> Bool {
        do { try await transferEngine.removeTransfers(ids); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
