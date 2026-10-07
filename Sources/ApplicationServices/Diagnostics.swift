import Foundation

public enum DiagnosticSeverity: String, Sendable { case info, warning, error }
public enum DiagnosticCategory: String, Sendable { case peer, server, storage, network, application }
public enum DiagnosticOperation: String, Sendable {
    case peerClosed, peerConnection, peerRequest, peerControl, serverConnection, accountConflict, storageRestore, storageSave, storageFailure, application
}

public struct DiagnosticEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let severity: DiagnosticSeverity
    public let category: DiagnosticCategory
    public let operation: DiagnosticOperation
    /// Local-only detail. Never include this string in a support report.
    public let message: String
    public init(severity: DiagnosticSeverity, category: DiagnosticCategory, message: String, timestamp: Date = Date(), operation: DiagnosticOperation = .application) {
        id = UUID(); self.timestamp = timestamp; self.severity = severity; self.category = category
        self.operation = operation
        self.message = String(message.prefix(2048))
    }
    public static func classify(_ text: String, timestamp: Date = Date()) -> Self {
        let severity: DiagnosticSeverity
        let category: DiagnosticCategory
        let operation: DiagnosticOperation
        if text.hasPrefix("Peer messaging ended:") || text.hasPrefix("Peer messaging ready:") || text.hasPrefix("Peer control ") {
            severity = .info; category = .peer
            operation = text.hasPrefix("Peer messaging ended:") ? .peerClosed : .peerControl
        } else if text.hasPrefix("Peer connection failed:") || text.hasPrefix("Peer request failed:") || text.hasPrefix("Couldn’t connect to ") {
            severity = .warning; category = .peer
            operation = text.hasPrefix("Peer request failed:") ? .peerRequest : .peerConnection
        } else if text.hasPrefix("Connection detail:") || text.hasPrefix("Server failure:") || text.hasPrefix("This account connected from another client.") {
            severity = .error; category = .server
            operation = text.hasPrefix("This account connected from another client.") ? .accountConflict : .serverConnection
        } else if text.hasPrefix("Storage failure:") || text.hasPrefix("storage error:") {
            severity = .error; category = .storage
            if text.hasPrefix("storage error: Could not restore") { operation = .storageRestore }
            else if text.hasPrefix("storage error: Could not save") { operation = .storageSave }
            else { operation = .storageFailure }
        } else { severity = .warning; category = .application; operation = .application }
        return Self(severity: severity, category: category, message: text, timestamp: timestamp, operation: operation)
    }
}

public struct DiagnosticStore: Sendable {
    private var activity: [DiagnosticEntry] = []
    private var retainedProblems: [DiagnosticEntry] = []
    public init() {}
    public var entries: [DiagnosticEntry] { (activity + retainedProblems).sorted { $0.timestamp < $1.timestamp } }
    public var problems: [DiagnosticEntry] { retainedProblems }
    public mutating func append(_ entry: DiagnosticEntry) {
        if entry.severity == .info {
            activity.append(entry); if activity.count > 200 { activity.removeFirst(activity.count - 200) }
        } else {
            retainedProblems.append(entry); if retainedProblems.count > 100 { retainedProblems.removeFirst(retainedProblems.count - 100) }
        }
    }
}
