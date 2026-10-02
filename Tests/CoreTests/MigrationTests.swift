import Foundation
import Testing
import Persistence
import SoulseekCore
import CSQLite

@Test func migratesEmptyDatabaseAndRejectsFutureSchema() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("state.sqlite")
    let database = try Database(url: url)
    #expect(try await database.schemaVersion() == 1)
    await database.close()
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    #expect(sqlite3_exec(handle, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    #expect(throws: StorageError.self) { try Database(url: url) }
}

@Test func wireFixturesHaveExactLengthAndCodeWidths() {
    #expect(SoulseekCore.WireWriter.frame(code: 26, payload: Data([1, 2])) == Data([6, 0, 0, 0, 26, 0, 0, 0, 1, 2]))
    #expect(SoulseekCore.WireWriter.frame(code: 1, payload: Data([1, 2]), narrow: true) == Data([3, 0, 0, 0, 1, 1, 2]))
}
