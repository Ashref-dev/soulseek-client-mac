# Verification record

Environment: macOS 27, Xcode 27, Swift 6.4, Apple Silicon.

- `swift test`: 48 tests passed, including real loopback TCP peer exchanges, forced callback connections, exact file bytes, pause/relaunch/resume, credential lookup ownership, account ownership, cancellation, packet bounds, shared receive reservations, traversal, schema versions and recursive file watching.
- Production SwiftPM build and ad-hoc-signed `dist/Arpeggio.app`: succeeded without compiler warnings.
- 10,000-result codec test completed in approximately 70 ms on the development Mac. This is a codec measurement, not a universal UI frame-rate claim.
- Actual native app inspection: nine offline sections in light and dark mode, five Settings tabs in both modes, login and command palette in both modes, and the minimum-width light Search window.
- Two independent read-only visual reviews inspected all 33 specified captures and returned PASS for the offline visual gate, with no blocking layout findings.
- Final grouped-search review inspected five fresh live states: collapsed folders, expanded tracks, a narrower window, filtered empty results and the connected-account sheet. Corrected resize evidence established actual 1240×837 and 1040×700 window bounds; independent review returned PASS without product or evidence blockers.

Generated PNG captures are retained locally under `docs/evidence/` and ignored by Git. Fixture captures contain isolated test state. Owner-authorized live search captures can contain third-party usernames and file paths and must not be published. VoiceOver traversal, system permission flows, additional peer versions and external NAT behavior remain on the joint-test checklist. See `docs/LIVE-VERIFICATION.md` for measured live interoperability and its limits.

Owner-authorized accounts were used for public-server login, search, browse, download, upload and messaging checks. Credentials are never included in source or captures. Fixture credentials are public loopback-only values. Build products, databases, logs, agent metadata and environment files are excluded from source publication.
