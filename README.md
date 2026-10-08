<p align="center"><img src="docs/cover.jpg" alt="Soulseek-Arpeggio, a native Soulseek client for macOS" width="100%"></p>

# Soulseek-Arpeggio

Soulseek-Arpeggio (Arpeggio for short) is a native Soulseek client for macOS, written in Swift and SwiftUI. It talks to the Soulseek server and to other people directly, with no wrapper, daemon or web view in between.

Soulseek is a long-running peer-to-peer network where people share their music libraries with each other. You search everyone who is online, download straight from them, and share your own folders in return.

## What it does

- **Search** the whole network. Results stream in live and are grouped by person, album and track, with quick filters for lossless, hi-res and bitrate.
- **Preview first.** Preview native audio, video, images and PDFs from Search, Browse or Transfers, including with Space. Supported audio can stream while bytes arrive; other files fetch into a temporary cache before opening in macOS playback or Quick Look. Codec support depends on macOS. Previews are limited to 512 MB and a five-minute fetch deadline. Keep them with Download, or close to discard.
- **Download** single files or whole albums. Each album lands in its own folder. Unfinished files wait in a visible `Incomplete` folder and move into place when done. There are no per-user folders unless you ask for them.
- **Share** folders with a drag and drop. See what you share, how big it is, and who is downloading from you right now.
- **Sharing policy and indexing.** Settings > Sharing and the welcome guide let you require sharing before someone downloads from you, with a configurable automatic message. Only fresh confirmed zero-share counts are declined; unknown counts are allowed. Messages are throttled per account and user. Indexing reports its current folder and actual files processed, without estimating an unknown total. The welcome guide offers both your Music folder and a prominent custom-folder picker.
- **Stay in the menu bar.** Close the window and Arpeggio keeps sharing. The menu bar icon (the classic Soulseek bird or the Arpeggio mark, chosen in Settings > General) shows whether you are offline, available or away, and whether anything is downloading, uploading or both, without animating. Its panel shows live speeds, pauses or resumes each direction, and opens Search, Settings or the download folder.
- **Statistics** count everything you have downloaded and uploaded since you started, in the sidebar and in Settings > Statistics. Totals are in decimal gigabytes (1 GB = 1,000,000,000 bytes) with completed file counts. Copy a text summary, or copy, save or share a 1200 x 676 picture. Your username and profile picture appear only if you turn them on.
- **Basic Soulseek workflows:** wishlist searches, received searches, browsing someone's library, private messages, chat rooms, a user list with trusted and ignored people, Available and Away status, your own picture and description, upload slots, speed limits and per-user queue limits. This is not a promise of exhaustive parity with mature clients.
- **Pause entire directions.** Pause or resume Uploads and Downloads independently from the menu bar or Network menu. Active sockets stop, queues remain, and downloads resume from partial bytes. Presence stays unchanged. These controls are session-only.
- **Router diagnostics.** Choose NAT-PMP and UPnP independently. Arpeggio reports actual mapping acknowledgments, not assumed compatibility or external reachability. Check Ports tests the local TCP listener. Check External Reachability contacts Soulseek's HTTPS port checker only after confirmation, with no credentials. It tests the public route used by that request; VPN routes may differ. Listening ports are never changed automatically.
- **Updates itself** from GitHub Releases, and only installs updates signed by the same developer.

Version 0.6 implements safer transfer history controls and independent Flat, Folders and Users > Folders > Files layouts for downloads and uploads. Removing a row from the list is not file deletion. An active transfer requires confirmation to stop first; completed files, partial downloads and lifetime totals are retained. It also adds a pixel Soulseek bird for Available, Away and offline, a Network settings destination, typed diagnostics with a redacted Copy Report, reconnect countdown and retry, a compact player with playback commands, and more explicit privacy and port onboarding. Reliability work protects partial-file ownership, settings recovery, transfer history restore, accounting, reentrant batch enqueue and updater replacement. The latest plain full test run passed 313 tests in 52 suites; final native UI inspection by the user remains outstanding. The published preview artifact still needs a fresh build from the final clean source. See the [0.6 acceptance gates](docs/ROADMAP-0.6.md) and [release notes](docs/RELEASE-0.6.md).

