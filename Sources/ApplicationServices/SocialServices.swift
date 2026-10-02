import Foundation
import SoulseekCore
import Persistence

extension AppModel {
    public func bookmark(_ username: String) async {
        guard !username.isEmpty, !users.contains(where: { $0.username == username }) else { return }
        let user = UserRecord(username: username); users.append(user)
        await saveUser(user)
        if connection == .connected { do { try await watchUser(username) } catch { self.error = error.localizedDescription } }
    }
    public func saveUser(_ user: UserRecord) async {
        guard let index = users.firstIndex(where: { $0.id == user.id }) else { return }
        let permissionsChanged = users[index].trusted != user.trusted || users[index].ignored != user.ignored
        users[index] = user
        do { try await database.put(user, collection: "users", id: user.id) } catch { self.error = error.localizedDescription }
        if permissionsChanged { await transferEngine.revalidateUploads() }
    }
    public func removeUser(_ user: UserRecord) async {
        do {
            try await database.remove(collection: "users", id: user.id); users.removeAll { $0.id == user.id }
            await transferEngine.revalidateUploads()
        }
        catch { self.error = error.localizedDescription }
    }
    public func userInfo(_ username: String) async {
        do {
            var writer = WireWriter(); writer.string(username)
            try await session.send(code: 36, payload: writer.data)
            try await session.send(code: 7, payload: writer.data)
            try await session.peerSend(user: username, code: 15)
        } catch { self.error = error.localizedDescription }
    }
    public func sendMessage(to user: String, text: String, room: Bool = false) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !user.isEmpty else { return }
        guard let generation = activeSessionGeneration, connection == .connected else { error = "Connect before sending a message."; return }
        let account = activeAccount
        do {
            var writer = WireWriter(); writer.string(user); writer.string(text)
            try await session.send(code: room ? 13 : 22, payload: writer.data, generation: generation)
            if !room {
                var message = ChatMessage(user: user, text: text, outgoing: true); message.account = account
                await recordMessage(message)
            }
        } catch { self.error = error.localizedDescription }
    }
    public func joinRoom(_ room: String) async {
        do { var writer = WireWriter(); writer.string(room); writer.uint(0); try await session.send(code: 14, payload: writer.data) }
        catch { self.error = error.localizedDescription }
    }
    public func leaveRoom(_ room: String) async {
        do { var writer = WireWriter(); writer.string(room); try await session.send(code: 15, payload: writer.data); joinedRooms.removeValue(forKey: room) }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult func recordMessage(_ message: ChatMessage) async -> Bool {
        var message = message
        if message.account == nil { message.account = activeAccount }
        do {
            try await database.put(message, collection: "messages", id: message.id)
            if message.account == activeAccount { messages.append(message) }
            messages = Array(messages.suffix(10_000))
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    public func addWish(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !wishlist.contains(where: { $0.query.caseInsensitiveCompare(query) == .orderedSame }) else { return }
        let entry = WishlistEntry(query: query); wishlist.append(entry); await saveWish(entry)
    }
    public func saveWish(_ entry: WishlistEntry) async {
        if let index = wishlist.firstIndex(where: { $0.id == entry.id }) { wishlist[index] = entry }
        do { try await database.put(entry, collection: "wishlist", id: entry.id) } catch { self.error = error.localizedDescription }
    }
    public func removeWish(_ entry: WishlistEntry) async {
        do { try await database.remove(collection: "wishlist", id: entry.id); wishlist.removeAll { $0.id == entry.id } }
        catch { self.error = error.localizedDescription }
    }
    func scheduleWishlist() {
        wishlistTask?.cancel()
        guard wishlistSeconds > 0 else { return }
        wishlistTask = Task { [weak self] in
            var cursor = 0
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(max(60, self.wishlistSeconds)))
                guard !Task.isCancelled, self.connection == .connected else { return }
                let entries = self.wishlist.filter(\.enabled)
                guard !entries.isEmpty else { continue }
                let entry = entries[cursor % entries.count]; cursor += 1
                do {
                    let token = await self.session.nextToken()
                    self.wishlistTokens[token] = entry.id
                    _ = try await self.session.search(query: entry.query, wishlist: true, token: token)
                    if self.wishlistTokens.count > 100 { self.wishlistTokens.removeValue(forKey: self.wishlistTokens.keys.min() ?? token) }
                    if let index = self.wishlist.firstIndex(where: { $0.id == entry.id }) {
                        self.wishlist[index].lastChecked = Date(); await self.saveWish(self.wishlist[index])
                    }
                } catch { self.log(error.localizedDescription) }
            }
        }
    }
}
