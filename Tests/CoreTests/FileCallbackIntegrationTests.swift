import Foundation
import Testing
@testable import SoulseekCore
import ProtocolFixtures

// Wire/session coverage only: no AppModel, persistence, indexing, or real shared files.
@MainActor
private final class CallbackPeer {
    let session = SoulseekSession()
    let user: String
    let file: SharedFile
    let servesFile: Bool
    var results: [SearchResult] = []
    var library: RemoteLibrary?
    var description: String?
    var incomingFile: (String, FramedConnection)?
    var failures: [String] = []
    var pump: Task<Void, Never>?

    init(user: String, file: SharedFile, servesFile: Bool) {
        self.user = user; self.file = file; self.servesFile = servesFile
    }

    func start() {
        pump = Task {
            for await envelope in session.events {
                do {
                    switch envelope.event {
                    case .searchRequest(let requester, let token, let query) where servesFile:
                        #expect(query == "Jóga")
                        let reply = try PeerCodec.searchReply(user: user, token: token, files: [file], slots: true, speed: 123_456, queue: 0)
                        try await session.peerSend(user: requester, code: 9, payload: reply)
                    case .peerMessage(let requester, 4, _) where servesFile:
                        let reply = try PeerCodec.libraryReply(["Synthetic\\Björk": [file]])
                        try await session.peerSend(user: requester, code: 5, payload: reply)
                    case .peerMessage(let requester, 15, _) where servesFile:
                        var reply = WireWriter(); reply.string("Synthetic uploader metadata")
                        reply.byte(0); reply.uint(1); reply.uint(0); reply.byte(1)
                        try await session.peerSend(user: requester, code: 16, payload: reply.data)
                    case .search(_, let received): results = received
                    case .library(let received): library = received
                    case .userInfo(_, let received, _): description = received
                    case .fileConnection(let requester, let connection):
                        #expect(incomingFile == nil)
                        incomingFile = (requester, connection)
                    default: break
                    }
                } catch { failures.append(error.localizedDescription) }
            }
        }
    }

    func stop() async {
        await session.shutdown()
        pump?.cancel(); await pump?.value
    }
}

