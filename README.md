# Arpeggio

A standalone, native Soulseek client for **macOS 27**, written in Swift and SwiftUI. One sidebar, live search, release-oriented transfers, a Finder-like file browser, and native conversations. Liquid Glass is confined to navigation and controls, not file tables or message content.

No SoulseekQt wrapper, Nicotine+ installation, Electron, Docker, external daemon, or additional cloud service is required. The application connects directly to the Soulseek server and peers.

## Verification status

The native application builds on macOS 27 with Xcode 27. Automated tests exercise actual TCP connections between independent Swift client instances: login framing, searches, browsing, uploads, downloads, callback connections, private messages, rooms, and partial-download restoration. Hostile-input, filesystem, lifecycle, persistence, and file-watching tests are included.

**Real-account Soulseek interoperability is deliberately pending.** It will be tested separately with an account supplied by its owner. Local protocol fixtures are not evidence of successful authentication against the public server or compatibility with every SoulseekQt/Nicotine+/slskd peer. No automated throwaway accounts are created.

## Build and run

Requirements:

- macOS 27 or later
- Xcode 27, with its command-line tools selected
- Swift 6.2 or later (developed with Swift 6.4)

```bash
git clone https://github.com/Ashref-dev/soulseek-client-mac.git
cd soulseek-client-mac
bash scripts/build-app.sh
open dist/Arpeggio.app
```

The build script produces an ad-hoc-signed `.app` with its icon and bundle metadata. Move it into Applications if desired. Ad-hoc builds are intended for local use; distributing a downloaded binary requires Developer ID signing and notarization. To use an installed signing identity:

```bash
ARPEGGIO_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/build-app.sh
```

This is a certificate identity, not a password. Never commit signing material or credentials.

For development, open `Package.swift` in Xcode and choose the Arpeggio executable scheme, or run:

```bash
swift build --product Arpeggio
bash scripts/build-app.sh debug
swift test
```

Use the packaged `.app` when checking notifications, app identity, and login-item integration. These depend on a proper application bundle.

## Getting started

1. Click the account control at the bottom of the sidebar or choose **Network → Connect**.
2. Enter your Soulseek username and password. Password storage is optional and uses Keychain.
3. Accept the explicit notice about Soulseek's unencrypted authentication protocol.
4. Search by artist, album, track, or filename. Results arrive over peer connections and are batched for presentation.
5. Select files to download, or use **Download Entire Folder** to request the complete remote folder rather than only the search hits.
6. Add shared directories in **Settings → Sharing**. Trusted-only directories require a trusted user and an IP matching the server's peer address.

Default server: `server.slsknet.org:2242`. Default incoming TCP port: `2234`. If the port is already occupied, choose another in Advanced settings. For reliable incoming connectivity, forward the selected TCP port through your router and allow Arpeggio through the macOS firewall. Callback negotiation helps when one side is reachable; it is not a relay when both sides are unreachable.

### Keyboard and native integration

| Shortcut | Action |
|---|---|
| ⌘K | Command palette |
| ⌘F | Network search |
| ⌘1–⌘9 | Search, Downloads, Uploads, Browse, Wishlist, Messages, Rooms, Users, Shared Files |
| ⇧⌘N | New private conversation |
| ⇧⌘B | Browse a user |
| ⌘, | Settings |
| ⌘[ / ⌘] | Back / forward in a user library |
| ⌘↑ | Enclosing folder |
| Space | Quick Look for a selected local transfer file |

Native selection, contextual menus, copy/paste, Finder reveal, full-screen windows, system/light/dark appearance, compact density, notification throttling, and window-section restoration are supported.

## State and file safety

Application state lives in `~/Library/Application Support/Arpeggio/arpeggio.sqlite`. Credentials are not stored in SQLite or source files. For an isolated **local test** instance, `ARPEGGIO_DATA_DIRECTORY` can point to a separate directory; do not point it at someone else's application data.

Downloads default to `~/Downloads/Arpeggio/{username}/{remote folders}`. Incomplete files use a reserved, hidden `.arpeggio-…partial` name. Pausing, cancelling, and clearing history do not delete downloaded content. Partial files survive relaunch; completed files are published only after the expected byte count has been written and synchronized.

