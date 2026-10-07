import SwiftUI
import ArpeggioServices
import SoulseekCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case search, downloads, uploads, browse, wishlist, messages, rooms, users, shared, received, statistics

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
        case .received: "Received Searches"
        case .statistics: "Statistics"
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
        case .received: "dot.radiowaves.left.and.right"
        case .statistics: "chart.bar.xaxis"
        }
    }

    var modifiers: EventModifiers { self == .received ? [.command, .shift] : .command }

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
        case .received: "0"
        case .statistics: "0"
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
    var confirmSignOut = false
    var showOnboarding = false
    var expandAllRequest = 0
    var collapseAllRequest = 0

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

/// sRGB components shared by SwiftUI colours and Core Graphics drawing, so they cannot drift apart.
enum BrandTone {
    static let purple = (red: 0.53, green: 0.45, blue: 0.88)
    static let muted = (red: 0.55, green: 0.55, blue: 0.57)
}

extension Color {
    static let arpeggio = Color(red: BrandTone.purple.red, green: BrandTone.purple.green, blue: BrandTone.purple.blue)
    /// The statistics card's fixed brand palette, the same in light and dark appearance.
    static let arpeggioDeep = Color(red: 0.36, green: 0.27, blue: 0.78)
    static let arpeggioNight = Color(red: 0.10, green: 0.08, blue: 0.27)
    static let arpeggioLavender = Color(red: 0.62, green: 0.52, blue: 1)
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
        bytesPerSecond > 0 ? bytes(UInt64(bytesPerSecond)) + "/s" : "-"
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "-" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
    static func clock(_ seconds: UInt32) -> String {
        guard seconds > 0 else { return "-" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension SharedFile {
    var symbol: String { isAudio ? "music.note" : "doc" }
}
