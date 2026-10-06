import Foundation

/// One user-initiated request to the Soulseek port checker for the listener owned by one session generation.
public struct ExternalPortCheck: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case open, closed
        case unavailable(Unavailable)
    }
    public enum Unavailable: Equatable, Sendable {
        case notListening, timedOut, network, httpStatus, oversized, unrecognized, conflicting, cancelled
    }

    public let port: UInt16
    public let generation: UInt64
    public var outcome: Outcome?
    public var checkedAt: Date?

    public init(port: UInt16, generation: UInt64, outcome: Outcome? = nil, checkedAt: Date? = nil) {
        self.port = port; self.generation = generation; self.outcome = outcome; self.checkedAt = checkedAt
    }

    public var isChecking: Bool { outcome == nil }

    public var summary: String {
        let time = checkedAt.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        switch outcome {
        case nil:
            return "Asking the Soulseek port checker about \(port)/TCP…"
        case .open:
            return "The Soulseek port checker reached \(port)/TCP\(time). This shows TCP reachability from the checker only. It does not prove uploads will succeed, does not test other ports, and may not match the route other people take, for example with a VPN."
        case .closed:
            return "The Soulseek port checker couldn’t reach \(port)/TCP\(time). Check port forwarding on your router, the macOS firewall and any VPN. The checker tests the public address your request came from, which a VPN can change."
        case .unavailable(let reason):
            return "External check unavailable\(time): \(reason.explanation) This is not a closed result."
        }
    }
}

extension ExternalPortCheck.Unavailable {
    var explanation: String {
        switch self {
        case .notListening: "Arpeggio isn’t listening on this port for the current connection. Reconnect to apply port changes, then check again."
        case .timedOut: "the checker didn’t answer within 15 seconds."
        case .network: "the checker couldn’t be contacted."
        case .httpStatus: "the checker returned an unexpected response."
        case .oversized: "the checker’s response was too large."
        case .unrecognized: "the checker’s response didn’t include a result for this port."
        case .conflicting: "the checker’s response was contradictory."
        case .cancelled: "the check was cancelled."
        }
    }
}

/// Fetches https://www.slsknet.org/porttest.php?port=<PORT>, the checker Nicotine+ uses. The request
/// carries no cookies, credentials or cache, refuses redirects, and is bounded in time and size.
public struct ExternalPortChecker: Sendable {
    public static let host = "www.slsknet.org"
    public static let responseLimit = 128 * 1024
    public static let deadline: Duration = .seconds(15)

    let makeConfiguration: @Sendable () -> URLSessionConfiguration
    let deadline: Duration
    let limit: Int

    public init() { self.init(configuration: { Self.hardenedConfiguration() }) }
    init(configuration: @escaping @Sendable () -> URLSessionConfiguration, deadline: Duration = Self.deadline, limit: Int = Self.responseLimit) {
        makeConfiguration = configuration; self.deadline = deadline; self.limit = limit
    }

    static func url(port: UInt16) -> URL? {
        guard port > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = "/porttest.php"
        components.queryItems = [URLQueryItem(name: "port", value: String(port))]
        return components.url
    }

    static func hardenedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    public func check(port: UInt16) async -> ExternalPortCheck.Outcome {
        guard let url = Self.url(port: port) else { return .unavailable(.notListening) }
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        let session = URLSession(configuration: makeConfiguration(), delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let limit = limit, deadline = deadline
        let outcome = await withTaskGroup(of: ExternalPortCheck.Outcome?.self) { group in
            group.addTask { await Self.fetch(url, port: port, session: session, limit: limit) }
            group.addTask {
                do { try await Task.sleep(for: deadline) } catch { return nil }
                session.invalidateAndCancel()
                return .unavailable(.timedOut)
            }
            let first = await group.next() ?? nil
            group.cancelAll(); session.invalidateAndCancel()
            return first
        }
        if Task.isCancelled { return .unavailable(.cancelled) }
        return outcome ?? .unavailable(.cancelled)
    }

    static func fetch(_ url: URL, port: UInt16, session: URLSession, limit: Int) async -> ExternalPortCheck.Outcome {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("text/html, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return .unavailable(.httpStatus) }
            guard http.url?.scheme?.lowercased() == "https", http.url?.host?.lowercased() == host else { return .unavailable(.httpStatus) }
            if http.expectedContentLength > Int64(limit) { return .unavailable(.oversized) }
            var data = Data(); data.reserveCapacity(min(limit, 16 * 1024))
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return .unavailable(.oversized) }
            }
            return PortCheckResponse.parse(data, port: port)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: return .unavailable(.cancelled)
            case .timedOut: return .unavailable(.timedOut)
            default: return .unavailable(.network)
            }
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch {
            return .unavailable(.network)
        }
    }
}

/// Reads only "<requested port>/tcp OPEN|CLOSED" from the checker's HTML. Anything missing, contradictory or
/// about another port is unavailable, never CLOSED.
enum PortCheckResponse {
    private static let verdict = try! NSRegularExpression(pattern: "(?<![0-9])([0-9]{1,5}) ?/ ?tcp (open|closed)(?![a-z0-9])", options: [.caseInsensitive])

    static func parse(_ data: Data, port: UInt16) -> ExternalPortCheck.Outcome {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return .unavailable(.unrecognized) }
        let text = normalize(raw)
        let range = NSRange(text.startIndex..., in: text)
        var states = Set<String>()
        for match in verdict.matches(in: text, range: range) {
            guard let number = Range(match.range(at: 1), in: text), let state = Range(match.range(at: 2), in: text),
                  text[number] == String(port) else { continue }
            states.insert(text[state].uppercased())
        }
        switch states {
        case ["OPEN"]: return .open
        case ["CLOSED"]: return .closed
        case []: return .unavailable(.unrecognized)
        default: return .unavailable(.conflicting)
        }
    }

    static func normalize(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&#160;": " ", "&#xa0;": " ", "&#47;": "/", "&#x2f;": "/", "&sol;": "/"] {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