Traversal, control characters, unsafe local names, symlink escapes, absurd sizes, malformed packets, decompression bombs, and amplified library hierarchies are rejected. Files must be explicitly indexed to be uploaded. Sharing/trust revocation invalidates queued or active uploads.

The Soulseek protocol provides no file checksum or cryptographically authenticated peer identity. Exact byte-count completion is not a cryptographic integrity guarantee. Use a unique Soulseek password, share only directories you intend to publish, and do not run untrusted downloaded executables.

## Architecture

| Module | Responsibility |
|---|---|
| `SoulseekCore` | Bounded wire codecs, zlib, TCP framing, server authentication, P/F/D connections, rendezvous, generation-scoped events |
| `TransferEngine` | Queues, attempt ownership, concurrency, bandwidth limits, retry deadlines, partial files and safe completion |
| `ShareIndexer` | Background enumeration, audio attributes, privacy filtering, exclusions, recursive FSEvents watching |
| `Persistence` | Versioned SQLite records, durable settings/history, and Keychain |
| `ArpeggioServices` | Main-actor presentation state and search, browsing, social, wishlist, sharing and lifecycle coordination |
| `Arpeggio` | SwiftUI windows, native tables, menus, settings, sheets, inspectors and AppKit integration |

The services source directory is named `ApplicationServices`, but the Swift module is `ArpeggioServices` to avoid colliding with Apple's framework of the same name. Networking and persistence do not live in SwiftUI views. The only dependencies are system frameworks and system SQLite/zlib.

See [implementation overview](docs/IMPLEMENTATION.md) and [protocol notes](docs/PROTOCOL.md).

## Offline protocol development

```bash
swift run ArpeggioFixture --help
swift run ArpeggioFixture
```

This **optional developer fixture** binds only to loopback and prints its temporary server port. It runs a real Swift peer sharing generated original WAV files. Configure the application to use that loopback port, sign in with the printed fixture credentials without saving them in Keychain, and search for `Glass Notes` or browse `studio-fixture`.

The fixture is not shipped inside Arpeggio.app, is not needed for normal use, and never contacts the public Soulseek service. It expires after ten minutes. Its sample credentials are intentionally public, local-only test values.

`scripts/native-qa.swift` inspects and drives the packaged app through macOS accessibility APIs. It requires explicit Accessibility/Screen Recording permission from macOS. Use it only with isolated fixture data, never to publish real conversations or credentials. Keyboard events are PID-targeted, not posted globally.

## Known limits and joint test checklist

- Public-server login, independent-client interoperability, NAT/router variations, and real-world network recovery await the joint account test.
- Automatic UPnP/NAT-PMP port mapping and obfuscated peer connections are not implemented. Plain TCP and server-assisted callbacks are implemented.
- The distributed role is a leaf, not a forwarding branch accepting children.
- Large search and browse responses have explicit safety budgets. Search presentation caps at 50,000 results; a wishlist retains 20,000 unique matches. Library search shows at most 2,000 file matches at once.
- Unsafe absolute/drive-letter paths and the reserved partial namespace are rejected rather than silently rewritten.
- Some audio formats do not expose native AVFoundation metadata; files remain shareable without quality attributes. Lossy bitrate estimates may include container overhead.
- System notification and login-item permission behavior depends on installation/signing and must be checked on the target Mac.
- Interests/recommendation UI and private-room administrative tools are not included; ordinary private messages, room membership, and room chat are implemented.

The joint session should cover login, global search, folder browsing/downloads with Nicotine+/SoulseekQt peers, incoming uploads, queue/denial handling, restart/resume, messages, rooms, wishlist timing, and listening-port/firewall diagnostics. Do not reuse a password from another service.

## License and references

Arpeggio is MIT-licensed. Its icon is original and replaceable; `Resources/AppIcon.svg` and `scripts/render-icon.swift` contain the artwork and renderer.

Protocol research references Nicotine+ (GPL-3.0-or-later), Soulseek.NET (GPL-3.0), and slskd (AGPL-3.0). No implementation source from those projects is vendored or translated into this repository. Their wire contracts were independently implemented in Swift. Reference links and compatibility findings are in [protocol notes](docs/PROTOCOL.md).

Arpeggio is not affiliated with or endorsed by Soulseek.
