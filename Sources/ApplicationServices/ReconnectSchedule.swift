import Foundation

public struct ReconnectSchedule: Sendable {
    public private(set) var attempt = 0
    public private(set) var deadline: Date?
    public init() {}
    @discardableResult public mutating func schedule(at now: Date) -> TimeInterval {
        let delays: [TimeInterval] = [5, 15, 30, 60, 120]
        let delay = delays[min(attempt, delays.count - 1)]
        attempt = min(attempt + 1, delays.count); deadline = now.addingTimeInterval(delay)
        return delay
    }
    public mutating func cancel(reset: Bool) { deadline = nil; if reset { attempt = 0 } }
    public func remaining(at now: Date) -> Int? { deadline.map { max(0, Int(ceil($0.timeIntervalSince(now)))) } }
}

public struct ReconnectClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.now = now; self.sleep = sleep
    }
    public static let live = Self(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
}
