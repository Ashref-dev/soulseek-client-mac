import Foundation
import Synchronization
import Testing
import Persistence
import ProtocolFixtures
@testable import ArpeggioServices

@Suite struct ExternalReachabilityParserTests {
    @Test func acceptsOnlyTheRequestedPortVerdict() {
        #expect(PortCheckResponse.parse(Data("<html><body><b>2234/tcp OPEN</b></body></html>".utf8), port: 2234) == .open)
        #expect(PortCheckResponse.parse(Data("Port: 2234/tcp CLOSED\n".utf8), port: 2234) == .closed)
        #expect(PortCheckResponse.parse(Data("<p>2234</p>/<i>tcp</i>&nbsp;open".utf8), port: 2234) == .open)
        #expect(PortCheckResponse.parse(Data("2234&#47;TCP\tClosed".utf8), port: 2234) == .closed)
        #expect(PortCheckResponse.parse(Data("2235/tcp CLOSED 2234/tcp OPEN".utf8), port: 2234) == .open)
    }

    @Test func malformedAmbiguousOrForeignAnswersAreUnavailableNotClosed() {
        let unavailable: [(String, ExternalPortCheck.Unavailable)] = [
            ("", .unrecognized),
            ("<html>Service temporarily unavailable</html>", .unrecognized),
            ("2235/tcp CLOSED", .unrecognized),
            ("12234/tcp OPEN", .unrecognized),
            ("22345/tcp CLOSED", .unrecognized),
            ("02234/tcp CLOSED", .unrecognized),
            ("2234/udp CLOSED", .unrecognized),
            ("2234/tcp OPENED", .unrecognized),
            ("2234/tcp CLOSEDX", .unrecognized),
            ("port 2234 is closed", .unrecognized),
            ("2234/tcp OPEN 2234/tcp CLOSED", .conflicting),
        ]
        for (body, reason) in unavailable {
            #expect(PortCheckResponse.parse(Data(body.utf8), port: 2234) == .unavailable(reason), "\(body)")
        }
        #expect(PortCheckResponse.parse(Data([0xFF, 0xFE, 0x00, 0x32]), port: 2234) == .unavailable(.unrecognized))
    }

    @Test func endpointIsTheOfficialHTTPSOriginWithOnlyThePortQuery() throws {
        let url = try #require(ExternalPortChecker.url(port: 2234))
        #expect(url.absoluteString == "https://www.slsknet.org/porttest.php?port=2234")
        #expect(ExternalPortChecker.url(port: 0) == nil)
        #expect(ExternalPortChecker.deadline == .seconds(15))
        #expect(ExternalPortChecker.responseLimit == 128 * 1024)
    }

    @Test func hardenedSessionStoresNoCookiesCredentialsOrCache() {
        let configuration = ExternalPortChecker.hardenedConfiguration()
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(configuration.timeoutIntervalForResource == 15)
        #expect(configuration.waitsForConnectivity == false)
    }

    @Test func redirectsAreRefused() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = try #require(URL(string: "https://www.slsknet.org/porttest.php?port=2234"))
        let task = session.dataTask(with: source)
        let response = try #require(HTTPURLResponse(url: source, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.invalid/"]))
        let next = await NoRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                  newRequest: URLRequest(url: try #require(URL(string: "https://example.invalid/"))))
        #expect(next == nil)
    }

    @Test func summariesStayHonestAboutScope() {
        let open = ExternalPortCheck(port: 2234, generation: 1, outcome: .open, checkedAt: Date()).summary
        #expect(open.contains("2234/TCP"))
        #expect(open.contains("does not prove uploads will succeed"))
        #expect(open.contains("other ports"))
        #expect(open.contains("VPN"))
        let unavailable = ExternalPortCheck(port: 2234, generation: 1, outcome: .unavailable(.timedOut), checkedAt: Date()).summary
        #expect(unavailable.contains("not a closed result"))
        for text in [open, unavailable, ExternalPortCheck(port: 2234, generation: 1).summary] {
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
        }
    }
}

