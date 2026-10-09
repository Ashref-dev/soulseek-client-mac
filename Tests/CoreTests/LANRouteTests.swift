import Foundation
import Network
import Testing
@testable import SoulseekCore

@Suite struct LANRouteTests {
    @Test func onlyInternetAddressesAreTreatedAsShared() {
        for host in ["196.237.242.167", "8.8.8.8", "100.128.0.1"] { #expect(LANRoute.isPublic(host)) }
        for host in ["127.0.0.1", "10.0.0.4", "172.16.3.1", "172.31.255.1", "192.168.1.167", "169.254.2.2", "100.64.0.1", "0.0.0.0", "239.1.1.1", "x"] {
            #expect(!LANRoute.isPublic(host))
        }
    }

    @Test func candidatesCoverTheSubnetButStopAtASlash22() {
        let home = LANRoute.candidates(networks: [(0xC0A8_01A7, 0xFFFF_FF00)])
        #expect(home.count == 254)
        #expect(home.first == 0xC0A8_0101 && home.last == 0xC0A8_01FE)
        let office = LANRoute.candidates(networks: [(0x0A00_0505, 0xFF00_0000)])
        #expect(office.count == 1022)
        #expect(office.allSatisfy { $0 & 0xFFFF_FC00 == 0x0A00_0400 })
    }

    @Test func scanFindsAListenerOnThisMachineAndSkipsExcludedHosts() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0 { continuation.yield(listener.port?.rawValue ?? 0); continuation.finish() } }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var iterator = ready.makeAsyncIterator()
        let port = try #require(await iterator.next())
        let own = Set(LANRoute.localNetworks().map { LANRoute.string($0.address) })
        try #require(!own.isEmpty, "needs a local network interface")
        let found = await LANRoute.scan(port: port)
        #expect(!Set(found).isDisjoint(with: own))
        #expect(Set(await LANRoute.scan(port: port, excluding: own)).isDisjoint(with: own))
    }

    /// Silent addresses must not serialise: 200 unanswered hosts finish in a few timeouts, not 200.
    @Test func probeIsASlidingWindowAndOnlyScansPrivateRanges() {
        #expect(LANRoute.concurrency <= 64)
        let started = ContinuousClock.now
        let found = LANRoute.probe((1...200).map { "198.51.100.\($0)" }, port: 9, timeoutMilliseconds: 100)
        #expect(found.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(LANRoute.isPrivate(0xC0A8_01A7) && LANRoute.isPrivate(0x0A01_0203) && LANRoute.isPrivate(0xAC1F_0001))
        #expect(!LANRoute.isPrivate(0xA9FE_8959) && !LANRoute.isPrivate(0x6476_A917) && !LANRoute.isPrivate(0xAC20_0001))
    }


}
