import SwiftUI
import AppKit
import ArpeggioServices

@main
struct ArpeggioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var bootstrap = Bootstrap()

    init() {
        do {
            let directory = ProcessInfo.processInfo.environment["ARPEGGIO_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let model = try AppModel(dataDirectory: directory)
            model.playback.remoteStop = model.remoteStopHandler()
            model.playback.remoteCommands = RemoteCommandRouter(bridge: SystemRemoteCommandBridge())
            _model = State(initialValue: model)
        }
        catch { _startupError = State(initialValue: error.localizedDescription) }
    }

    var body: some Scene {
        Window("Arpeggio", id: "main") {
            if let model {
                RootView(model: model, bootstrap: bootstrap)
                    .task { delegate.model = model }
            } else {
                StartupFailureView(message: startupError ?? "Storage is unavailable.")
            }
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .commands { ArpeggioCommands(model: model) }

        MenuBarExtra(isInserted: Binding(get: { model?.menuBarExtraVisible ?? false }, set: { value in
            guard let model, value != model.menuBarExtraVisible else { return }
            model.settings.menuBarIcon = value
            Task { await model.saveSettings() }
        })) {
            if let model {
                MenuBarPanel(model: model)
                    .task { delegate.model = model }
            }
        } label: {
            if let model { MenuBarLabel(model: model, bootstrap: bootstrap) } else { Image(nsImage: MenuBarGlyph.image(presence: .offline, uploading: false)) }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let model {
                SettingsView(model: model)
                    .preferredColorScheme(model.settings.appearance == "light" ? .light : model.settings.appearance == "dark" ? .dark : nil)
            } else {
                StartupFailureView(message: startupError ?? "Storage is unavailable.")
            }
        }

        Window("Arpeggio Help", id: "help") { HelpView() }
            .defaultSize(width: 560, height: 640)
    }
}

/// Starts the shared model exactly once, whether the window or the menu bar icon appears first.
/// Every caller waits until stored state is loaded; signing in continues in the background.
@MainActor
final class Bootstrap {
    private var loading: Task<Void, Never>?
    func start(_ model: AppModel) async {
        if loading == nil {
            loading = Task {
                await model.start()
                Task { await model.connectAtLaunch() }
            }
        }
        await loading?.value
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct StartupFailureView: View {
    let message: String
    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Open Arpeggio", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Quit") { NSApp.terminate(nil) }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
