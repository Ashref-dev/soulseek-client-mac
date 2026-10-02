# Verification record

Environment: macOS 27, Xcode 27, Swift 6.4, Apple Silicon.

- `swift test`: 29 tests passed, including real loopback TCP peer exchanges, forced callback connections, exact file bytes, pause/relaunch/resume, account ownership, cancellation, packet bounds, traversal, schema versions and recursive file watching.
- Production SwiftPM build and ad-hoc-signed `dist/Arpeggio.app`: succeeded without compiler warnings.
- 10,000-result codec test completed in approximately 70 ms on the development Mac. This is a codec measurement, not a universal UI frame-rate claim.
- Actual native app inspection: nine offline sections in light and dark mode, five Settings tabs in both modes, login and command palette in both modes, and the minimum-width light Search window.
- Two independent read-only visual reviews inspected all 33 specified captures and returned PASS for the offline visual gate, with no blocking layout findings.

Generated PNG captures are retained locally under `docs/evidence/` and ignored by Git. They contain isolated test state, not production conversations or credentials. Populated network screens, VoiceOver traversal, system permission flows, and public-account interoperability remain on the joint-test checklist.

No real Soulseek account was used or created during development. Fixture credentials are public loopback-only values. Build products, databases, logs, agent metadata and environment files are excluded from source publication.
