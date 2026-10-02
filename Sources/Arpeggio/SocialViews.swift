import SwiftUI
import ArpeggioServices
import SoulseekCore
import Persistence

struct Transcript: View {
    let messages: [ChatMessage]
    let showSender: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { message in
                        MessageRow(message: message, showSender: showSender).id(message.id)
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, id in
                if let id { withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let showSender: Bool
    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 80) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 2) {
                if showSender && !message.outgoing {
                    Text(message.user).font(.caption.weight(.semibold)).foregroundStyle(Color.arpeggio)
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(message.outgoing ? Color.arpeggio.opacity(0.18) : Color.secondary.opacity(0.1),
                                in: .rect(cornerRadius: 13))
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !message.outgoing { Spacer(minLength: 80) }
        }
    }
}

struct Composer: View {
    let placeholder: String
    let enabled: Bool
    let send: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(submit)
            Button("Send", systemImage: "arrow.up.circle.fill", action: submit)
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.borderless)
                .disabled(!enabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .disabled(!enabled)
        .padding(12)
    }
    private func submit() {
        guard enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(text); text = ""
    }
}

struct MessagesView: View {
    let model: AppModel
    @Bindable var navigator: Navigator

    private var conversations: [String] {
        var latest: [String: Date] = [:]
        for message in model.messages where message.room == nil { latest[message.user] = max(latest[message.user] ?? .distantPast, message.date) }
        if let current = navigator.conversation, latest[current] == nil { latest[current] = .now }
        return latest.sorted { $0.value > $1.value }.map(\.key)
    }

    var body: some View {
        let conversations = conversations
        Group {
            if conversations.isEmpty {
                ContentUnavailableView {
                    Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Private messages you send or receive appear here.")
                } actions: {
                    Button("New Message…") { navigator.prompt = .message }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                split(conversations)
            }
        }
        .navigationTitle("Messages")
        .navigationSubtitle(navigator.conversation ?? "")
        .toolbar {
            Button("New Message", systemImage: "square.and.pencil") { navigator.prompt = .message }
        }
        .onAppear { markRead(navigator.conversation) }
        .onChange(of: navigator.conversation) { _, user in markRead(user) }
        .onDisappear { model.activeConversation = nil }
    }

    private func split(_ conversations: [String]) -> some View {
        HSplitView {
            List(conversations, id: \.self, selection: $navigator.conversation) { user in
                HStack {
                    StatusDot(status: model.userStatuses[user])
                    Text(user).fontWeight(model.unread.contains(user) ? .semibold : .regular)
                    Spacer()
                    if model.unread.contains(user) { Circle().fill(Color.arpeggio).frame(width: 7, height: 7) }
                }
                .tag(user)
                .contextMenu { UserActions(user: user, model: model, navigator: navigator) }
            }
            .listStyle(.inset)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)

            Group {
                if let user = navigator.conversation {
                    VStack(spacing: 0) {
                        OfflineNotice(model: model, navigator: navigator)
                        Transcript(messages: model.messages.filter { $0.room == nil && $0.user == user }, showSender: false)
                        Divider()
                        Composer(placeholder: "Message \(user)", enabled: model.connection.isConnected) { text in
                            Task { await model.sendMessage(to: user, text: text) }
                        }
                    }
                } else {
                    ContentUnavailableView("Select a Conversation", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func markRead(_ user: String?) {
        model.activeConversation = user
        if let user { model.unread.remove(user) }
    }
}

struct RoomsView: View {
    let model: AppModel
    @Bindable var navigator: Navigator
    @State private var filter = ""
    @State private var showMembers = true

    var body: some View {
        Group {
            if model.rooms.isEmpty && model.joinedRooms.isEmpty {
                ContentUnavailableView {
                    Label("Chat Rooms", systemImage: "person.3")
                } description: {
                    if model.connection.isConnected {
                        Text("Waiting for the server’s room list…")
                    } else {
                        Text("Connect to see and join public chat rooms.")
                    }
                } actions: {
                    if model.connection.isConnected {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Connect…") { navigator.showLogin = true }.disabled(model.connection.isBusy)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                split.searchable(text: $filter, placement: .toolbar, prompt: "Filter rooms")
            }
        }
        .navigationTitle("Rooms")
        .navigationSubtitle(navigator.selectedRoom ?? "")
        .toolbar {
            if let room = navigator.selectedRoom {
                if model.joinedRooms[room] != nil {
                    Toggle(isOn: $showMembers) { Label("Members", systemImage: "person.2") }
                    Button("Leave", systemImage: "rectangle.portrait.and.arrow.right") { Task { await model.leaveRoom(room) } }
                        .disabled(!model.connection.isConnected)
                } else {
                    Button("Join", systemImage: "plus.bubble") { Task { await model.joinRoom(room) } }
                        .disabled(!model.connection.isConnected)
                }
            }
        }
    }

    private var split: some View {
        HSplitView {
            List(selection: $navigator.selectedRoom) {
                if !model.joinedRooms.isEmpty {
                    Section("Joined") {
                        ForEach(model.joinedRooms.keys.sorted(), id: \.self) { room in
                            Label(room, systemImage: "number").tag(room)
                                .contextMenu { Button("Leave Room") { Task { await model.leaveRoom(room) } } }
                        }
                    }
                }
                Section("All Rooms") {
                    ForEach(model.rooms.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.prefix(500)) { room in
                        HStack {
                            Text(room.name).lineLimit(1)
                            Spacer()
                            Text(room.users.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(room.name)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            roomDetail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var roomDetail: some View {
        if let room = navigator.selectedRoom, let members = model.joinedRooms[room] {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    OfflineNotice(model: model, navigator: navigator)
                    Transcript(messages: model.messages.filter { $0.room == room }, showSender: true)
                    Divider()
                    Composer(placeholder: "Message #\(room)", enabled: model.connection.isConnected) { text in
                        Task { await model.sendMessage(to: room, text: text, room: true) }
                    }
                }
                if showMembers {
                    Divider()
                    List(members.sorted(), id: \.self) { user in
                        Text(user).lineLimit(1).contextMenu { UserActions(user: user, model: model, navigator: navigator) }
                    }
                    .listStyle(.inset)
                    .frame(width: 170)
                }
            }
        } else if let room = navigator.selectedRoom {
            ContentUnavailableView {
                Label(room, systemImage: "number")
            } description: {
                Text("Join this room to read and send messages.")
            } actions: {
                Button("Join Room") { Task { await model.joinRoom(room) } }.disabled(!model.connection.isConnected)
            }
        } else {
            ContentUnavailableView("Select a Room", systemImage: "person.3", description: Text("Pick a room to read along or join the conversation."))
        }
    }
}

struct StatusDot: View {
    let status: UInt32?
    var body: some View {
        Circle()
            .fill(status == 2 ? Color.green : status == 1 ? Color.orange : Color.secondary.opacity(0.4))
            .frame(width: 7, height: 7)
            .help(status == 2 ? "Online" : status == 1 ? "Away" : "Offline")
            .accessibilityLabel(status == 2 ? "Online" : status == 1 ? "Away" : "Offline")
    }
}

struct UserActions: View {
    let user: String
    let model: AppModel
    let navigator: Navigator
    var body: some View {
        Button("Message") { navigator.message(user) }
        Button("Browse Files") { navigator.browse(user, model: model) }.disabled(!model.connection.isConnected)
        Button("Get Info") { navigator.showProfile(user) }
        if !model.users.contains(where: { $0.username == user }) {
            Button("Add to Users") { Task { await model.bookmark(user) } }
        }
        Button("Copy Username") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(user, forType: .string)
        }
    }
}