@Suite struct ExternalReachabilityTransportTests {
    private func checker(deadline: Duration = .seconds(5), limit: Int = ExternalPortChecker.responseLimit) -> ExternalPortChecker {
        ExternalPortChecker(configuration: {
            let configuration = ExternalPortChecker.hardenedConfiguration()
            configuration.protocolClasses = [PortCheckMock.self]
            return configuration
        }, deadline: deadline, limit: limit)
    }

    @Test func openAndClosedPagesAreParsedWithoutCookiesOrCredentials() async {
        PortCheckMock.route(41001, .respond(200, Data("<html>41001/tcp OPEN</html>".utf8)))
        PortCheckMock.route(41002, .respond(200, Data("<html>41002/tcp CLOSED</html>".utf8)))
        #expect(await checker().check(port: 41001) == .open)
        #expect(await checker().check(port: 41002) == .closed)
        let request = PortCheckMock.requests(41001).first
        #expect(request?.url?.absoluteString == "https://www.slsknet.org/porttest.php?port=41001")
        #expect(request?.httpMethod == "GET")
        #expect(request?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.httpShouldHandleCookies == false)
    }

    @Test func nonSuccessRedirectOversizedAndFailedResponsesAreUnavailable() async {
        PortCheckMock.route(41010, .respond(500, Data("41010/tcp CLOSED".utf8)))
        PortCheckMock.route(41011, .redirect(to: "https://www.slsknet.org/porttest.php?port=41012"))
        PortCheckMock.route(41012, .respond(200, Data("41011/tcp OPEN 41012/tcp OPEN".utf8)))
        PortCheckMock.route(41013, .respond(200, Data(repeating: 0x41, count: 2048) + Data("41013/tcp CLOSED".utf8)))
        PortCheckMock.route(41014, .fail(.notConnectedToInternet))
        PortCheckMock.route(41015, .respond(200, Data("<html>maintenance</html>".utf8)))
        #expect(await checker().check(port: 41010) == .unavailable(.httpStatus))
        let redirected = await checker(deadline: .seconds(2)).check(port: 41011)
        #expect(redirected != .open && redirected != .closed)
        #expect(PortCheckMock.requests(41012).isEmpty)
        #expect(await checker(limit: 1024).check(port: 41013) == .unavailable(.oversized))
        #expect(await checker().check(port: 41014) == .unavailable(.network))
        #expect(await checker().check(port: 41015) == .unavailable(.unrecognized))
    }

