import Foundation
import Darwin
import ArpeggioServices
import SoulseekCore
import Persistence

@main
struct LiveMain {
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Live verification: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2, !args.contains("--help") else {
            print("Usage: ArpeggioLive <username> <login|search|browse|download|self-message|interactive> [query-or-user] [seconds]. Password is read silently from the terminal, never from arguments. All data is isolated under Application Support/ArpeggioLive.")
            return
        }
        let username = args[0]; let action = args[1]
        guard ["login", "search", "browse", "download", "self-message", "interactive"].contains(action) else { throw ProtocolError.invalid("Unknown verification action.") }
        try LoginIdentity.validateUsername(username)
        let password = try securePassword()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ArpeggioLive")
        let model = try AppModel(dataDirectory: root)
        await model.start()
        for item in model.transfers where !item.upload && ![.completed, .cancelled].contains(item.status) { await model.transferEngine.cancel(item.id) }
        model.settings.username = username
        model.settings.server = "server.slsknet.org"; model.settings.port = 2242; model.settings.listeningPort = 2235
        model.settings.notifications = false
        model.settings.downloadDirectory = root.appendingPathComponent("Downloads").path
        model.settings.sharedFolders = []
        print("Connecting to \(model.settings.server):\(model.settings.port), listener \(model.settings.listeningPort)")
        await model.login(password: password, remember: false)
        guard model.connection == .connected else {
            let reason = model.error ?? model.connection.label
            for detail in model.diagnostics.suffix(10) { print(detail) }
            await model.shutdown(); throw ProtocolError.invalid(reason)
        }
        print("LIVE LOGIN ACCEPTED; rooms=\(model.rooms.count)")
        let seconds = args.count > 3 ? Int(args[3]) ?? 25 : 25
        switch action {
        case "interactive":
            print("Commands: search <query>, browse <user>, download <result-number>, shares, message-self, status, quit")
            while model.connection == .connected {
                print("LIVE>", terminator: " "); fflush(stdout)
                guard let line = await Task.detached(operation: { readLine() }).value else { break }
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                let argument = parts.count > 1 ? parts[1] : ""
                switch parts.first ?? "" {
                case "quit": await model.shutdown(); return
                case "search":
                    model.query = argument; await model.search(); try await Task.sleep(for: .seconds(25))
                    print("RESULT COUNT \(model.results.count)")
                    model.results.sort { $0.freeSlot == $1.freeSlot ? $0.speed > $1.speed : $0.freeSlot }
                    for (index, result) in model.results.prefix(20).enumerated() { print("\(index): \(result.user) | \(result.file.size) | \(result.speed) | \(result.freeSlot) | \(result.file.path)") }
                case "browse":
                    await model.browse(argument); try await Task.sleep(for: .seconds(25))
                    if let library = model.libraries[argument] { print("LIBRARY \(library.folders.count) folders, \(library.folders.values.reduce(0) { $0 + $1.count }) files") }
                case "download":
                    guard let index = Int(argument), model.results.indices.contains(index) else { print("Invalid result number"); continue }
                    let result = model.results[index]; print("QUEUING \(result.user) | \(result.file.path)")
                    await model.download([result]); try await Task.sleep(for: .seconds(40))
                case "shares":
                    let folder = root.appendingPathComponent("Original-Arpeggio-Share")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data("Original Arpeggio interoperability test data, created by this client.\n".utf8).write(to: folder.appendingPathComponent("Arpeggio-original-share.txt"))
                    model.settings.sharedFolders = [ShareFolder(path: folder.path)]; await model.saveSettings()
                    print("SHARED \(model.sharedCount) original file, \(model.sharedBytes) bytes")
                case "message-self":
                    await model.sendMessage(to: username, text: "Arpeggio authorized live self-test " + UUID().uuidString)
                    try await Task.sleep(for: .seconds(3)); print("MESSAGES \(model.messages.count)")
                default: break
                }
                print("STATE \(model.connection.label); results=\(model.results.count); rooms=\(model.rooms.count)")
                for item in model.transfers.filter({ !$0.upload && $0.status != .cancelled }).prefix(10) { print("TRANSFER \(item.user) \(item.status.rawValue) \(item.transferred)/\(item.file.size) q\(item.queuePosition) \(item.error ?? "")") }
                for detail in model.diagnostics.suffix(20) { print("DETAIL \(detail)") }
            }
        case "login": try await Task.sleep(for: .seconds(2))
        case "search", "download":
            guard args.count > 2 else { throw ProtocolError.invalid("Supply a search query.") }
            model.query = args[2]; await model.search()
            try await Task.sleep(for: .seconds(max(5, min(180, seconds))))
            print("LIVE SEARCH RESULTS: \(model.results.count)")
            for result in model.results.prefix(15) {
                print("RESULT \(result.user) | \(result.file.size) | \(result.freeSlot ? "free" : "queued") | \(result.file.path)")
            }
            if action == "download", let result = model.results.filter({ $0.freeSlot && $0.file.size > 0 && $0.file.size < 10_000_000 }).sorted(by: { $0.speed == $1.speed ? $0.file.size < $1.file.size : $0.speed > $1.speed }).first {
                print("SELECTED \(result.user) | \(result.file.path) | \(result.file.size)")
                await model.download([result])
                let deadline = ContinuousClock.now.advanced(by: .seconds(180))
                var previous = ""
                while ContinuousClock.now < deadline {
                    if let transfer = model.transfers.first(where: { !$0.upload && $0.user == result.user && $0.file.path == result.file.path && $0.status != .cancelled }) {
                        let state = "\(transfer.status.rawValue) bytes=\(transfer.transferred)/\(transfer.file.size) queue=\(transfer.queuePosition) error=\(transfer.error ?? "none")"
                        if state != previous { print("TRANSFER \(state)"); previous = state }
                        if transfer.status == .completed {
                            print("LIVE DOWNLOAD COMPLETED: \(transfer.file.name)")
                            break
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            }
        case "browse":
            guard args.count > 2 else { throw ProtocolError.invalid("Supply a username to browse.") }
            await model.browse(args[2]); try await Task.sleep(for: .seconds(max(5, min(180, seconds))))
            if let library = model.libraries[args[2]] { print("LIVE LIBRARY folders=\(library.folders.count) files=\(library.folders.values.reduce(0) { $0 + $1.count })") }
        case "self-message":
            let text = "Arpeggio live protocol self-test " + UUID().uuidString
            await model.sendMessage(to: username, text: text)
            try await Task.sleep(for: .seconds(5))
            print("SELF MESSAGE RECEIVED: \(model.messages.contains { !$0.outgoing && $0.text == text })")
        default: break
        }
        for detail in model.diagnostics.suffix(20) { print("DETAIL \(detail)") }
        print("SERVER STATE: \(model.connection.label)")
        await model.shutdown()
    }
    static func securePassword() throws -> String {
        guard isatty(STDIN_FILENO) != 0 else { throw ProtocolError.invalid("Use an interactive terminal for secure password entry.") }
        var previous = termios()
        guard tcgetattr(STDIN_FILENO, &previous) == 0 else { throw ProtocolError.invalid("Could not secure terminal input.") }
        var hidden = previous; hidden.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else { throw ProtocolError.invalid("Could not disable terminal echo.") }
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &previous) }
        FileHandle.standardOutput.write(Data("Soulseek password (hidden): ".utf8))
        guard let password = readLine(), !password.isEmpty else { throw ProtocolError.invalid("Password is required.") }
        FileHandle.standardOutput.write(Data("\n".utf8))
        return password
    }
}
