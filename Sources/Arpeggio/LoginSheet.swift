import SwiftUI
import ArpeggioServices
import SoulseekCore
import Persistence

struct LoginSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @State private var consent = false
    @State private var working = false
    @State private var attempted = false
    @State private var passwordAccount: String?
    @State private var passwordEditRevision: UInt64 = 0
    @State private var dismissedFailure: String?

    private var canConnect: Bool {
        !username.isEmpty && usernameIssue == nil && !password.isEmpty && consent && !working && !model.connection.isBusy
    }

    /// Client-side hint only; the session layer remains the authority on what the server accepts.
    private var usernameIssue: String? {
        guard !username.isEmpty else { return nil }
        if username.first?.isWhitespace == true || username.last?.isWhitespace == true { return "Remove spaces at the start or end of the username." }
        if username.count > 30 { return "Usernames can be at most 30 characters." }
        if !username.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) { return "Use letters, digits, spaces and standard ASCII symbols only." }
        return nil
    }

    private var visibleFailure: String? {
        guard let reason = model.connection.failureReason, !reason.isEmpty, reason != dismissedFailure else { return nil }
        return reason
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.connection.isConnected { connectedBody } else { form }
            Divider()
            footer
        }
        .frame(width: 460)
        .tint(.arpeggio)
        .task {
            username = model.settings.username
            if !username.isEmpty {
                let initialUsername = username
                let initialRevision = passwordEditRevision
                let saved = await model.savedPassword()
                guard !Task.isCancelled, username == initialUsername, passwordEditRevision == initialRevision else { return }
                password = saved; consent = !password.isEmpty
                passwordAccount = password.isEmpty ? nil : username
            }
        }
        .onChange(of: username) { _, value in
            if let account = passwordAccount, value != account { password = ""; passwordAccount = nil }
        }
        .onChange(of: model.connection) { _, state in
            if attempted, state.isConnected { dismiss() }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            ArpeggioLogo()
                .frame(width: 40, height: 40)
                .foregroundStyle(Color.arpeggio)
            Text(model.connection.isConnected ? "Connected to \(model.settings.isSoulseekServer ? "Soulseek" : model.settings.targetDescription)" : "Sign In to Soulseek")
                .font(.title3.weight(.semibold))
            HStack(spacing: 4) {
                if !model.settings.isLocalServer {
                    Text(model.settings.targetDescription).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                }
                ServerTargetText(settings: model.settings)
            }
            .font(.caption)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Server: \(model.settings.targetDescription), \(model.settings.serverEndpoint)")
        }
        .padding(.top, 22).padding(.bottom, 12).padding(.horizontal, 20)
    }

    private var form: some View {
        Form {
            if !model.settings.isSoulseekServer { targetSection }
            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: Binding(get: { password }, set: { password = $0; passwordEditRevision &+= 1 }))
                    .textContentType(.password)
                    .onSubmit(connect)
            } footer: {
                Group {
                    if let usernameIssue {
                        Label(usernameIssue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    } else {
                        Text("New to Soulseek? Pick a username (up to 30 ASCII characters) and a password. If the name is unused, the server registers it on first sign-in. There’s no way to check in advance: a name that’s already taken is rejected as a wrong password.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Remember password in Keychain", isOn: $remember)
                Toggle(isOn: $consent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("I understand the risk")
                        Text("The Soulseek protocol sends your username and password to the server without encryption. Use a password unique to Soulseek.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let visibleFailure {
                Label(visibleFailure, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .disabled(working || model.connection.isBusy)
        .frame(height: model.settings.isSoulseekServer ? 380 : 450)
    }

    /// Shown only when the configured server isn't the public Soulseek server; never changes it silently.
    private var targetSection: some View {
        let local = model.settings.isLocalServer
        return Section {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: local ? "exclamationmark.triangle.fill" : "server.rack")
                    .foregroundStyle(local ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(local ? "Local test server, not Soulseek" : "Custom server")
                        .font(.callout.weight(.medium))
                    Text(local
                         ? "\(model.settings.serverEndpoint) is a developer fixture on this Mac. Its accounts, users and files aren’t on the Soulseek network."
                         : "Signing in to \(model.settings.serverEndpoint) instead of \(AppSettings.soulseekEndpoint).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Use Soulseek Server") {
                    dismissedFailure = model.connection.failureReason
                    Task { await model.useSoulseekServer() }
                }
                .fixedSize()
                .help("Switch to \(AppSettings.soulseekEndpoint). Your username and saved password are kept.")
            }
        }
    }

    private var connectedBody: some View {
        VStack(spacing: 10) {
            LabeledContent("Account", value: model.activeAccount.isEmpty ? model.settings.username : model.activeAccount)
            LabeledContent("Server") { ServerTargetText(settings: model.settings) }
            LabeledContent("Listening port", value: String(model.settings.listeningPort))
            LabeledContent("Sharing", value: "\(model.sharedCount.formatted()) files · \(Format.bytes(model.sharedBytes))")
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }

    private var footer: some View {
        HStack {
            if working || model.connection.isBusy {
                ProgressView().controlSize(.small)
                Text(model.connection.label).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.connection.isConnected ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if model.connection.isConnected {
                Button("Sign Out", role: .destructive) {
                    Task { await model.signOut(); dismiss() }
                }
                .help("Disconnect and forget the saved password")
                Button("Disconnect") {
                    Task { await model.disconnect() }
                }
                .help("Go offline; Arpeggio still signs in automatically next time")
            } else if model.connection.isBusy {
                Button("Stop") { Task { await model.disconnect() } }
            } else {
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding(16)
    }

    private func connect() {
        guard canConnect else { return }
        model.settings.username = username
        working = true; attempted = true; dismissedFailure = nil
        Task {
            await model.login(password: password, remember: remember)
            working = false
        }
    }
}