    @Test(.timeLimit(.minutes(1))) func hangingCheckerIsBoundedByTheTotalDeadline() async {
        PortCheckMock.route(41020, .hang)
        let started = ContinuousClock.now
        #expect(await checker(deadline: .milliseconds(300)).check(port: 41020) == .unavailable(.timedOut))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1))) func cancellationEndsTheRequestAsUnavailable() async {
        PortCheckMock.route(41030, .hang)
        let checker = checker(deadline: .seconds(30))
        let task = Task { await checker.check(port: 41030) }
        await waitUntil { !PortCheckMock.requests(41030).isEmpty }
        let started = ContinuousClock.now
        task.cancel()
        #expect(await task.value == .unavailable(.cancelled))
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

@Suite struct ExternalReachabilityModelTests {
    @Test @MainActor func checkRequiresAConnectedListenerAndNeverRunsOffline() async throws {
        let fixture = try await ReachabilityFixture.make()
        let probes = ProbeRecorder()
        fixture.model.externalPortProbe = { port in probes.record(port); return .open }
        #expect(fixture.model.canCheckExternalPort == false)
        await fixture.model.checkExternalPort()
        #expect(probes.ports.isEmpty)
        #expect(fixture.model.externalPortCheck == nil)
        await fixture.close()
    }

    @Test @MainActor func resultIsTiedToThePortAndGenerationThatWereChecked() async throws {
        let fixture = try await ReachabilityFixture.make()
        let probes = ProbeRecorder()
        fixture.model.externalPortProbe = { port in probes.record(port); return .open }
        await fixture.model.login(password: "fixture-only", remember: false)
        #expect(fixture.model.connection == .connected)
        #expect(fixture.model.canCheckExternalPort)
        let port = fixture.model.settings.listeningPort
        await fixture.model.checkExternalPort()
        #expect(probes.ports == [port])
        let check = try #require(fixture.model.currentExternalPortCheck)
        #expect(check.port == port && check.outcome == .open && check.checkedAt != nil)
        #expect(check.generation == fixture.model.activeSessionGeneration)

        fixture.model.settings.listeningPort = try unusedPort()
        #expect(fixture.model.currentExternalPortCheck == nil)
        await fixture.model.checkExternalPort()
        #expect(probes.ports == [port])
        #expect(fixture.model.currentExternalPortCheck?.outcome == .unavailable(.notListening))

        fixture.model.settings.listeningPort = port
        await fixture.model.disconnect()
        #expect(fixture.model.currentExternalPortCheck == nil)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func disconnectDuringCheckDiscardsTheLateResult() async throws {
        let fixture = try await ReachabilityFixture.make()
        let gate = ProbeGate()
        fixture.model.externalPortProbe = { _ in await gate.wait(); return .open }
        await fixture.model.login(password: "fixture-only", remember: false)
        let work = Task { await fixture.model.checkExternalPort() }
        await waitUntil { await gate.entered }
        #expect(fixture.model.currentExternalPortCheck?.isChecking == true)
        #expect(fixture.model.canCheckExternalPort == false)
        await fixture.model.disconnect()
        await gate.release(); await work.value
        #expect(fixture.model.externalPortCheck == nil)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func newerCheckSupersedesAnOlderOne() async throws {
        let fixture = try await ReachabilityFixture.make()
        let gate = ProbeGate(); let calls = ProbeRecorder()
        fixture.model.externalPortProbe = { port in
            calls.record(port)
            if calls.ports.count == 1 { await gate.wait(); return .closed }
            return .open
        }
        await fixture.model.login(password: "fixture-only", remember: false)
        let first = Task { await fixture.model.checkExternalPort() }
        await waitUntil { await gate.entered }
        fixture.model.cancelExternalPortCheck()
        #expect(fixture.model.externalPortCheck == nil)
        await fixture.model.checkExternalPort()
        await gate.release(); await first.value
        #expect(fixture.model.currentExternalPortCheck?.outcome == .open)
        await fixture.close()
    }
}

@MainActor private struct ReachabilityFixture {
    let root: URL
    let model: AppModel
    let server: MockSoulseekServer
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = try await MockSoulseekServer.start()
        let model = try AppModel(dataDirectory: root)
        var settings = AppSettings()
        settings.username = "reach-fixture"; settings.server = "127.0.0.1"
        settings.port = try await server.port(); settings.listeningPort = try unusedPort()
        settings.notifications = false; settings.checkForUpdates = false; settings.portMapping = false
        settings.downloadDirectory = root.appendingPathComponent("downloads").path
        try await model.database.put(settings, collection: "settings", id: "main")
        await model.start()
        model.credentials = CredentialWrites(backend: .init(save: { _, _ in }, delete: { _ in }))
        return Self(root: root, model: model, server: server)
    }
    func close() async {
        await model.shutdown(); await server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ProbeRecorder: Sendable {
    private let storage = Mutex<[UInt16]>([])
    func record(_ port: UInt16) { storage.withLock { $0.append(port) } }
    var ports: [UInt16] { storage.withLock { $0 } }
}

private actor ProbeGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; entered = true }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<400 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Serves canned checker responses by requested port so no test touches the real internet.
final class PortCheckMock: URLProtocol, @unchecked Sendable {
    enum Route: Sendable {
        case respond(Int, Data)
        case redirect(to: String)
        case fail(URLError.Code)
        case hang
    }
    private static let routes = Mutex<[String: Route]>([:])
    private static let seen = Mutex<[String: [URLRequest]]>([:])

    static func route(_ port: UInt16, _ route: Route) { routes.withLock { $0[String(port)] = route } }
    static func requests(_ port: UInt16) -> [URLRequest] { seen.withLock { $0[String(port)] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let port = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "port" })?.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        Self.seen.withLock { $0[port, default: []].append(request) }
        switch Self.routes.withLock({ $0[port] }) ?? .respond(404, Data()) {
        case .respond(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let location):
            let target = URL(string: location)!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}
}
