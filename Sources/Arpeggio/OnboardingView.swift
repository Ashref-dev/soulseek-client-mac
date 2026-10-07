import SwiftUI
import AppKit
import ArpeggioServices
import Persistence

/// What people should know before they sign in and share, as plain data so the copy is tested.
enum OnboardingContent {
    struct Point: Equatable {
        let symbol: String
        let title: String
        let detail: String
    }

    static let privacy: [Point] = [
        Point(symbol: "person.text.rectangle", title: "Your username is public",
              detail: "People see it in search results, rooms, messages and transfers."),
        Point(symbol: "network", title: "People you connect with see your IP address",
              detail: "Soulseek is peer to peer: transfers and browsing go directly between your Mac and theirs."),
        Point(symbol: "folder", title: "Anyone can browse what you share",
              detail: "Folder and file names inside your shared folders, with sizes and audio quality, are visible to everyone. Only the folders you choose are shared."),
        Point(symbol: "person.2.badge.key", title: "Trusted-only folders stay private",
              detail: "Mark a shared folder Trusted users only, and only the people you mark as trusted can see or download it."),
        Point(symbol: "key", title: "Your password is sent without encryption",
              detail: "The Soulseek protocol sends it to the server as is. Use a password you don’t use anywhere else. If you choose Remember password, Arpeggio keeps it in the macOS Keychain on this Mac."),
    ]

    /// How Arpeggio describes the listening port: new profiles use the fresh default, saved ports are kept as they are.
    static func portSummary(saved: UInt16, freshDefault: UInt16 = AppSettings().listeningPort) -> String {
        saved == freshDefault
            ? "Arpeggio listens for other people on TCP port \(saved), the default for new profiles."
            : "Arpeggio keeps your saved TCP port \(saved). It never changes a saved port on its own."
    }

    static let routerNote = "If your router supports NAT-PMP or UPnP, Arpeggio asks it to open the port when you connect. Some routers ignore these requests, and an acknowledgment doesn’t prove people can reach you. If automatic mapping is unavailable, try a matching manual TCP rule. Firewalls, VPNs and upstream NAT can still prevent incoming connections."
}

/// Step order and when Continue is allowed. Skip buttons cover the optional steps.
struct OnboardingFlow {
    enum Step: Int, CaseIterable { case welcome, privacy, account, share, network, downloads }

    static func next(_ step: Step) -> Step? { Step(rawValue: step.rawValue + 1) }
    static func previous(_ step: Step) -> Step? { Step(rawValue: step.rawValue - 1) }

    static func canContinue(_ step: Step, connected: Bool, sharedFolders: Int) -> Bool {
        switch step {
        case .account: connected
        case .share: sharedFolders > 0
        default: true
        }
    }

    static func skipTitle(_ step: Step, connected: Bool, sharedFolders: Int) -> String? {
        switch step {
        case .account where !connected: "Skip for Now"
        case .share where sharedFolders == 0: "Not Now"
        default: nil
        }
    }
}

struct OnboardingView: View {
    let model: AppModel
    let navigator: Navigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.welcome
    @State private var showLogin = false

    typealias Step = OnboardingFlow.Step

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                GeometryReader { proxy in
                    ScrollView {
                        page(step).frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .id(step)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Divider()
            footer.padding(16)
        }
        .frame(width: 640)
        .frame(minHeight: 440, idealHeight: 640, maxHeight: 640)
        .tint(.arpeggio)
        .sheet(isPresented: $showLogin) { LoginSheet(model: model) }
        .interactiveDismissDisabled()
    }

