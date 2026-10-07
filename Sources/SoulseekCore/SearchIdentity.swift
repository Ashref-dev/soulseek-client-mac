import Foundation

public enum SearchIdentity {
    public static func key(user: String, path: String) -> String {
        let userBytes = Data(user.utf8)
        let pathBytes = Data(path.utf8)
        return "search-v2:\(userBytes.count):\(userBytes.base64EncodedString()):\(pathBytes.count):\(pathBytes.base64EncodedString())"
    }

    /// Legacy aliases are accepted only when the original NUL boundary has exactly one interpretation.
    public static func legacyWishlistKey(user: String, path: String) -> String? {
        guard (try? LoginIdentity.validateUsername(user)) != nil, !path.utf8.contains(0) else { return nil }
        return user + "\0" + path
    }
}
