import SwiftUI
import AppKit
import ArpeggioServices
import Persistence
import ShareIndexer

struct SharedFilesView: View {
    let model: AppModel
    let navigator: Navigator
    @SceneStorage("Arpeggio.sharedMode") private var mode = Mode.folders
    @State private var dropTargeted = false
    @State private var removing: ShareFolder?

    enum Mode: String, CaseIterable { case folders = "Folders", browse = "Browse Files" }

    var body: some View {
        Group {
            switch mode {
            case .folders: folders
            case .browse: browser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            Task { await model.share(folders) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.arpeggio, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                    .background(Color.arpeggio.opacity(0.06), in: .rect(cornerRadius: 16))
                    .overlay { Label("Drop to share", systemImage: "plus.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(Color.arpeggio) }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .animation(.smooth(duration: 0.2), value: dropTargeted)
        .navigationTitle("Shared Files")
        .navigationSubtitle(model.sharedCount > 0 ? "\(model.sharedCount.formatted()) files · \(Format.bytes(model.sharedBytes))" : "")
        .confirmationDialog("Stop sharing \(removing.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { folder in
            Button("Stop Sharing", role: .destructive) { Task { await model.unshare(folder) } }
        } message: { _ in
            Text("Files stay on your Mac. People can no longer browse or download them, and queued uploads from this folder are cancelled.")
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button("Add Folder", systemImage: "plus") { add() }
                    .help("Share another folder")
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await model.rescanShares() } }
                    .disabled(model.indexing || model.settings.sharedFolders.isEmpty)
                    .help("Index the shared folders again")
            }
        }
    }

    private var folders: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if let music = AppModel.musicFolder, !model.settings.sharedFolders.contains(where: { $0.path == music.standardizedFileURL.path }) {
                    suggestion(music)
                }
                ForEach(model.settings.sharedFolders) { folder in
                    FolderCard(folder: folder, summary: model.shareSummaries[folder.path], indexing: model.indexing) { trusted in
                        Task { await model.setTrustedOnly(folder, trusted) }
                    } remove: { removing = folder }
                }
                dropZone
                exclusions
                if !model.shareErrors.isEmpty {
                    DisclosureGroup("\(model.shareErrors.count) items couldn’t be read") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.shareErrors.prefix(50), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private var summary: some View {
        let audio = model.shareSummaries.values.reduce(0) { $0 + $1.audioFiles }
        let directories = model.shareSummaries.values.reduce(0) { $0 + $1.folders }
        return HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle().fill(Color.arpeggio.opacity(0.14)).frame(width: 64, height: 64)
                Image(systemName: model.sharedCount > 0 ? "externaldrive.fill.badge.wifi" : "externaldrive.badge.plus")
                    .font(.system(size: 26)).foregroundStyle(Color.arpeggio)
                    .symbolEffect(.pulse, options: .repeating, isActive: model.indexing || model.activeUploads > 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.sharedCount > 0 ? "Sharing \(model.sharedCount.formatted()) files" : "You aren’t sharing anything yet")
                    .font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.sharedCount > 0 {
                HStack(spacing: 18) {
                    stat(Format.bytes(model.sharedBytes), "Size")
                    stat(directories.formatted(), "Folders")
                    stat(model.sharedCount > 0 ? (Double(audio) / Double(model.sharedCount)).formatted(.percent.precision(.fractionLength(0))) : "-", "Audio")
                    stat(model.activeUploads.formatted(), "Uploading")
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 16))
    }

    private var statusLine: String {
        if model.indexing { return model.shareProgress.description }
        if model.settings.sharedFolders.isEmpty { return "Add a folder so people can browse and download from you." }
        if !model.connection.isConnected { return "Indexed. Visible to others once you’re connected." }
        return "Visible to everyone on Soulseek. Changes in these folders are picked up automatically."
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.headline).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func suggestion(_ music: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.house.fill").font(.title2).foregroundStyle(Color.arpeggio)
            VStack(alignment: .leading, spacing: 1) {
                Text("Share your Music folder").font(.headline)
                Text((music.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Share") { Task { await model.share([music]) } }.buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.arpeggio.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private var dropZone: some View {
        Button(action: add) {
            VStack(spacing: 6) {
                Image(systemName: "folder.badge.plus").font(.system(size: 26)).foregroundStyle(Color.arpeggio)
                Text("Add a folder").font(.headline)
                Text("Click to choose, or drop folders from Finder anywhere here.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var exclusions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Never share files named").font(.headline)
            TextField("e.g. *.cue, *.log, Scans", text: Binding(
                get: { (model.settings.shareExclusions ?? []).joined(separator: ", ") },
                set: { model.settings.shareExclusions = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.saveSettings() } }
            Text("Comma-separated names or patterns, matched against file and folder names. Press Return to apply. Hidden files and symbolic links are always skipped.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var browser: some View {
        if model.settings.sharedFolders.isEmpty || model.sharedLibrary.isEmpty {
            ContentUnavailableView {
                Label(model.indexing ? "Indexing…" : "Nothing to Browse", systemImage: "externaldrive")
            } description: {
                Text(model.indexing ? "Your folders are being indexed." : "Share a folder to see exactly what other people see.")
            } actions: {
                if !model.indexing { Button("Add Folder…", action: add) }
            }
        } else {
            LibraryBrowser(folders: model.sharedLibrary, identity: "local-\(model.sharedCount)-\(model.sharedBytes)", rootTitle: "My Shares") { files, folder in
                let urls = files.isEmpty ? [folder.flatMap { localURL(path: $0) }].compactMap { $0 } : files.compactMap { localURL(path: $0.path) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }.disabled(urls.isEmpty)
                Button("Copy Share Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(files.isEmpty ? (folder ?? "") : files.map(\.path).joined(separator: "\n"), forType: .string)
                }
            } onOpen: { files in
                NSWorkspace.shared.activateFileViewerSelecting(files.compactMap { localURL(path: $0.path) })
            }
        }
    }

    private func add() {
        let urls = FolderPicker.choose(prompt: "Share", multiple: true)
        Task { await model.share(urls) }
    }

    /// Maps a virtual share path ("Root\\Sub\\file") back to the configured local folder.
    private func localURL(path: String) -> URL? {
        let parts = path.split(separator: "\\").map(String.init)
        guard let head = parts.first,
              let share = model.settings.sharedFolders.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().lastPathComponent == head })
        else { return nil }
        let url = parts.dropFirst().reduce(URL(fileURLWithPath: share.path).resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

private struct FolderCard: View {
    let folder: ShareFolder
    let summary: ShareRootSummary?
    let indexing: Bool
    let setTrusted: @MainActor @Sendable (Bool) -> Void
    let remove: () -> Void
    @State private var hovering = false

    private var url: URL { URL(fileURLWithPath: folder.path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: folder.path) }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: exists ? (url.lastPathComponent == "Music" ? "music.note.house.fill" : "folder.fill") : "questionmark.folder.fill")
                .font(.system(size: 28))
                .foregroundStyle(exists ? Color.arpeggio : .orange)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.headline)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(folder.path)
                Group {
                    if !exists {
                        Text("This folder is missing or its drive isn’t connected.").foregroundStyle(.orange)
                    } else if let summary {
                        Text("\(summary.files.formatted()) files · \(Format.bytes(summary.bytes)) · \(summary.folders.formatted()) folders")
                            .monospacedDigit().foregroundStyle(.secondary)
                    } else if indexing {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Indexing…") }.foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 10)
            Picker("Visible to", selection: Binding(get: { folder.buddyOnly }, set: setTrusted)) {
                Label("Everyone", systemImage: "globe").tag(false)
                Label("Trusted users", systemImage: "person.badge.shield.checkmark").tag(true)
            }
            .labelsHidden()
            .fixedSize()
            .help("Trusted-only folders are visible only to users you mark as trusted in Users")
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(.borderless).help("Show in Finder").disabled(!exists)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Stop sharing this folder")
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(hovering ? 0.12 : 0.06)))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
    }
}
