import Testing
import SoulseekCore

@Test func validatesActualServerUsernameContractBeforeSendingCredentials() throws {
    try LoginIdentity.validateUsername("fixture user")
    try LoginIdentity.validateUsername(String(repeating: "a", count: 30))
    for value in ["", " user", "user ", "user\n", "Björk", String(repeating: "a", count: 31)] {
        #expect(throws: ProtocolError.self) { try LoginIdentity.validateUsername(value) }
    }
}
