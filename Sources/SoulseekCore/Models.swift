import Foundation

public struct SharedFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var size: UInt64
    public var attributes: [UInt32: UInt32]
    public init(path: String, size: UInt64, attributes: [UInt32: UInt32] = [:]) {
        self.path = path; self.size = size; self.attributes = attributes
    }
    public var name: String { path.split(separator: "\\").last.map(String.init) ?? path }
    public var folder: String { path.split(separator: "\\").dropLast().joined(separator: "\\") }
    public var format: String { (name as NSString).pathExtension.uppercased() }
    public var quality: String {
        if let depth = attributes[5], let rate = attributes[4] {
            return "\(depth)-bit / \(Double(rate) / 1000) kHz"
        }
        if let bitrate = attributes[0] { return "\(bitrate) kbps" }
        return format
    }
}

public struct SearchResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String { SearchIdentity.key(user: user, path: file.path) }
    public let user: String
    public let file: SharedFile
    public let freeSlot: Bool
    public let speed: UInt32
    public let queue: UInt32
    public init(user: String, file: SharedFile, freeSlot: Bool, speed: UInt32, queue: UInt32) {
        self.user = user; self.file = file; self.freeSlot = freeSlot; self.speed = speed; self.queue = queue
    }
}

public struct RemoteLibrary: Codable, Sendable {
    public var user: String
    public var folders: [String: [SharedFile]]
    public init(user: String, folders: [String: [SharedFile]]) { self.user = user; self.folders = folders }
}
public struct UserStatistics: Codable, Sendable {
    public var speed: UInt32
    public var files: UInt32
    public var country: String?
    public init(speed: UInt32, files: UInt32, country: String?) { self.speed = speed; self.files = files; self.country = country }
}

public enum ConnectionState: Equatable, Sendable {
    case offline, connecting, connected, reconnecting, failed(String)
    public var label: String {
        switch self {
        case .offline: "Offline"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .failed: "Connection unavailable"
        }
    }
}

public enum SoulseekEvent: Sendable {
    case state(ConnectionState)
    case search(UInt32, [SearchResult])
    case library(RemoteLibrary)
    case privateMessage(id: UInt32, user: String, text: String, timestamp: UInt32)
    case roomMessage(room: String, user: String, text: String)
    case roomList([(String, UInt32)])
    case roomJoined(String, [String])
    case userStatus(String, UInt32)
    case userInfo(String, String, Data?)
    case wishlistInterval(UInt32)
    case peerMessage(String, UInt32, Data)
    case fileConnection(String, FramedConnection)
    case searchRequest(String, UInt32, String)
    case peerUnavailable(String)
    case roomMembership(String, String, Bool)
    case userStats(String, UInt32, UInt32, String?)
    case privileges(UInt32)
    case diagnostic(String)
}
