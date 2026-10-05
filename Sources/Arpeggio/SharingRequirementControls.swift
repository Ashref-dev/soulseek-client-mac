import SwiftUI
import ArpeggioServices
import Persistence

/// The require-sharing switch, its automatic message and the honest account of what it does. Settings > Sharing
/// and the welcome guide both show this one view, so they edit the same saved settings the same way.
struct SharingRequirementControls: View {
    static let messageLimit = 250
    static let explanation = "Arpeggio asks the server how many files each person shares. Only people it currently reports as sharing zero files are declined and sent your message, at most once an hour per person. If the count is unknown or doesn’t arrive in time, they’re allowed. It can’t tell whether a shared folder is empty or useful."

    @Bindable var model: AppModel

    private var required: Binding<Bool> {
        Binding(get: { model.settings.requiresSharing }, set: { model.settings.requireSharing = $0 })
    }

    private var message: Binding<String> {
        Binding(get: { model.settings.sharingMessageDraft },
                set: { model.settings.sharingRequiredMessage = String($0.prefix(Self.messageLimit)) })
    }

    private var isDefaultMessage: Bool { model.settings.sharingMessageDraft == AppSettings.defaultSharingMessage }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Require sharing to download from me")
                Text("People who share nothing can’t download from you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("Require sharing to download from me", isOn: required)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Automatic message")
                Spacer()
                if !isDefaultMessage {
                    Button("Use Default") { model.settings.sharingRequiredMessage = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Restore: \(AppSettings.defaultSharingMessage)")
                }
            }
            TextField("Automatic message", text: message, prompt: Text(AppSettings.defaultSharingMessage), axis: .vertical)
                .labelsHidden()
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
        }
        .disabled(!model.settings.requiresSharing)
        Text(Self.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
