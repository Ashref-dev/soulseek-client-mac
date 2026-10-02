import SwiftUI
import ArpeggioServices
import SoulseekCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case search, downloads, uploads, browse, wishlist, messages, rooms, users, shared

    var id: Self { self }

    var title: String {
        switch self {
        case .search: "Search"
        case .downloads: "Downloads"
        case .uploads: "Uploads"
        case .browse: "Browse"
        case .wishlist: "Wishlist"
        case .messages: "Messages"
        case .rooms: "Rooms"
        case .users: "Users"
        case .shared: "Shared Files"
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .uploads: "arrow.up.circle"
        case .browse: "folder"
        case .wishlist: "star"
        case .messages: "bubble.left.and.bubble.right"
        case .rooms: "person.3"
        case .users: "person.crop.circle"
        case .shared: "externaldrive"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .search: "1"
        case .downloads: "2"
        case .uploads: "3"
        case .browse: "4"
        case .wishlist: "5"
        case .messages: "6"
        case .rooms: "7"
        case .users: "8"
        case .shared: "9"
        }
    }
}

enum UserPrompt: String, Identifiable {
    case message, browse
    var id: Self { self }
}

/// A request to show a user's profile sheet.
struct ProfileRequest: Identifiable, Hashable {
    let username: String
    var id: String { username }
}

/// Per-window navigation state, exposed to menu commands through focused scene values.
@MainActor @Observable
final class Navigator {
    var section: SidebarSection? = .search
    var showLogin = false
    var showPalette = false
    var prompt: UserPrompt?
    var conversation: String?
    var selectedRoom: String?
    var searchFocusRequest = 0
    var profile: ProfileRequest?

    func go(_ section: SidebarSection) { self.section = section }

    func focusSearch() {
        section = .search
        searchFocusRequest += 1
    }

    func showProfile(_ user: String) {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        profile = ProfileRequest(username: name)
    }

    func message(_ user: String) {
        conversation = user
        section = .messages
    }

    func browse(_ user: String, model: AppModel) {
        section = .browse
        Task { await model.browse(user) }
    }

    func runSearch(_ text: String, model: AppModel) {
        model.query = text
        section = .search
        Task { await model.search() }
    }
}

extension FocusedValues {
    @Entry var navigator: Navigator?
}

extension Color {
    static let arpeggio = Color(red: 0.53, green: 0.45, blue: 0.88)
}

extension ConnectionState {
    var isConnected: Bool { self == .connected }
    var isBusy: Bool { self == .connecting || self == .reconnecting }
    var tint: Color {
        switch self {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .failed: .red
        case .offline: .secondary
        }
    }
    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond > 0 ? bytes(UInt64(bytesPerSecond)) + "/s" : "—"
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
    static func clock(_ seconds: UInt32) -> String {
        guard seconds > 0 else { return "—" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension SharedFile {
    var bitrate: UInt32 { attributes[0] ?? 0 }
    var length: UInt32 { attributes[1] ?? 0 }
    var isAudio: Bool { ["FLAC", "MP3", "OGG", "OPUS", "M4A", "AAC", "WAV", "AIFF", "AIF", "ALAC", "APE", "WV"].contains(format) }
    var symbol: String { isAudio ? "music.note" : "doc" }
}
