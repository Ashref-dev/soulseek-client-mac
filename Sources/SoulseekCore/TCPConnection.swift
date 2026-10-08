import Foundation
import Network

public final class TCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "tn.ashref.arpeggio.tcp")
    public init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw ProtocolError.invalid("Invalid port.") }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }
    public init(incoming: NWConnection) { connection = incoming }
    public var remoteHost: String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        switch host {
        case .ipv4(let address): return address.debugDescription
        case .ipv6(let address): return address.debugDescription
        default: return nil
        }
    }
    public func start() async throws {
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(15)); self.cancel() } catch { }
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .waiting(let error):
                        connection.stateUpdateHandler = nil; connection.cancel()
                        continuation.resume(throwing: error)
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: ProtocolError.disconnected)
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: { self.cancel() }
    }
    public func send(_ data: Data, lease: SendLease? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let send = { [connection] in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
            do { if let lease { try lease.perform(send) } else { send() } }
            catch { continuation.resume(throwing: error) }
        }
    }
    public func receive(maximum: Int = 65_536, timeout seconds: Int? = nil) async throws -> Data {
        let timeout = seconds.map { seconds in
            Task { do { try await Task.sleep(for: .seconds(seconds)); self.cancel() } catch { } }
        }
        defer { timeout?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if let error { continuation.resume(throwing: error) }
                    else if complete { continuation.resume(throwing: ProtocolError.disconnected) }
                    else { continuation.resume(returning: Data()) }
                }
            }
        } onCancel: { self.cancel() }
    }
    public func cancel() { connection.cancel() }
}

public actor FramedConnection {
    public nonisolated let socket: TCPConnection
    private var buffer = Data()
    public init(_ socket: TCPConnection) { self.socket = socket }
    public func send(code: UInt32, payload: Data = Data(), narrow: Bool = false, lease: SendLease? = nil) async throws {
        try await socket.send(WireWriter.frame(code: code, payload: payload, narrow: narrow), lease: lease)
    }
    public func read(narrow: Bool = false, timeout: Int? = nil, peer: Bool = false) async throws -> (UInt32, Data) {
        try await read(narrow: narrow, timeout: timeout, peer: peer, budget: nil, admit: nil)
    }
    func read(narrow: Bool = false, timeout: Int? = nil, peer: Bool = false,
              budget: ReceiveBudget?, admit: (@Sendable (UInt32) async throws -> Void)?) async throws -> (UInt32, Data) {
        let header = try await exact(4, timeout: timeout)
        var reader = WireReader(header)
        let length = try reader.uint()
        let width = narrow ? 1 : 4
        guard length >= width, length <= 256 * 1024 * 1024 else { throw ProtocolError.oversized }
        var codeReader = WireReader(try await exact(width, timeout: timeout))
        let code = try narrow ? UInt32(codeReader.byte()) : codeReader.uint()
        let payloadLength = Int(length) - width
        if !peer, !narrow, payloadLength > 32 * 1024 * 1024 { throw ProtocolError.oversized }
        if narrow, payloadLength > 8192 { throw ProtocolError.oversized }
        if peer, code == 9, payloadLength > 16 * 1024 * 1024 { throw ProtocolError.oversized }
        if peer, code == 16, payloadLength > 8 * 1024 * 1024 + 32_768 { throw ProtocolError.oversized }
        if peer, ![5, 9, 16, 37].contains(code), payloadLength > 8192 { throw ProtocolError.oversized }
        try await admit?(code)
        try budget?.reserve(payloadLength)
        defer { budget?.release(payloadLength) }
        let deadline = peer ? Task {
            do { try await Task.sleep(for: .seconds(30)); socket.cancel() } catch { }
        } : nil
        defer { deadline?.cancel() }
        return (code, try await exact(payloadLength, timeout: timeout))
    }
    public func exact(_ count: Int, timeout: Int? = nil) async throws -> Data {
        guard count >= 0, count <= 256 * 1024 * 1024 else { throw ProtocolError.oversized }
        while buffer.count < count { buffer.append(try await socket.receive(maximum: min(65_536, count - buffer.count), timeout: timeout)) }
        if buffer.count == count { defer { buffer = Data() }; return buffer }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count); return result
    }
}
