import Foundation
import Testing
import Persistence
@testable import SoulseekCore
@testable import ArpeggioServices
@testable import Arpeggio

@Suite struct OnboardingTests {
    @Test func stepsRunInOrderWithPrivacyBeforeSignInAndNetworkAfterSharing() {
        typealias Step = OnboardingFlow.Step
        #expect(Step.allCases == [.welcome, .privacy, .account, .share, .network, .downloads])
        var visited: [Step] = [.welcome]
        while let next = OnboardingFlow.next(visited.last!) { visited.append(next) }
        #expect(visited == Step.allCases)
        #expect(OnboardingFlow.previous(.welcome) == nil)
        #expect(OnboardingFlow.next(.downloads) == nil)
        #expect(OnboardingFlow.previous(.account) == .privacy)
    }

    @Test func continueAndSkipFollowSignInAndSharingChoices() {
        #expect(!OnboardingFlow.canContinue(.account, connected: false, sharedFolders: 0))
        #expect(OnboardingFlow.canContinue(.account, connected: true, sharedFolders: 0))
        #expect(OnboardingFlow.skipTitle(.account, connected: false, sharedFolders: 0) == "Skip for Now")
        #expect(OnboardingFlow.skipTitle(.account, connected: true, sharedFolders: 0) == nil)
        #expect(!OnboardingFlow.canContinue(.share, connected: true, sharedFolders: 0))
        #expect(OnboardingFlow.canContinue(.share, connected: false, sharedFolders: 2))
        #expect(OnboardingFlow.skipTitle(.share, connected: true, sharedFolders: 0) == "Not Now")
        for step in [OnboardingFlow.Step.welcome, .privacy, .network, .downloads] {
            #expect(OnboardingFlow.canContinue(step, connected: false, sharedFolders: 0))
            #expect(OnboardingFlow.skipTitle(step, connected: false, sharedFolders: 0) == nil)
        }
    }

    @Test func privacyCoversUsernameAddressSharesTrustedFoldersAndPassword() {
        let text = OnboardingContent.privacy.map { "\($0.title) \($0.detail)" }.joined(separator: "\n").lowercased()
        for topic in ["username", "ip address", "shared folders", "trusted", "password", "without encryption", "keychain"] {
            #expect(text.contains(topic), "missing \(topic)")
        }
        for claim in ["password is encrypted", "encrypted password", "securely encrypted", "encrypts your password"] {
            #expect(!text.contains(claim))
        }
        #expect(!text.contains("\u{2014}")); #expect(!text.contains("\u{2013}"))
    }

    @Test func freshProfilesUse61147AndSavedPortsAreKept() throws {
        #expect(AppSettings().listeningPort == 61147)
        #expect(OnboardingContent.portSummary(saved: 61147, freshDefault: 61147).contains("default for new profiles"))
        let saved = OnboardingContent.portSummary(saved: 2234, freshDefault: 61147)
        #expect(saved.contains("2234"))
        #expect(saved.contains("never changes a saved port"))
        var legacy = AppSettings(); legacy.listeningPort = 2234
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.listeningPort == 2234)
        #expect(OnboardingContent.portSummary(saved: decoded.listeningPort).contains("2234"))
    }

    @Test func routerGuidanceNamesBothRouterMenusWithoutPromisingSuccess() {
        let lines = PortGuidance.instructions(port: 2234).joined(separator: " ")
        #expect(lines.contains("Port Forwarding")); #expect(lines.contains("Virtual Server"))
        #expect(lines.contains("TCP port 2234")); #expect(lines.contains("Soulseek Qt"))
        let note = OnboardingContent.routerNote.lowercased()
        #expect(note.contains("doesn’t prove"))
        for promise in ["guarantee", "always works", "always work", "will work", "works every time", "never fails",
                        "ensures", "makes you reachable", "100%"] {
            #expect(!note.contains(promise), "unconditional promise: \(promise)")
        }
        #expect(note.contains("if automatic mapping is unavailable"))
        #expect(note.contains("manual tcp rule"))
        for limit in ["firewall", "vpn", "upstream nat", "can still prevent incoming connections"] {
            #expect(note.contains(limit), "missing network limit: \(limit)")
        }
        #expect(!note.contains("\u{2014}")); #expect(!note.contains("\u{2013}"))
    }

    @Test func networkErrorsDeepLinkToTheNetworkTab() {
        let inUse = "TCP listening port 2234 is already in use. Only one app can listen on a port at a time. Quit the other client or review Settings › Network; Arpeggio will not change your port automatically."
        #expect(ErrorRoute.destination(for: inUse) == .network)
        #expect(ErrorRoute.destination(for: inUse)?.tab == .network)
        #expect(ErrorRoute.destination(for: "Choose a listening port between 1024 and 65535.") == .network)
        #expect(ErrorRoute.destination(for: "Wrong password.") == nil)
        #expect(SettingsDestination.port.tab == .network)
        #expect(SettingsDestination.recovery.tab == .advanced)
    }

    /// Routing reads core's own error text, so a wording change there must fail here rather than drop the link.
    @Test func coreListenerErrorsAllRouteToTheNetworkTab() async throws {
        for error in [ListeningPortError.inUse(61147), .unavailable(2234)] {
            let message = try #require(error.errorDescription)
            #expect(ErrorRoute.destination(for: message) == .network, "\(message)")
            #expect(!message.contains("Settings › Account"))
        }
        let session = SoulseekSession()
        do {
            try await session.startListener(port: 80)
            Issue.record("a privileged port should be rejected before binding")
        } catch {
            #expect(ErrorRoute.destination(for: error.localizedDescription) == .network, "\(error.localizedDescription)")
            #expect(!error.localizedDescription.contains("Settings › Account"))
        }
        await session.shutdown()
    }

    @Test func reconnectCountdownReadsNaturally() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ReconnectBanner.countdown(deadline: now.addingTimeInterval(14.2), now: now) == "Connection lost. Reconnecting in 15 s.")
        #expect(ReconnectBanner.countdown(deadline: now.addingTimeInterval(120), now: now) == "Connection lost. Reconnecting in 2 min 0 s.")
        #expect(ReconnectBanner.countdown(deadline: now.addingTimeInterval(-3), now: now) == "Connection lost. Reconnecting now…")
    }

    @Test func diagnosticScopesSeparateProblemsFromRoutineActivity() {
        let entries = [DiagnosticEntry(severity: .info, category: .peer, message: "routine"),
                       DiagnosticEntry(severity: .warning, category: .peer, message: "request failed"),
                       DiagnosticEntry(severity: .error, category: .server, message: "server failure")]
        #expect(DiagnosticScope.problems.filter(entries).map(\.message) == ["request failed", "server failure"])
        #expect(DiagnosticScope.all.filter(entries).count == 3)
    }

    @Test func localAddressFilterAcceptsOnlyPrivateIPv4() {
        for address in ["10.0.0.4", "172.16.5.1", "172.31.255.255", "192.168.1.20"] { #expect(LocalNetworkAddress.isPrivate(address)) }
        for address in ["8.8.8.8", "172.32.0.1", "192.169.0.1", "fe80::1", "not an address", "100.64.0.1"] {
            #expect(!LocalNetworkAddress.isPrivate(address))
        }
    }
}
