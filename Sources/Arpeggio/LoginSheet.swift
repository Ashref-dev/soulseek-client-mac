import SwiftUI
import ArpeggioServices
import SoulseekCore

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

    private var canConnect: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && consent && !working && !model.connection.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.connection.isConnected { connectedBody } else { form }
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear {
            username = model.settings.username
            if !username.isEmpty {
                password = model.savedPassword(); consent = !password.isEmpty
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
            Image(systemName: "music.quarternote.3")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.arpeggio)
            Text(model.connection.isConnected ? "Connected to Soulseek" : "Sign In to Soulseek")
                .font(.title3.weight(.semibold))
            Text("\(model.settings.server):\(String(model.settings.port))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 22).padding(.bottom, 12)
    }

    private var form: some View {
        Form {
            TextField("Username", text: $username)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit(connect)
            Toggle("Remember password in Keychain", isOn: $remember)
            Toggle(isOn: $consent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("I understand the risk")
                    Text("The Soulseek protocol sends your username and password to the server without encryption. Use a password unique to Soulseek.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let reason = model.connection.failureReason, attempted || !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .disabled(working || model.connection.isBusy)
        .scrollDisabled(true)
        .frame(height: 300)
    }

    private var connectedBody: some View {
        VStack(spacing: 10) {
            LabeledContent("Account", value: model.settings.username)
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
                Button("Disconnect", role: .destructive) {
                    Task { await model.disconnect() }
                }
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
        model.settings.username = username.trimmingCharacters(in: .whitespaces)
        working = true; attempted = true
        Task {
            await model.login(password: password, remember: remember)
            working = false
        }
    }
}