## Install

1. For an existing stable build, use the [latest stable release](https://github.com/Ashref-dev/soulseek-client-mac/releases/latest). The 0.6.0-rc.1 preview is a GitHub prerelease at the [exact tag page](https://github.com/Ashref-dev/soulseek-client-mac/releases/tag/v0.6.0-rc.1), not the stable latest link or updater. Confirm the release exists before downloading.
2. Download the single `Soulseek-Arpeggio-0.6.0-rc.1.zip` archive from that release page, unzip it, then replace the app in Applications with **Soulseek-Arpeggio**. The app data and credentials are stored separately and are not removed by replacing the application. Older clients may not accept this preview through the updater, so use the manual download path.
3. Open it. The 0.6 preview is signed with the pinned Apple Development certificate, not notarized. If macOS blocks it, use **System Settings > Privacy & Security > Open Anyway** if macOS offers that option. Do not use Control-click > Open as a workaround or treat signature validity as notarization or Gatekeeper approval. The About view reports the custom prerelease version.

The current support target is Apple Silicon and macOS 27 or later. No Intel or older-macOS support is claimed. A welcome guide walks you through signing in and sharing your music folder. There is no separate sign-up on Soulseek: if the username you pick is free, the server registers it the first time you sign in.

### Listening port and router

New profiles use TCP port **61147**. An existing profile keeps its saved listening port. Arpeggio does not rewrite it or add a second, obfuscated port. To receive incoming connections, set your router's TCP **Port Forwarding** or **Virtual Server** rule to the port shown in Arpeggio and the Mac's current LAN IP address. If you used SoulseekQt, use the same listening port as that client. Router menus differ; reserve the Mac's LAN address if your router supports it. Only one client can listen on a given port on the same Mac at a time. Don't run another Soulseek client on the same account and same port alongside Arpeggio.

With **Remember password** enabled, Arpeggio saves your password in Keychain after successful authentication and connects automatically on the next launch without waiting for folder indexing. If the password is missing or Keychain blocks access, the app explains what needs attention instead of staying silently offline. Sign Out disconnects and forgets the password; Disconnect only goes offline for the current session.

Shared-folder metadata is cached after a successful scan. Relaunch still checks actual files, paths, sizes, modification times and current sharing permissions before advertising them. Unchanged Settings saves do not queue another scan; filesystem changes still do. A first scan of a large library can take time, and the app now distinguishes indexing from having no configured shares.

The 0.6 software tests, including the latest enqueue reentrancy regression and full suite, have passed. The earlier F3 candidate predates that last source correction and must not be published; prepare a new artifact from the final clean source. The preview remains an unnotarized development build. No Developer ID/notarization, quarantined clean-Mac install or upgrade, or independent-network transfer receipts are available. Final manual review of the native UI is also still required. The [0.6 release gates](docs/ROADMAP-0.6.md) distinguish completed software checks from those outstanding distribution and user-acceptance gates.

## Build from source

You need Xcode 27 with Swift 6.2 or later.

```bash
git clone https://github.com/Ashref-dev/soulseek-client-mac.git
cd soulseek-client-mac
swift test
bash scripts/build-app.sh
open dist/Soulseek-Arpeggio.app
```

`build-app.sh` needs a stable signing identity for Keychain access and updater trust. The current preview path uses the configured Apple Development identity. A production release requires Developer ID signing, hardened runtime, a secure timestamp, accepted notarization and a stapled ticket. Those production credentials and external acceptance receipts are not available yet.

Release builds also produce `dist/Soulseek-Arpeggio-x.y.z.zip`. For example, preview commands are `bash scripts/release.sh prepare preview FULL_PUBLIC_MAIN_SHA` and then `bash scripts/release.sh publish preview FULL_PUBLIC_MAIN_SHA [notes-file]`. Production uses the same two actions with `production` as the mode. `prepare` tests and builds/signs the candidate once. Verify and test that exact archive. `publish` checks the existing artifact and acceptance receipts, then uploads the same archive bytes without rebuilding. Both stages require a clean source tree and exact target SHA on the actual public repository's `main`; production additionally requires owner-provided notarization and exact-artifact acceptance receipts. See [release notes and distribution requirements](docs/RELEASE-0.6.md). Versions follow [semantic versioning](https://semver.org).

## Where things live

| What | Where |
|---|---|
| Downloads | `~/Downloads/Arpeggio/<album>/<file>` by default. Settings > Transfers can add per-user folders or keep the sharer's full path. |
| Unfinished downloads | A visible `Incomplete` folder inside the download folder, with readable names such as `Song [1a2b3c4d5e6f7a8b].flac.partial`. Files move into place only when every byte has arrived, and the folder disappears once nothing is unfinished. Partial files from the older hidden `.arpeggio-incomplete` folder move there automatically. `.partial` files are never shared. |
| Previews | `~/Library/Caches/tn.ashref.arpeggio/Previews`. Cleared when you stop listening, at launch and at quit. |
| App data | `~/Library/Application Support/Arpeggio/arpeggio.sqlite` |
| Password | macOS Keychain, only if you choose to remember it |

## Privacy and safety

- The Soulseek protocol sends your password to the server without encryption. Use a password you don't use anywhere else.
- Your Soulseek username and public IP address are exposed through ordinary network activity. Use Copy Report only after reviewing its redacted output. Don't share raw diagnostics, which may contain identifying details.
- Only folders you choose are shared. Hidden files and symbolic links are never shared, and trusted-only folders are visible only to people you mark as trusted.
- Remote paths are checked before anything touches the disk. Traversal, unsafe names, symbolic link escapes, oversized files and malformed messages are rejected.
- Soulseek has no checksums, so a finished download only proves the byte count matched. Don't run executables from strangers.

## Architecture

| Module | Role |
|---|---|
| `SoulseekCore` | Wire format, zlib, TCP framing, server login, peer, file and distributed connections |
| `TransferEngine` | Download and upload queues, slots, speed limits, retries, previews and safe file placement |
| `ShareIndexer` | Indexes shared folders in the background and watches them for changes |
| `Persistence` | SQLite records and Keychain access |
| `ArpeggioServices` | App state and coordination: search, sharing, playback, presence, statistics, port mapping, updates |
| `Arpeggio` | SwiftUI windows, menu bar extra, settings and commands |

The logo is the arpeggio sign from sheet music beside a three-note chord. It is defined once in `Sources/Arpeggio/ArpeggioMark.swift`; the app icon (`scripts/icon`), the Arpeggio menu bar style and the in-app logo are all drawn from it. The presence bird is a pixel grid in `docs/bird/`, embedded in `Sources/Arpeggio/BirdMark.swift`.

The only dependencies are Apple frameworks plus the system SQLite and zlib. Protocol notes and references are in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Developer tools

- `swift run ArpeggioFixture` starts a local Soulseek-compatible server with a test peer sharing generated audio. Point Arpeggio at the printed port with an isolated profile (`ARPEGGIO_DATA_DIRECTORY=/tmp/arpeggio-test`).
- `swift run ArpeggioLive --help` is a command-line driver for checking behavior against the real network with your own account.
- `scripts/native-qa.swift` drives the app through the accessibility APIs for UI checks.

## License

MIT. Arpeggio is an independent implementation and is not affiliated with or endorsed by Soulseek. Protocol research drew on the public documentation of Nicotine+, Soulseek.NET and slskd; no code from those projects is included.