@MainActor
private func awaitCallbackEvidence(_ label: String, _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw ProtocolError.invalid("\(label) timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func syntheticDirectUploadSearchBrowseMetadata() async throws {
    try await exerciseFileRoute(forceDownloaderIndirect: false)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func syntheticForcedFCallbackUploadSearchBrowseMetadata() async throws {
    try await exerciseFileRoute(forceDownloaderIndirect: true)
}

@MainActor
private func exerciseFileRoute(forceDownloaderIndirect: Bool) async throws {
    let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
    let file = SharedFile(path: "Synthetic\\Björk\\01 Jóga.flac", size: UInt64(bytes.count), attributes: [0: 1024, 1: 123])
    let uploader = CallbackPeer(user: "synthetic-uploader", file: file, servesFile: true)
    let downloader = CallbackPeer(user: "synthetic-downloader", file: file, servesFile: false)
    let server = try await MockSoulseekServer.start(forceIndirect: forceDownloaderIndirect ? [downloader.user] : [])
    uploader.start(); downloader.start()
    do {
        try await exerciseConnectedRoute(server: server, uploader: uploader, downloader: downloader, bytes: bytes, forced: forceDownloaderIndirect)
    } catch {
        await uploader.stop(); await downloader.stop(); await server.stop()
        throw error
    }
    await uploader.stop(); await downloader.stop(); await server.stop()
}

@MainActor
private func exerciseConnectedRoute(server: MockSoulseekServer, uploader: CallbackPeer, downloader: CallbackPeer, bytes: Data, forced: Bool) async throws {
    let serverPort = try await server.port()
    let uploaderPort = try unusedPort()
    try await uploader.session.connect(host: "127.0.0.1", port: serverPort, user: uploader.user, password: "fixture-only", listeningPort: uploaderPort)
    let downloaderPort = try unusedPort()
    try await downloader.session.connect(host: "127.0.0.1", port: serverPort, user: downloader.user, password: "fixture-only", listeningPort: downloaderPort)
    try await awaitCallbackEvidence("both listeners advertised") {
        let trace = await server.trace
        return trace.contains("\(uploader.user):2") && trace.contains("\(downloader.user):2")
    }

    let searchToken = try await downloader.session.search(query: "Jóga")
    try await awaitCallbackEvidence("search result") { !downloader.results.isEmpty }
    let result = try #require(downloader.results.first)
    #expect(result.user == uploader.user)
    #expect(result.file == uploader.file)
    #expect(result.freeSlot && result.speed == 123_456 && result.queue == 0)
    try await downloader.session.peerSend(user: uploader.user, code: 4)
    try await downloader.session.peerSend(user: uploader.user, code: 15)
    try await awaitCallbackEvidence("browse and metadata") { downloader.library != nil && downloader.description != nil }
    #expect(downloader.library?.user == uploader.user)
    #expect(downloader.library?.folders["Synthetic\\Björk"] == [uploader.file])
    #expect(downloader.description == "Synthetic uploader metadata")
    await downloader.session.retireSearch(searchToken)

    // The uploader owns the rendezvous token. The download transfer token is a
    // separate wire header, deliberately distinct from that callback token.
    let rendezvousToken = await uploader.session.token &+ 1
    let transferToken: UInt32 = 77
    #expect(rendezvousToken != transferToken)
    let outgoing = try await uploader.session.openFileConnection(user: downloader.user, transferToken: transferToken)
    try await awaitCallbackEvidence("downloader F socket") { downloader.incomingFile != nil }
    let (remoteUser, incoming) = try #require(downloader.incomingFile)
    #expect(remoteUser == uploader.user)
    var header = WireReader(try await incoming.exact(4, timeout: 5))
    #expect(try header.uint() == transferToken)
    #expect(await uploader.session.rendezvous[rendezvousToken] == nil)
    #expect(await uploader.session.fileWaiters[rendezvousToken] == nil)

    let addresses = await server.addressReplies
    #expect(addresses.contains { $0.requester == uploader.user && $0.target == downloader.user && $0.port == UInt32(forced ? 1 : downloaderPort) })
    let requests = await server.indirectRequests
    let fileRequests = requests.filter { $0.type == "F" }
    if forced {
        let request = try #require(fileRequests.first)
        #expect(fileRequests.count == 1)
        #expect(request.requester == uploader.user)
        #expect(request.target == downloader.user)
        #expect(request.token == rendezvousToken)
        #expect(request.callbackPort == UInt32(uploaderPort))
        // Search establishes P by callback too, but that is NOT our F evidence.
        #expect(requests.contains { $0.type == "P" && $0.requester == uploader.user && $0.target == downloader.user })
        #expect(await server.trace.contains("\(uploader.user):18"))
        print("F callback trace: server18 requester=\(request.requester) target=\(request.target) type=\(request.type) uploaderRendezvousToken=\(request.token) callbackPort=\(request.callbackPort) transferToken=\(transferToken)")
    } else {
        #expect(fileRequests.isEmpty)
        #expect(requests.isEmpty)
    }

    var offset = WireWriter(); offset.ulong(0)
    try await incoming.socket.send(offset.data)
    var receivedOffset = WireReader(try await outgoing.exact(8, timeout: 5))
    #expect(try receivedOffset.ulong() == 0)
    let receive = Task { try await incoming.exact(bytes.count, timeout: 10) }
    try await outgoing.socket.send(bytes)
    let received = try await receive.value
    #expect(received == bytes)
    #expect(received.count == 300_000)
    #expect(uploader.failures.isEmpty && downloader.failures.isEmpty)
    print("\(forced ? "forced-F" : "direct") synthetic upload: exactBytes=\(received.count), search/browse/metadata=passed")
    outgoing.socket.cancel(); incoming.socket.cancel()
    await uploader.session.releaseFileConnection(outgoing)
    await downloader.session.releaseFileConnection(incoming)
}
