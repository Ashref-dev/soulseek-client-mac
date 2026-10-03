import Foundation

public enum LoginIdentity {
    public static func validateUsername(_ username: String) throws {
        guard !username.isEmpty, username.utf8.count <= 30,
              username == username.trimmingCharacters(in: .whitespaces),
              username.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) else {
            throw ProtocolError.invalid("Use a username of 1–30 printable ASCII characters, without spaces at either end.")
        }
    }
}
