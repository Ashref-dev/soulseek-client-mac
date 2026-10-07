# Arpeggio 0.6 release gates

## Status summary

F1 software compliance and F4 documentation honesty were approved against the integrated source before the final batch-reentrancy correction. F2 found an enqueue reentrancy defect, which was fixed and covered by a native failing regression followed by targeted and full-suite green runs. The latest plain full `swift test` was run by that correction's worker and was not run by F3. F3's signed preview candidate predates that correction and came from an uncommitted tree, so it is **not publishable**. User manual UI acceptance and external distribution receipts remain open. Bind final review and artifact preparation to the final clean committed source.

## Software acceptance gates

| Gate | Verified behavior | Status and evidence |
|---|---|---|
| Listener and router guidance | New profiles default to TCP 61147. Saved ports remain unchanged. Guidance covers the former SoulseekQt listening port, a matching TCP rule to the Mac LAN IP, Port Forwarding or Virtual Server naming, same-port client conflicts and no extra obfuscated port. Network settings distinguish the configured port from the actual bound listener after settings edits. Onboarding says manual rules may still fail due to firewalls, VPN, upstream NAT or router behavior. | Passed targeted listener/onboarding tests and full suite. Physical router and public reachability were not tested. |
| Transfer layouts and removal | Downloads and uploads have independent Flat, Folders and Users > Folders > Files preferences, expandable groups and loose-file handling. Remove from List is distinct from deleting files. Active transfers require confirmation to stop. Normal destinations, partial downloads, upload sources and lifetime totals are retained. | Passed grouping, removal, durability tests and full suite. |
| Purple bird presence | Original vector bird indicates Available with spread wings and Away with folded wings; offline state is muted. App and menu-bar glyphs remain unchanged. | Passed synthetic rendering and accessibility tests. Live NSMenu check remains part of user UI review. |
| Network, diagnostics and reconnect | Network destination covers listener and connectivity settings. Typed diagnostic report exports allowlisted context without raw messages, identifiers, addresses, paths or credentials. Reconnect countdown, capped backoff and Retry Now are event-driven and guarded against stale/manual-offline attempts. | Passed 13 targeted core tests and full suite. No independent network validation. |
| Durability and recovery | Single ownership of partial writers, nonterminal restore beyond history caps, malformed-settings recovery without implicit overwrite, transactional replayable lifetime accounting, safe queued transfer removal, and batch-enqueue reentrancy across `await keep` are covered. Cursor retention is one record per lifetime transfer UUID and is intentionally unbounded on disk, accessed by primary key. | Passed targeted durability/failure-join/batch-reentrancy coverage and latest 313-test full suite. Batch worker ran the full suite. Abrupt termination can still lose bytes after the last coalesced checkpoint; no stronger guarantee is claimed. |
| Search, indexing and session behavior | Search preparation is event-driven, coalesces snapshots and rejects stale results. Workload and long-session drivers use synthetic profiles and loopback services. | Passed targeted tests and opt-in workload checks; measurements below are one-machine observations, not universal budgets. |
| Player, commands and onboarding | Compact player geometry, shortcuts, media-command routing, VoiceOver labels, privacy onboarding and conditional port guidance have automated checks. | Automated tests and selected synthetic renders passed. They do not substitute for final live UI acceptance. |
| Updater safety | Version/architecture checks, archive validation, startup receipt, rollback paths, signing trust and release-asset selection have regression coverage. If moving or restoring a rejected bundle fails, updater reports `rollback-incomplete` and retains copies; restoration is not guaranteed for every filesystem failure. | Passed targeted updater tests and release review. Actual in-app update over installed 0.5.5 was not run. |

## Integrated verification recorded

