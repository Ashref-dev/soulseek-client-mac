import SwiftUI
import AppKit
import ArpeggioServices
import Persistence

struct OnboardingView: View {
    let model: AppModel
    let navigator: Navigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.welcome
    @State private var showLogin = false

    enum Step: Int, CaseIterable { case welcome, account, share, downloads }

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
        .frame(width: 640, height: 640)
        .tint(.arpeggio)
        .sheet(isPresented: $showLogin) { LoginSheet(model: model) }
        .interactiveDismissDisabled()
    }

    @ViewBuilder private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: welcome
        case .account: account
        case .share: share
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
                    Text("Soulseek sends passwords without encryption, so use one you don’t use anywhere else.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
    }

    private var share: some View {
        VStack(spacing: 18) {
            hero(symbol: "externaldrive.badge.person.crop", title: "Share your music",
                 text: "Pick the folders other people can browse and download from. Only what you choose is shared. Hidden files and symbolic links never are.")
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
            if step == .account, !model.connection.isConnected {
                Button("Skip for Now") { move(1) }
            }
            if step == .share, model.settings.sharedFolders.isEmpty {
                Button("Not Now") { move(1) }
            }
            Button(step == .downloads ? "Start Exploring" : "Continue") {
                if step == .downloads { finish() } else { move(1) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled((step == .account && !model.connection.isConnected) || (step == .share && model.settings.sharedFolders.isEmpty))
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
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
