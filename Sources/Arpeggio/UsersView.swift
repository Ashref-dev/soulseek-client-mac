import SwiftUI
import ArpeggioServices
import SoulseekCore
import Persistence

extension UserRecord {
    var lastSeenSort: Date { lastSeen ?? .distantPast }
}

struct UsersView: View {
    let model: AppModel
    let navigator: Navigator
    @State private var selection: UserRecord.ID?
    @State private var draft = ""
    @State private var sortOrder = [KeyPathComparator(\UserRecord.username)]

    private var selected: UserRecord? { model.users.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Add a username", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            Divider()
            Group {
            if model.users.isEmpty {
                ContentUnavailableView("No Saved Users", systemImage: "person.crop.circle",
                                       description: Text("Add people to follow their status, keep notes, trust them with private shares, or ignore them."))
            } else {
                Table(model.users.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("User", value: \.username) { user in
                        HStack(spacing: 8) {
                            StatusDot(status: model.userStatuses[user.username])
                            Text(user.username).strikethrough(user.ignored, color: .secondary)
                        }
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Trusted") { user in
                        Toggle("Trusted", isOn: flag(user, \.trusted)).labelsHidden()
                    }
                    .width(56)
                    TableColumn("Ignored") { user in
                        Toggle("Ignored", isOn: flag(user, \.ignored)).labelsHidden()
                    }
                    .width(56)
                    TableColumn("Note") { Text($0.note).foregroundStyle(.secondary).lineLimit(1) }
                    TableColumn("Last Seen", value: \.lastSeenSort) { user in
                        Text(user.lastSeen.map { $0.formatted(.relative(presentation: .named)) } ?? "-").foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 110)
                }
                .contextMenu(forSelectionType: UserRecord.ID.self) { ids in
                    if let id = ids.first, let user = model.users.first(where: { $0.id == id }) {
                        UserActions(user: user.username, model: model, navigator: navigator)
                        Divider()
                        Button("Remove", role: .destructive) { Task { await model.removeUser(user) } }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { navigator.message(id) }
                }
                .onDeleteCommand { if let selected { Task { await model.removeUser(selected) } } }
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Users")
        .inspector(isPresented: .constant(selected != nil)) {
            if let selected { UserInspector(user: selected, model: model, navigator: navigator) }
        }
    }

    private func flag(_ user: UserRecord, _ key: WritableKeyPath<UserRecord, Bool>) -> Binding<Bool> {
        Binding(get: { user[keyPath: key] }, set: { value in
            var copy = user; copy[keyPath: key] = value
            Task { await model.saveUser(copy) }
        })
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        Task { await model.bookmark(name); selection = name }
    }
}

private struct UserInspector: View {
    let user: UserRecord
    let model: AppModel
    let navigator: Navigator
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    let status = model.userStatuses[user.username]
                    HStack(spacing: 6) {
                        StatusDot(status: status)
                        Text(status == 2 ? "Online" : status == 1 ? "Away" : "Offline or unknown")
                    }
                }
                Toggle("Trusted", isOn: binding(\.trusted))
                    .help("Trusted users can see trusted-only shared folders")
                Toggle("Ignored", isOn: binding(\.ignored))
                    .help("Ignore messages, searches and requests from this user")
            } header: {
                Text(user.username).font(.headline)
            }
            Section("Note") {
                TextEditor(text: $note)
                    .frame(minHeight: 80)
                    .onChange(of: note) { _, value in
                        guard value != user.note else { return }
                        var copy = user; copy.note = value
                        Task { await model.saveUser(copy) }
                    }
            }
            Section("Info") {
                if let description = model.userDescriptions[user.username], !description.isEmpty {
                    Text(description).textSelection(.enabled).font(.callout)
                } else {
                    Text("No description received.").foregroundStyle(.secondary)
                }
                Button("Request Info") { Task { await model.userInfo(user.username) } }
                    .disabled(!model.connection.isConnected)
            }
            Section {
                Button("Message") { navigator.message(user.username) }
                Button("Browse Files") { navigator.browse(user.username, model: model) }
                    .disabled(!model.connection.isConnected)
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        .task(id: user.id) { note = user.note }
    }

    private func binding(_ key: WritableKeyPath<UserRecord, Bool>) -> Binding<Bool> {
        Binding(get: { user[keyPath: key] }, set: { value in
            var copy = user; copy[keyPath: key] = value
            Task { await model.saveUser(copy) }
        })
    }
}
