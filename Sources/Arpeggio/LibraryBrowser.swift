import SwiftUI
import SoulseekCore

/// A folder in a backslash-separated Soulseek share hierarchy.
struct FolderNode: Identifiable, Hashable {
    let id: String
    let name: String
    var fileCount: Int
    var totalFiles: Int
    var totalBytes: UInt64
    var children: [FolderNode]?

    var parent: String? { id.lastIndex(of: "\\").map { String(id[..<$0]) } }

    static func tree(from folders: [String: [SharedFile]]) -> [FolderNode] {
        final class Builder {
            let path: String, name: String
            var files = 0
            var bytes: UInt64 = 0
            var children: [String: Builder] = [:]
            init(path: String, name: String) { self.path = path; self.name = name }
            func node() -> FolderNode {
                let kids = children.values.map { $0.node() }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return FolderNode(id: path, name: name, fileCount: files,
                                  totalFiles: files + kids.reduce(0) { $0 + $1.totalFiles },
                                  totalBytes: bytes + kids.reduce(0) { $0 + $1.totalBytes },
                                  children: kids.isEmpty ? nil : kids)
            }
        }
        let root = Builder(path: "", name: "")
        for (folder, files) in folders {
            var cursor = root
            var path = ""
            for component in folder.split(separator: "\\", omittingEmptySubsequences: true).map(String.init) {
                path = path.isEmpty ? component : path + "\\" + component
                if let child = cursor.children[component] {
                    cursor = child
                } else {
                    let child = Builder(path: path, name: component)
                    cursor.children[component] = child
                    cursor = child
                }
            }
            cursor.files += files.count
            cursor.bytes += files.reduce(0) { $0 + $1.size }
        }
        return root.node().children ?? []
    }

    static func index(_ nodes: [FolderNode], into map: inout [String: FolderNode]) {
        for node in nodes {
            map[node.id] = node
            if let children = node.children { index(children, into: &map) }
        }
    }
}

/// A row in the browser table: either a subfolder or a file.
struct BrowserEntry: Identifiable {
    let id: String
    let name: String
    let folder: FolderNode?
    let file: SharedFile?

    init(folder: FolderNode) { id = "d:" + folder.id; name = folder.name; self.folder = folder; file = nil }
    init(file: SharedFile) { id = "f:" + file.path; name = file.name; folder = nil; self.file = file }

    var isFolder: Bool { folder != nil }
    var size: UInt64 { file?.size ?? folder?.totalBytes ?? 0 }
    var quality: String { file?.quality ?? "" }
    var length: UInt32 { file?.length ?? 0 }
    var location: String { file?.folder ?? folder?.parent ?? "" }
}

/// Finder-like browser for a share hierarchy (remote or local): folder outline, breadcrumb,
/// back/forward history, search across every file, and a table of the current folder.
struct LibraryBrowser<Actions: View>: View {
    let folders: [String: [SharedFile]]
    let identity: String
    var rootTitle = "All Folders"
    @ViewBuilder let fileMenu: (_ files: [SharedFile], _ folder: String?) -> Actions
    var onOpen: ([SharedFile]) -> Void = { _ in }

