import SwiftUI
import AppKit
import ArpeggioServices
import Persistence

/// Settings > Network: the listening port, router mapping, local and external checks and router guidance
/// in one place. Saved ports are never changed automatically; edits apply the next time you connect.
struct NetworkSettingsView: View {
    @Bindable var model: AppModel
    @State private var confirmExternalCheck = false

    var body: some View {
        Form {
            Section {
                TextField("Listening port", value: $model.settings.listeningPort, format: .number.grouping(.never))
                    .help("Other people connect to this TCP port.")
                LabeledContent("Status") { listenerStatus }
            } header: {
                Text("Incoming Connections")
            } footer: {
                Text("Other Soulseek users connect to this TCP port. Changes apply the next time you connect, and Arpeggio never changes a saved port on its own.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open the port on my router automatically", isOn: Binding(get: { model.settings.mapsPorts }, set: { model.settings.portMapping = $0 }))
                Toggle("Use NAT-PMP", isOn: Binding(get: { model.settings.usesNATPMP }, set: { model.settings.natPMPEnabled = $0 })).disabled(!model.settings.mapsPorts)
                Toggle("Use UPnP", isOn: Binding(get: { model.settings.usesUPnP }, set: { model.settings.upnpEnabled = $0 })).disabled(!model.settings.mapsPorts)
                LabeledContent("Router") { portStatus }
            } header: {
                Text("Router Mapping")
            } footer: {
                Text("A router acknowledgment means the router accepted the request. It does not prove people can reach you from the internet.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Check Ports") { Task { await model.checkListeningPort() } }
                        .help("Tests the local TCP listener on this Mac only")
                    Button("Check External Reachability…") { confirmExternalCheck = true }
                        .disabled(!model.canCheckExternalPort)
                        .help(model.connection.isConnected
                              ? "Ask the Soulseek port checker whether \(String(model.settings.listeningPort))/TCP is reachable from the internet"
                              : "Connect first. The check tests the port Arpeggio is listening on.")
                    if model.currentExternalPortCheck?.isChecking == true {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelExternalPortCheck() }.controlSize(.small)
                    }
                }
                if let check = model.portCheck {
                    Label { Text(check).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "desktopcomputer") }
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let external = model.currentExternalPortCheck { ExternalPortCheckStatus(check: external) }
            } header: {
                Text("Checks")
            } footer: {
                Text("Check Ports tests only this Mac. Check External Reachability contacts the Soulseek port checker only when you confirm it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(PortGuidance.instructions(port: model.settings.listeningPort).enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(Color.arpeggio)
                            .frame(width: 16, height: 16)
                            .background(Color.arpeggio.opacity(0.12), in: .circle)
                            .accessibilityHidden(true)
                        Text(line).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let address = LocalNetworkAddress.current {
                    LabeledContent("This Mac on your network") {
                        Text(address).monospacedDigit().textSelection(.enabled)
                    }
                    .help("Use this address as the target of the router rule")
                }
            } header: {
                Text("Forward the Port Manually")
            } footer: {
                Text("Rule type TCP, external and internal port \(String(model.settings.listeningPort)). Router menus call this Port Forwarding or Virtual Server.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .confirmationDialog("Check whether \(String(model.settings.listeningPort))/TCP is reachable from the internet?", isPresented: $confirmExternalCheck) {
            Button("Check Port \(String(model.settings.listeningPort))") { Task { await model.checkExternalPort() } }
                .disabled(!model.canCheckExternalPort)
        } message: {
            Text("Contacts the Soulseek port checker (\(ExternalPortChecker.host)) using your public IP address. No credentials are sent. The checker tests the address your request comes from, which a VPN can change.")
        }
    }

    @ViewBuilder private var listenerStatus: some View {
        let status = ListenerStatus.make(connected: model.connection.isConnected,
                                         busyLabel: model.connection.isBusy ? model.connection.label : nil,
                                         activePort: model.activeListeningPort, configuredPort: model.settings.listeningPort)
        VStack(alignment: .trailing, spacing: 2) {
            switch status.tone {
            case .active: Label(status.title, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .neutral: Text(status.title).foregroundStyle(.secondary)
            }
            if let detail = status.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var portStatus: some View {
        switch model.portMapping {
        case .idle: Text(model.connection.isConnected ? "Not mapped" : "Maps when you connect").foregroundStyle(.secondary)
        case .disabled: Text("Off").foregroundStyle(.secondary)
        case .mapping: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Asking the router…") }.foregroundStyle(.secondary)
        case .mapped(let method, let port, let address):
            Label("Router acknowledged \(method) mapping for \(port)\(address.map { " · \($0)" } ?? ""). External reachability unverified.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unavailable(let reason): Text(reason).foregroundStyle(.orange)
        }
    }
}

struct ListenerStatus: Equatable {
    enum Tone: Equatable { case active, neutral }
    let title: String
    let detail: String?
    let tone: Tone

    /// `activePort` must be the port the current session actually bound, never the edited setting.
    static func make(connected: Bool, busyLabel: String?, activePort: UInt16?, configuredPort: UInt16) -> ListenerStatus {
        guard connected else {
            return ListenerStatus(title: busyLabel ?? "Starts when you connect", detail: nil, tone: .neutral)
        }
        guard let activePort else { return ListenerStatus(title: "Connected to Soulseek", detail: nil, tone: .active) }
        let pending = activePort == configuredPort ? nil : "Port \(configuredPort) applies the next time you connect."
        return ListenerStatus(title: "Listening on \(activePort)", detail: pending, tone: .active)
    }
}

/// The Mac's private IPv4 address on the local network, for the router rule. Shown only in Settings, never reported.
enum LocalNetworkAddress {
    static var current: String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(name: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isPrivate(text) { candidates.append((String(cString: entry.pointee.ifa_name), text)) }
        }
        return candidates.first { $0.name.hasPrefix("en") }?.address ?? candidates.first?.address
    }

    static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }
}

struct ExternalPortCheckStatus: View {
    let check: ExternalPortCheck

    var body: some View {
        Label {
            Text(check.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch check.outcome {
        case nil: "network"
        case .open: "checkmark.circle.fill"
        case .closed: "xmark.circle.fill"
        case .unavailable: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch check.outcome {
        case .open: .green
        case .closed: .orange
        default: .secondary
        }
    }
}
