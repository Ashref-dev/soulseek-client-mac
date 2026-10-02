import Foundation
import SoulseekCore
import Persistence
import ImageIO

extension AppModel {
    func handle(_ event: SoulseekEvent, account: String, generation: UInt64) async {
        guard !shuttingDown else { return }
        switch event {
        case .state(let state):
            connection = state
            await transferEngine.setConnected(state == .connected)
            if state != .connected { userStatuses = [:] }
            if case .failed = state, !intentionallyOffline, reconnectAllowed, reconnectTask == nil {
                let revision = loginRevision
                reconnectTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, !Task.isCancelled, revision == self.loginRevision else { return }
                    self.reconnectTask = nil
                    let password = self.savedPassword()
                    if !password.isEmpty { self.connection = .reconnecting; await self.login(password: password, automatic: true) }
                }
            }
        case .search(let token, let incoming):
            if token == searchToken {
                let ignored = Set(users.filter(\.ignored).map(\.username))
                for result in incoming where results.count + buffered.count < 50_000 && !ignored.contains(result.user) {
                    if resultIDs.insert(result.id).inserted { buffered.append(result) }
                }
                if batchTask == nil {
                    batchTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(120)); self?.flushResults()
                    }
                }
            } else if let id = wishlistTokens[token], let index = wishlist.firstIndex(where: { $0.id == id }) {
                var entry = wishlist[index]
                guard entry.enabled else { return }
                let previous = entry.seen.count
                for item in incoming where entry.seen.count < 20_000 { entry.seen.insert(item.id) }
                let added = entry.seen.count - previous
                entry.matches += added
                await saveWish(entry)
                if added > 0, wishlist.contains(where: { $0.id == id && $0.enabled }) {
                    await notify(key: "wish-\(id)", title: "New wishlist matches", text: entry.query, minimumInterval: 1800)
                }
            }
        case .library(let library):
            libraries[library.user] = library; browseLoading = false; browseRevision += 1
            do { try await database.put(library, collection: "libraries", id: library.user) } catch { self.error = error.localizedDescription }
        case .privateMessage(let id, let user, let text, let timestamp):
            guard !users.contains(where: { $0.username == user && $0.ignored }) else { try? await session.acknowledgeMessage(id, generation: generation); return }
            let messageID = "server-\(Data(account.utf8).base64EncodedString())-\(id)-\(timestamp)"
            guard !messages.contains(where: { $0.id == messageID }) else { try? await session.acknowledgeMessage(id, generation: generation); return }
            var message = ChatMessage(user: user, text: text, date: Date(timeIntervalSince1970: Double(timestamp)), outgoing: false)
            message.id = messageID
            message.account = account
            guard await recordMessage(message) else { return }
            do { try await session.acknowledgeMessage(id, generation: generation) } catch { log(error.localizedDescription) }
            guard activeAccount == account else { return }
            if activeConversation != user { unread.insert(user) }
            if activeConversation != user { await notify(key: "message-\(user)", title: "Message from \(user)", text: text, minimumInterval: 15) }
        case .roomMessage(let room, let user, let text):
            var message = ChatMessage(user: user, text: text, outgoing: user == account, room: room); message.account = account
            await recordMessage(message)
        case .roomList(let list): rooms = list.map { RoomSummary(name: $0.0, users: $0.1) }.sorted { $0.users > $1.users }
        case .roomJoined(let room, let users): joinedRooms[room] = users
        case .userStatus(let user, let status):
            userStatuses[user] = status
            if status != 0, let index = users.firstIndex(where: { $0.username == user }) {
                users[index].lastSeen = Date()
                do { try await database.put(users[index], collection: "users", id: user) } catch { log(error.localizedDescription) }
            }
        case .userInfo(let user, let description, let picture):
            userDescriptions[user] = description
            if let picture, let source = CGImageSourceCreateWithData(picture as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0, width <= 4096, height <= 4096 {
                userPictures[user] = picture
                if userPictures.count > 10, let first = userPictures.keys.first(where: { $0 != user }) { userPictures.removeValue(forKey: first) }
            }
        case .peerUnavailable(let user):
            if browsingUser == user { browseLoading = false }
            await transferEngine.peerUnavailable(user)
        case .roomMembership(let room, let user, let joined):
            guard joinedRooms[room] != nil else { return }
            if joined { if joinedRooms[room]?.contains(user) != true { joinedRooms[room]?.append(user) } }
            else { joinedRooms[room]?.removeAll { $0 == user } }
        case .userStats(let username, let speed, let files, let country):
            userStatistics[username] = UserStatistics(speed: speed, files: files, country: country ?? userStatistics[username]?.country)
            if let index = users.firstIndex(where: { $0.username == username }) {
                users[index].averageSpeed = speed; users[index].sharedFiles = files
                if let country { users[index].country = country }
                await saveUser(users[index])
            }
        case .privileges(let seconds): privilegeSeconds = seconds
        case .wishlistInterval(let seconds): wishlistSeconds = seconds; scheduleWishlist()
        case .peerMessage(let user, let code, let payload):
            do { try await handlePeer(user: user, code: code, payload: payload) } catch { log(error.localizedDescription) }
        case .fileConnection(let user, let connection): Task { await transferEngine.acceptFile(user: user, connection: connection) }
        case .searchRequest(let user, let token, let query):
            guard !users.contains(where: { $0.username == user && $0.ignored }) else { return }
            var trusted = false
            if users.contains(where: { $0.username == user && $0.trusted }) { trusted = await session.peerMatchesServerAddress(user) }
            let files = await shareIndex.search(query, allowPrivate: trusted, configuredFolders: currentShareFolders)
            guard !files.isEmpty else { return }
            do {
                let payload = try PeerCodec.searchReply(user: activeAccount, token: token, files: files,
                                                       slots: transfers.filter { $0.upload && $0.status == .transferring }.count < settings.uploadSlots,
                                                       speed: 0, queue: UInt32(transfers.filter { $0.upload && $0.status == .queued }.count))
                try await session.peerSend(user: user, code: 9, payload: payload)
            } catch { log(error.localizedDescription) }
        case .diagnostic(let text): log(text)
        }
    }
    func flushResults() { results.append(contentsOf: buffered); buffered.removeAll(keepingCapacity: true); batchTask = nil }
    func handlePeer(user: String, code: UInt32, payload: Data) async throws {
        var trusted = false
        if users.contains(where: { $0.username == user && $0.trusted }) { trusted = await session.peerMatchesServerAddress(user) }
        let ignored = users.contains { $0.username == user && $0.ignored }
        switch code {
        case 4:
            let library = ignored ? [:] : await shareIndex.library(allowPrivate: trusted, configuredFolders: currentShareFolders)
            try await session.peerSend(user: user, code: 5, payload: PeerCodec.libraryReply(library))
        case 15:
            var writer = WireWriter(); writer.string("Shared with Arpeggio."); writer.byte(0)
            writer.uint(UInt32(settings.uploadSlots)); writer.uint(UInt32(transfers.filter { $0.upload && $0.status == .queued }.count)); writer.byte(1)
            try await session.peerSend(user: user, code: 16, payload: writer.data)
        case 36:
            var reader = WireReader(payload); let token = try reader.uint(); let folder = try reader.string()
            let library = ignored ? [:] : await shareIndex.library(allowPrivate: trusted, configuredFolders: currentShareFolders)
            var writer = WireWriter(); writer.uint(token); writer.string(folder)
            PeerCodec.writeFolders(library.filter { $0.key == folder || $0.key.hasPrefix(folder + "\\") }, to: &writer)
            try await session.peerSend(user: user, code: 37, payload: Zlib.deflate(writer.data))
        case 37:
            var reader = WireReader(try Zlib.inflate(payload))
            let token = try reader.uint(); _ = try reader.string()
            guard let request = folderDownloads.removeValue(forKey: token), request.0 == user else { return }
            let folders = try PeerCodec.readFolders(&reader)
            let files = folders.filter { $0.key == request.1 || $0.key.hasPrefix(request.1 + "\\") }.values.flatMap { $0 }
            await download(files.map { SearchResult(user: user, file: $0, freeSlot: false, speed: 0, queue: 0) })
        case 43:
            var reader = WireReader(payload); let path = try reader.string()
            if !ignored, let file = await shareIndex.resolve(path, allowPrivate: trusted, configuredFolders: currentShareFolders) {
                await transferEngine.queueUpload(user: user, file: file.file, localURL: file.localURL)
            } else {
                var writer = WireWriter(); writer.string(path); writer.string("File not shared.")
                try await session.peerSend(user: user, code: 50, payload: writer.data)
            }
        default: try await transferEngine.peerMessage(user: user, code: code, payload: payload)
        }
    }
}