    @State private var tree: [FolderNode] = []
    @State private var index: [String: FolderNode] = [:]
    @State private var folder: String?
    @State private var back: [String?] = []
    @State private var forward: [String?] = []
    @State private var expanded = Set<String>()
    @State private var selection = Set<BrowserEntry.ID>()
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\BrowserEntry.name, comparator: .localizedStandard)]

    private static var resultLimit: Int { 2000 }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let rows = entries
        HSplitView {
            List(selection: Binding(get: { folder }, set: { if let path = $0 { open(path) } })) {
                ForEach(tree) { node in
                    FolderOutlineRow(node: node, expanded: $expanded) { path in fileMenu([], path) }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 200, idealWidth: 270, maxWidth: 420)

            VStack(spacing: 0) {
                header(count: rows.count)
                Divider()
                content(rows).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search \(rootTitle)")
        .onChange(of: query) { selection.removeAll() }
        .task(id: identity) { rebuild() }
    }

    // MARK: Content

    private var entries: [BrowserEntry] {
        let raw: [BrowserEntry]
        if searching {
            let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            func matches(_ text: String) -> Bool { let text = text.lowercased(); return terms.allSatisfy { text.contains($0) } }
            let dirs = index.values.lazy.filter { matches($0.name) }.prefix(200).map(BrowserEntry.init(folder:))
            let files = folders.values.lazy.joined().filter { matches($0.path) }.prefix(Self.resultLimit).map(BrowserEntry.init(file:))
            raw = Array(dirs) + Array(files)
        } else {
            let subfolders = folder.map { index[$0]?.children ?? [] } ?? tree
            raw = subfolders.map(BrowserEntry.init(folder:)) + (folders[folder ?? ""] ?? []).map(BrowserEntry.init(file:))
        }
        let sorted = raw.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    @ViewBuilder private func content(_ rows: [BrowserEntry]) -> some View {
        if rows.isEmpty {
            if searching {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("There are no files in this folder."))
            }
        } else {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { entry in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).lineLimit(1)
                            if searching && !entry.location.isEmpty {
                                Text(entry.location.replacingOccurrences(of: "\\", with: " › "))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                    } icon: {
                        Image(systemName: entry.isFolder ? "folder.fill" : entry.file?.symbol ?? "doc")
                            .foregroundStyle(entry.isFolder ? Color.arpeggio : Color.secondary)
                    }
                    .help(entry.file?.path ?? entry.folder?.id ?? entry.name)
                }
                .width(min: 200, ideal: 340)
                TableColumn("Size", value: \.size) { entry in
                    Text(Format.bytes(entry.size)).monospacedDigit().foregroundStyle(entry.isFolder ? .secondary : .primary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Quality", value: \.quality) { entry in
                    if let node = entry.folder {
                        Text("\(node.totalFiles.formatted()) files").foregroundStyle(.secondary)
                    } else {
                        Text(entry.quality).lineLimit(1)
                    }
                }
                .width(min: 70, ideal: 110)
                TableColumn("Length", value: \.length) { Text(Format.clock($0.length)).monospacedDigit() }
                    .width(min: 44, ideal: 56)
            }
            .contextMenu(forSelectionType: BrowserEntry.ID.self) { ids in
                menu(for: rows.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                let picked = rows.filter { ids.contains($0.id) }
                if picked.count == 1, let node = picked.first?.folder { open(node.id) }
                else { onOpen(picked.compactMap(\.file)) }
            }
        }
    }

    @ViewBuilder private func menu(for picked: [BrowserEntry]) -> some View {
        let files = picked.compactMap(\.file)
        if files.isEmpty, let node = picked.first?.folder {
            Button("Open") { open(node.id) }
            Divider()
            fileMenu([], node.id)
        } else if !files.isEmpty {
            let parents = Set(files.map(\.folder))
            if searching, parents.count == 1, let parent = parents.first {
                Button("Show in Enclosing Folder") { open(parent, select: files.map { "f:" + $0.path }) }
                Divider()
            }
            fileMenu(files, parents.count == 1 ? parents.first : nil)
        }
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(spacing: 4) {
            Button("Back", systemImage: "chevron.left", action: goBack)
                .disabled(back.isEmpty)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
            Button("Forward", systemImage: "chevron.right", action: goForward)
                .disabled(forward.isEmpty)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")
            Button("Enclosing Folder", systemImage: "chevron.up") { open(folder.flatMap { index[$0]?.parent }) }
                .disabled(folder == nil || searching)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Enclosing Folder")
            Divider().frame(height: 14).padding(.horizontal, 4)
            if searching {
                Text(count >= Self.resultLimit ? "First \(count.formatted()) matches in \(rootTitle)" : "\(count.formatted()) matches in \(rootTitle)")
                    .foregroundStyle(.secondary)
            } else {
                breadcrumb
            }
            Spacer(minLength: 8)
            if !searching, let node = folder.flatMap({ index[$0] }) {
                Text("\(node.totalFiles.formatted()) files · \(Format.bytes(node.totalBytes))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var breadcrumb: some View {
        let components = folder.map { $0.split(separator: "\\").map(String.init) } ?? []
        return HStack(spacing: 2) {
            crumb(rootTitle, path: nil, current: components.isEmpty)
            ForEach(components.indices, id: \.self) { position in
                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                crumb(components[position], path: components[...position].joined(separator: "\\"), current: position == components.count - 1)
            }
        }
        .truncationMode(.middle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private func crumb(_ title: String, path: String?, current: Bool) -> some View {
        Button { open(path) } label: {
            Text(title)
                .fontWeight(current ? .semibold : .regular)
                .foregroundStyle(current ? .primary : .secondary)
        }
        .labelStyle(.titleOnly)
        .disabled(current && !searching)
    }

    // MARK: Navigation

    private func open(_ path: String?, select: [String] = []) {
        if path != folder {
            back.append(folder)
            forward.removeAll()
        }
        show(path)
        selection = Set(select)
    }

    private func goBack() {
        guard let target = back.popLast() else { return }
        forward.append(folder)
        show(target)
    }

    private func goForward() {
        guard let target = forward.popLast() else { return }
        back.append(folder)
        show(target)
    }

    private func show(_ path: String?) {
        folder = path
        query = ""
        selection.removeAll()
        var ancestor = path.flatMap { index[$0]?.parent }
        while let current = ancestor {
            expanded.insert(current)
            ancestor = index[current]?.parent
        }
    }

    private func rebuild() {
        tree = FolderNode.tree(from: folders)
        var map: [String: FolderNode] = [:]
        FolderNode.index(tree, into: &map)
        index = map
        func valid(_ path: String?) -> Bool { path.map { map[$0] != nil } ?? true }
        if !valid(folder) { folder = nil }
        back = back.filter(valid)
        forward = forward.filter(valid)
        expanded = expanded.filter { map[$0] != nil }
        selection.removeAll()
        if expanded.isEmpty {
            // Open top-level shares, and follow single-child chains (e.g. "Music › Artist") a few levels deep.
            for node in tree {
                expanded.insert(node.id)
                var chain = node.children
                var depth = 0
                while let only = chain, only.count == 1, let next = only.first, depth < 3 {
                    expanded.insert(next.id)
                    chain = next.children
                    depth += 1
                }
            }
        }
    }
}

private struct FolderOutlineRow<Menu: View>: View {
    let node: FolderNode
    @Binding var expanded: Set<String>
    let menu: (String) -> Menu

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(node.id) },
                set: { if $0 { expanded.insert(node.id) } else { expanded.remove(node.id) } }
            )) {
                ForEach(children) { child in
                    FolderOutlineRow(node: child, expanded: $expanded, menu: menu)
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label {
            HStack {
                Text(node.name).lineLimit(1)
                Spacer(minLength: 4)
                Text(node.totalFiles.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: "folder").foregroundStyle(Color.arpeggio)
        }
        .tag(node.id)
        .contextMenu { menu(node.id) }
        .accessibilityLabel("\(node.name), \(node.totalFiles) files")
    }
}
