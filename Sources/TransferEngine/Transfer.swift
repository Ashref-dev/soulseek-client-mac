import Foundation
import SoulseekCore

public enum TransferStatus: String, Codable, Sendable {
    case queued, negotiating, transferring, paused, completed, failed, cancelled
}

public struct Transfer: Codable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var user: String
    public var file: SharedFile
    public var upload: Bool
    public var status: TransferStatus = .queued
    public var transferred: UInt64 = 0
    public var speed: Double = 0
    public var queuePosition: UInt32 = 0
    public var destination: String?
    public var partial: String?
    public var error: String?
    public var retries = 0
    public var date = Date()
    public var token: UInt32?
    public var preview: Bool?
    public var bytesMoved: UInt64?
    public var isPreview: Bool { preview == true }
    public var progress: Double { file.size == 0 ? (status == .completed ? 1 : 0) : min(1, Double(transferred) / Double(file.size)) }
    public var eta: Double? { speed > 0 ? Double(file.size - min(transferred, file.size)) / speed : nil }
    public init(user: String, file: SharedFile, upload: Bool = false) { self.user = user; self.file = file; self.upload = upload }
}
