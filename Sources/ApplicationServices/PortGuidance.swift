public enum PortGuidance {
    public static func instructions(port: UInt16) -> [String] {
        ["If your former Soulseek Qt client worked with a router rule, use that same listening port here. Saved ports are never changed automatically.",
         "In your router’s Port Forwarding or Virtual Server settings, forward TCP port \(port) to port \(port) at this Mac’s local LAN address. Keep that LAN address reserved in your router.",
         "Only one app can listen on a port at a time. Quit the other Soulseek client before connecting Arpeggio on the same port.",
         "Arpeggio does not need an extra obfuscated port. Local listener checks and mapping acknowledgments do not prove internet reachability; the external check tests the route used by its HTTPS request."]
    }
}