- Latest plain `swift test`: **313 tests in 52 suites passed after 19.740 seconds**, exit 0, run by the batch-reentrancy correction worker. The new parameterized test ran seven cases; the previous 312-test result is historical. F3's earlier 312-test log is not the latest result and its artifact predates the correction.
- Distribution stage tests: **18 cases passed**. Publication orchestration tests: **15 cases passed**. Positive production fixtures are stubs and are not real notarization or acceptance receipts.
- Core targeted verification: 13 tests. Visual/UI targeted verification: 83 tests. Opt-in performance tests: 10 passed. These subsets are not additional independent full-suite runs.
- F3 prepared and verified a fresh signed preview build for classification from the frozen but **uncommitted** tree. It verified arm64, minimum macOS 27, version metadata, exact pinned signing certificate, archive integrity and installed designated requirement. It is not an exact public-SHA release artifact.
- `spctl` rejected the unnotarized development preview, as expected. This is not a production Gatekeeper result. No production ticket was submitted or stapled.

## Synthetic performance observations

These values are machine-specific, measured on an Apple M4 Pro with macOS 27.0.1. They are not release-wide performance guarantees:

- 100,000 generated files, including 25,000 generated audio files, with an injected metadata reader returning fixed values: cold 3.51 s, warm 3.22 s, restored cache 3.29 s. The reader is not a native codec and does not prove audible preview decoding.
- 1,000 synthetic transfers: enqueue 0.21 s, one transaction and one publication.
- 50,000 search results: 0.367 s, 10 submitted snapshots, 2 started builds and 8 coalesced.
- Latest 10-cycle isolated SDK driver: 8.26 s duration, peak resident memory 32.7 MB, idle CPU 0.0012 s (fraction 0.00022), median cycle 0.288 s. This runs two AppModel profiles and a loopback mock server in one process, not the signed GUI app or audible playback. An earlier 15-cycle run measured 12.68 s and 0.026% idle CPU; the latest 10-cycle result supersedes it for current session figures.

Synthetic measurements and logs are documented in `.omo/evidence/visual-06.md` and `.omo/evidence/final-qa-06.md`. No owner account, database or real library was used. No independent internet peer was used.

## Preview and production status

The candidate is `0.6.0-rc.1` (`CFBundleShortVersionString` 0.6.0, build 11, custom `ArpeggioReleaseVersion` 0.6.0-rc.1), arm64 with minimum macOS 27. Its pinned Apple Development certificate SHA-1 is `52DFDB3AE69296BA6E137CDC8275FD0CF314DA38`. The candidate's designated requirement matches the currently installed 0.5.5 app's requirement. Its `spctl` rejection is expected for an unnotarized development preview.

The inspected archive and application came from source `b0ace58e5031407802ce7580e63577d6f0f72bbc` with `ArpeggioSourceTreeState=uncommitted`, and predate the final batch-reentrancy fix. Their digests are historical review evidence only and must never be used for publication. The public `v0.6.0-rc.1` release has not been created. Follow [release preparation and publication instructions](RELEASE-0.6.md) to prepare a new archive from the final clean, committed SHA present on the actual public `main`, then publish those exact bytes without rebuilding.

## Remaining gates

- [ ] User manually reviews and accepts the native UI: menus, Settings, onboarding, dark mode, real NSMenu bird, removal confirmations, keyboard and media keys inside the signed app, VoiceOver, Reduce Motion and settings deep links. Synthetic geometry/renders and automated tests are not user visual approval.
- [ ] For production only: owner-provisioned Developer ID Application certificate, hardened runtime, secure timestamp, accepted notarization, stapled ticket and successful Gatekeeper assessment of the exact artifact. None is currently available.
- [ ] For production only: clean-Mac quarantined install and upgrade receipt, and independent-client transfer proof over an independent network. Neither receipt exists.
- [ ] For any publication: finish commits and push the reviewed source; run `prepare` against the exact full public-main SHA; review and acceptance-test that candidate; pin its identity and digest; then run `publish` for the same SHA. Preview publication is authorized only as an explicitly labeled GitHub prerelease, never as production.
- [ ] Keep production blocked until every owner-controlled receipt and exact-artifact review is complete. Do not claim stable or production readiness from the passing automated suite.