    @ViewBuilder private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: welcome
        case .privacy: privacy
        case .account: account
        case .share: share
        case .network: network
        case .downloads: downloads
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            hero(symbol: nil, title: "Welcome to Arpeggio",
                 text: "A Mac app for Soulseek, the long-running peer-to-peer network where music lovers share their libraries with each other. No servers hold the music: you download straight from other people, and they download from you.")
            VStack(alignment: .leading, spacing: 14) {
                feature("magnifyingglass", "Search everyone at once", "Results stream in from people sharing right now, grouped by person and album.")
                feature("play.circle", "Listen before you download", "Preview any track while it arrives. Keep it with one click.")
                feature("arrow.up.heart", "Share back", "Soulseek works because people share. Many users only let you download if you share something too.")
            }
            .frame(maxWidth: 440)
        }
        .padding(32)
    }

    private var privacy: some View {
        VStack(spacing: 20) {
            hero(symbol: "eye", title: "What other people can see",
                 text: "Soulseek is an open network. Before you sign in and share, here is what is visible and what stays on this Mac.")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(OnboardingContent.privacy, id: \.title) { point in feature(point.symbol, point.title, point.detail) }
            }
            .frame(maxWidth: 460)
        }
        .padding(32)
    }

    private var network: some View {
        VStack(spacing: 18) {
            hero(symbol: "point.3.connected.trianglepath.dotted", title: "Let people reach you",
                 text: OnboardingContent.portSummary(saved: model.settings.listeningPort))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(PortGuidance.instructions(port: model.settings.listeningPort).enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(Color.arpeggio)
                            .frame(width: 18, height: 18)
                            .background(Color.arpeggio.opacity(0.12), in: .circle)
                            .accessibilityHidden(true)
                        Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            .frame(maxWidth: 480)
            statusCard(symbol: "wifi.router", tint: .arpeggio, title: "Automatic router mapping", detail: OnboardingContent.routerNote)
            SettingsDestinationLink(destination: .network, model: model) { Text("Open Network Settings…") }
        }
        .padding(32)
    }

    private var account: some View {
        VStack(spacing: 22) {
            hero(symbol: "person.crop.circle.badge.checkmark", title: "Your Soulseek account",
                 text: "There’s no separate sign-up. Pick a username and password: if the name is free, the server registers it the first time you sign in.")
            if model.connection.isConnected {
                statusCard(symbol: "checkmark.circle.fill", tint: .green, title: "Signed in as \(model.activeAccount)",
                           detail: "Arpeggio signs in automatically each time it opens.")
            } else {
                VStack(spacing: 10) {
                    Button { showLogin = true } label: {
                        Label(model.settings.username.isEmpty ? "Sign In or Create Account…" : "Sign In as \(model.settings.username)…", systemImage: "person.badge.key")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if model.connection.isBusy {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(model.connection.label).foregroundStyle(.secondary) }
                    }
                    Text("Soulseek sends passwords without encryption, so use one you don’t use anywhere else. Your username is visible to other people.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
            }
        }
        .padding(32)
    }

    private var share: some View {
        VStack(spacing: 18) {
            hero(symbol: "externaldrive.badge.person.crop", title: "Share your music",
                 text: "Pick the folders other people can browse and download from. Everyone can see the folder and file names inside them. Only what you choose is shared; hidden files and symbolic links never are. Mark a folder Trusted users only in Shared Files to limit it to people you trust.")
            shareChoices
            if !model.settings.sharedFolders.isEmpty { sharedFolderList }
            VStack(alignment: .leading, spacing: 12) {
                SharingRequirementControls(model: model)
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            .frame(maxWidth: 480)
        }
        .padding(32)
    }

    private var musicFolderShared: Bool {
        guard let music = AppModel.musicFolder else { return false }
        return model.settings.sharedFolders.contains { $0.path == music.standardizedFileURL.path }
    }

    private var shareChoices: some View {
        VStack(spacing: 10) {
            if let music = AppModel.musicFolder {
                if musicFolderShared {
                    Button {} label: {
                        Label("Music Folder Shared", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                } else {
                    Button { Task { await model.share([music]) } } label: {
                        Label("Share My Music Folder", systemImage: "music.note.house").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if AppModel.musicFolder == nil {
                customFolderButton.buttonStyle(.borderedProminent)
            } else {
                customFolderButton.buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .frame(width: 300)
    }

    private var customFolderButton: some View {
        Button {
            let urls = FolderPicker.choose(prompt: "Share", multiple: true)
            Task { await model.share(urls) }
        } label: {
            Label("Choose a Custom Folder…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
        }
        .help("Share any folder on this Mac, such as a music library on an external drive")
    }

    private var sharedFolderList: some View {
        VStack(spacing: 0) {
            ForEach(model.settings.sharedFolders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.arpeggio)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: folder.path).lastPathComponent).font(.callout.weight(.medium))
                        Text((folder.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let summary = model.shareSummaries[folder.path] {
                        Text("\(summary.files.formatted()) files · \(Format.bytes(summary.bytes))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else if model.indexing {
                        ProgressView().controlSize(.small)
                    }
                    Button { Task { await model.unshare(folder) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Stop sharing")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                if folder.id != model.settings.sharedFolders.last?.id { Divider() }
            }
            if model.indexing {
                Text(model.shareProgress.description)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .frame(maxWidth: 480)
    }

    private var downloads: some View {
        VStack(spacing: 18) {
            hero(symbol: "arrow.down.circle", title: "Where downloads go",
                 text: "Each album lands in its own folder inside your download folder. No user folders, no “incomplete” or “complete” folders to dig through. Unfinished files stay hidden until they’re done.")
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Color.arpeggio)
                Text((model.settings.downloadDirectory as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…") {
                    if let url = FolderPicker.choose(prompt: "Use Folder", multiple: false).first {
                        model.settings.downloadDirectory = url.path
                        Task { await model.saveSettings() }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            .frame(maxWidth: 480)
            statusCard(symbol: "menubar.arrow.up.rectangle", tint: .arpeggio, title: "Keeps sharing in the background",
                       detail: "Close the window and Arpeggio stays in the menu bar, so people can keep downloading from you. Quit it from the menu bar icon.")
        }
        .padding(32)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule().fill(item == step ? Color.arpeggio : Color.secondary.opacity(0.3))
                        .frame(width: item == step ? 18 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.3), value: step)
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Spacer()
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            if let skip = OnboardingFlow.skipTitle(step, connected: model.connection.isConnected, sharedFolders: model.settings.sharedFolders.count) {
                Button(skip) { move(1) }
            }
            Button(step == .downloads ? "Start Exploring" : "Continue") {
                if step == .downloads { finish() } else { move(1) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!OnboardingFlow.canContinue(step, connected: model.connection.isConnected, sharedFolders: model.settings.sharedFolders.count))
        }
    }

    private func move(_ delta: Int) {
        guard let next = delta > 0 ? OnboardingFlow.next(step) : OnboardingFlow.previous(step) else { return }
        if step == .share { Task { await model.saveSettings() } }
        withAnimation(reduceMotion ? .default : .spring(duration: 0.4, bounce: 0.15)) { step = next }
    }

    private func finish() {
        model.settings.onboardingVersion = 1
        Task { await model.saveSettings() }
        dismiss()
        navigator.focusSearch()
    }

    private func hero(symbol: String?, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .light))
                        .symbolEffect(.bounce, options: .nonRepeating, value: step)
                } else {
                    ArpeggioLogo().frame(width: 58, height: 58)
                }
            }
            .foregroundStyle(Color.arpeggio)
            .frame(height: 60)
            Text(title).font(.title.weight(.semibold))
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.arpeggio)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusCard(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .frame(maxWidth: 480)
    }
}
