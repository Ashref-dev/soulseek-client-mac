import Foundation
import CSQLite

public enum StorageError: Error, LocalizedError {
    case sqlite(String)
    public var errorDescription: String? { switch self { case .sqlite(let message): message } }
}

public actor Database {
    private var handle: OpaquePointer?
    private var transactionActive = false
    private var failCommit = false
    public private(set) var transactionCount = 0
    /// Deterministic fault injection for isolated database tests, never changes stored data.
    public func failNextTransactionCommit() { failCommit = true }
    public func transaction<T: Sendable>(_ body: @Sendable (isolated Database) throws -> T) throws -> T {
        guard !transactionActive else { throw StorageError.sqlite("Nested transaction.") }
        try execute("BEGIN IMMEDIATE"); transactionActive = true
        defer { transactionActive = false }
        do {
            let result = try body(self)
            if failCommit { failCommit = false; throw StorageError.sqlite("Injected commit failure.") }
            try execute("COMMIT"); transactionCount += 1
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard let handle, sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StorageError.sqlite("Could not open the application database.")
        }
        guard let handle else { throw StorageError.sqlite("Missing database handle.") }
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK else {
            sqlite3_close(handle); self.handle = nil
            throw StorageError.sqlite("Could not read database schema version.")
        }
        let result = sqlite3_step(versionStatement)
        let version = result == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : -1
        sqlite3_finalize(versionStatement)
        guard version >= 0, version <= 1 else {
            sqlite3_close(handle); self.handle = nil
            throw StorageError.sqlite("This database was created by a newer Arpeggio version. Update the app to open it safely.")
        }
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=5000;
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);
        INSERT INTO schema_version SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM schema_version);
        UPDATE schema_version SET version=1;
        CREATE TABLE IF NOT EXISTS records(collection TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, updated REAL NOT NULL, PRIMARY KEY(collection,id));
        PRAGMA user_version=1;
        COMMIT;
        """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle); self.handle = nil
            throw StorageError.sqlite(message)
        }
    }
    public func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(statement, 0))
    }
    public func put<T: Encodable & Sendable>(_ value: T, collection: String, id: String) throws {
        let data = try JSONEncoder().encode(value)
        try putRaw(data, collection: collection, id: id)
    }
    public func putRaw(_ data: Data, collection: String, id: String) throws {
        let statement = try prepare("INSERT INTO records VALUES(?,?,?,?) ON CONFLICT(collection,id) DO UPDATE SET payload=excluded.payload, updated=excluded.updated")
        defer { sqlite3_finalize(statement) }
        bind(collection, to: statement, at: 1); bind(id, to: statement, at: 2)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    public func raw(collection: String, id: String) throws -> Data? {
        let statement = try prepare("SELECT payload FROM records WHERE collection=? AND id=?")
        defer { sqlite3_finalize(statement) }
        bind(collection, to: statement, at: 1); bind(id, to: statement, at: 2)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    public func get<T: Decodable & Sendable>(_ type: T.Type, collection: String, id: String) throws -> T? {
        try raw(collection: collection, id: id).map { try JSONDecoder().decode(type, from: $0) }
    }
    /// SQLite filters the BLOB as text, so old unfinished work is not hidden by history limits.
    public func transferRecords<T: Decodable & Sendable>(_ type: T.Type, terminalLimit: Int = 10000) throws -> [T] {
        let sql = """
        SELECT payload FROM records WHERE collection='transfers' AND
        CASE WHEN json_valid(CAST(payload AS TEXT)) THEN
          COALESCE(json_extract(CAST(payload AS TEXT),'$.status'),'') NOT IN ('completed','cancelled') ELSE 0 END
        UNION ALL SELECT payload FROM (SELECT payload FROM records WHERE collection='transfers' AND
        CASE WHEN json_valid(CAST(payload AS TEXT)) THEN
          json_extract(CAST(payload AS TEXT),'$.status') IN ('completed','cancelled') ELSE 0 END
        ORDER BY updated DESC LIMIT ?)
        """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clamping: max(0, terminalLimit)))
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw failure() }
            let count = Int(sqlite3_column_bytes(statement, 0))
            if let bytes = sqlite3_column_blob(statement, 0), let value = try? JSONDecoder().decode(type, from: Data(bytes: bytes, count: count)) { values.append(value) }
        }
    }
    public func allValid<T: Decodable & Sendable>(_ type: T.Type, collection: String, limit: Int = 10000) throws -> [T] {
        let statement = try prepare("SELECT payload FROM records WHERE collection=? ORDER BY updated DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        bind(collection, to: statement, at: 1); sqlite3_bind_int(statement, 2, Int32(clamping: max(1, limit)))
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw failure() }
            let count = Int(sqlite3_column_bytes(statement, 0))
            if let bytes = sqlite3_column_blob(statement, 0), let value = try? JSONDecoder().decode(type, from: Data(bytes: bytes, count: count)) { values.append(value) }
        }
    }
    public func all<T: Decodable & Sendable>(_ type: T.Type, collection: String, limit: Int = 10_000) throws -> [T] {
        let statement = try prepare("SELECT payload FROM records WHERE collection=? ORDER BY updated DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        bind(collection, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(max(1, min(100_000, limit))))
        var values = [T]()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw failure() }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            values.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: count)))
        }
    }
    public func remove(collection: String, id: String) throws {
        let statement = try prepare("DELETE FROM records WHERE collection=? AND id=?")
        defer { sqlite3_finalize(statement) }
        bind(collection, to: statement, at: 1); bind(id, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    public func close() { if let handle { sqlite3_close(handle); self.handle = nil } }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let handle, sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func failure() -> StorageError {
        guard let handle else { return .sqlite("Database is closed.") }
        return .sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}
