import Foundation
import Testing
import SoulseekCore
import Persistence
@testable import ArpeggioServices

struct SearchIdentityTests {
    @Test func helperFramesControlDelimitersAndUTF8WithoutEscapingAliases() {
        #expect(SearchIdentity.key(user: "a", path: "b\u{1F}c") != SearchIdentity.key(user: "a\u{1F}b", path: "c"))
        #expect(SearchIdentity.key(user: "a", path: "b:c") != SearchIdentity.key(user: "a:b", path: "c"))
        let key = SearchIdentity.key(user: "é", path: "音乐\\track")
        #expect(key.hasPrefix("search-v2:2:"))
        #expect(!key.contains("\0"))
        #expect(SearchIdentity.key(user: "", path: "a") != SearchIdentity.key(user: "a", path: ""))
        #expect(SearchIdentity.legacyWishlistKey(user: "a\0b", path: "c") == nil)
        #expect(SearchIdentity.legacyWishlistKey(user: "a", path: "b\0c") == nil)
    }
    @Test func nulContainingDecodedFieldsCannotCollide() {
        let first = result(user: "a", path: "b\0c")
        let second = result(user: "a\0b", path: "c")
        #expect(first.id != second.id)
        #expect(Set([first.id, second.id]).count == 2)
    }

    @Test @MainActor func persistedNormalLegacyWishlistHitMigratesWithoutRecount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        model.settings.notifications = false
        let existing = result(user: "fixture-user", path: "Music\\Track.flac")
        let legacy = existing.user + "\0" + existing.file.path
        var saved = WishlistEntry(query: "fixture")
        saved.matches = 42; saved.seen = [legacy]
        let restored = try JSONDecoder().decode(WishlistEntry.self, from: JSONEncoder().encode(saved))
        model.wishlist = [restored]; model.wishlistTokens[99] = saved.id
        await model.handle(.search(99, [existing, existing]), account: "fixture", generation: 0)
        let upgraded = try #require(model.wishlist.first)
        #expect(upgraded.matches == 42)
        #expect(upgraded.seen == [existing.id])
        #expect(!upgraded.seen.contains(legacy))
        #expect(existing.id != legacy)
        let persisted = try #require(try await model.database.all(WishlistEntry.self, collection: "wishlist").first)
        #expect(persisted.matches == 42); #expect(persisted.seen == [existing.id])
        let fresh = result(user: "fixture-user", path: "Music\\Other.flac")
        await model.handle(.search(99, [existing, fresh, fresh]), account: "fixture", generation: 0)
        #expect(model.wishlist.first?.matches == 43)
        await model.shutdown()
    }

    @Test @MainActor func ambiguousLegacyKeysCannotCombineMaliciousOwners() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        model.settings.notifications = false
        let first = result(user: "a", path: "b\0c")
        let second = result(user: "a\0b", path: "c")
        var saved = WishlistEntry(query: "fixture"); saved.seen = ["a\0b\0c"]; saved.matches = 5
        model.wishlist = [saved]; model.wishlistTokens[99] = saved.id
        await model.handle(.search(99, [first, second]), account: "fixture", generation: 0)
        #expect(model.wishlist.first?.matches == 7)
        #expect(model.wishlist.first?.seen.contains(first.id) == true)
        #expect(model.wishlist.first?.seen.contains(second.id) == true)
        await model.shutdown()
    }

    @Test @MainActor func lazyMigrationAtRetentionLimitDoesNotResetOrRecount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        model.settings.notifications = false
        let existing = result(user: "fixture-user", path: "Music\\Track.flac")
        let legacy = existing.user + "\0" + existing.file.path
        var saved = WishlistEntry(query: "fixture")
        saved.seen = Set((0..<19_999).map { "retained-\($0)" }); saved.seen.insert(legacy)
        saved.matches = 25_000
        model.wishlist = [saved]; model.wishlistTokens[99] = saved.id
        await model.handle(.search(99, [existing]), account: "fixture", generation: 0)
        #expect(model.wishlist.first?.seen.count == 20_000)
        #expect(model.wishlist.first?.seen.contains(existing.id) == true)
        #expect(model.wishlist.first?.matches == 25_000)
        await model.shutdown()
    }

    private func result(user: String, path: String) -> SearchResult {
        SearchResult(user: user, file: SharedFile(path: path, size: 1), freeSlot: true, speed: 0, queue: 0)
    }
}
