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
            _model = State(initialValue: try AppModel(dataDirectory: directory))
        }
        catch { _startupError = State(initialValue: error.localizedDescription) }
    }

    var body: some Scene {
        WindowGroup("Arpeggio", id: "main") {
            if let model {
                RootView(model: model, bootstrap: bootstrap)
                    .task { delegate.model = model }
            } else {
                StartupFailureView(message: startupError ?? "Storage is unavailable.")
            }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands { ArpeggioCommands(model: model) }

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

/// Starts the shared model exactly once, regardless of how many windows are opened.
@MainActor
final class Bootstrap {
    private var started = false
    func start(_ model: AppModel) async {
        guard !started else { return }
        started = true
        await model.start()
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
