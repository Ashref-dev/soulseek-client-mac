# Arpeggio 0.6.0-rc.1 development preview

**Candidate notes for the 0.6.0-rc.1 public development prerelease.** The software gates and available automated QA passed, but the release is not yet published. The inspected candidate was built from an uncommitted source tree and cannot be published. Prepare a fresh archive from the final clean committed SHA on the actual public `main`, then publish those exact bytes. Final user UI acceptance and external production distribution receipts remain outstanding.

## What's in 0.6

- Three separate transfer-list layouts for downloads and uploads: Flat, Folders, and Users > Folders > Files. Each direction remembers its own layout.
- Remove selected transfers from the list without deleting downloaded files, upload sources or partial downloads. Removing an active transfer requires confirmation to stop it. Lifetime totals remain intact.
- A distinct purple bird presence control for Available and Away. The artwork is original and does not replace Arpeggio's existing app or menu-bar mark.
- Typed network diagnostics, a redacted Copy Report and visible reconnect timing.
- Network settings distinguish the configured listening port from the port actually bound by the current connection. Onboarding explains public metadata, the unencrypted legacy password protocol and conditional router setup.
- Compact player layout and playback commands, event-driven search updates, safer partial-file ownership, durable transfer accounting and settings recovery.
- New profiles use TCP listening port 61147. Existing saved ports are preserved.

Verification: the latest plain full suite passed **313 tests in 52 suites after 19.740 seconds**. This run was performed by the batch-reentrancy correction worker and recorded in `.omo/evidence/batch-reentrancy-final-06.md`; it includes a seven-case parameterized enqueue regression. The previous 312-test run is historical. F3's earlier candidate build and 312-test log predate this final correction. F3 separately recorded 18 distribution-stage cases and 15 release-orchestration cases passing. Positive production orchestration fixtures are stubs, not real production receipts. Core separately passed 13 targeted tests; visual/UI separately passed 83 targeted tests and 10 opt-in performance tests. Do not add the subsets to imply F3 ran all tests. F1 software compliance and F4 documentation honesty were approved before this last correction. User live UI acceptance is still required.

## Port and router setup

If you used SoulseekQt, set Arpeggio to the same listening port that client used. In the router, create a TCP Port Forwarding or Virtual Server rule for that port, directed to the Mac's LAN IP address. Router screens use different names. Keep the Mac address stable if possible. Arpeggio does not change a saved port or create an extra obfuscated port. Only one process can listen on a port at a time. Don't run another Soulseek client on the same account and same port while Arpeggio is using it.

## Recorded synthetic performance observations

These are observations from one Apple M4 Pro running macOS 27.0.1, not universal targets or promises:

- 100,000 generated files, of which 25,000 were audio files, using an injected metadata reader: cold 3.51 s, warm 3.22 s, restored cache 3.29 s. This reader is not the native codec; this workload does not prove audible preview decoding.
- 1,000 synthetic transfers: enqueue 0.21 s, one transaction and one publication.
- 50,000 search results: 0.367 s, 10 submitted snapshots, 2 started builds and 8 coalesced.
- Latest 10-cycle SDK-driver run: 8.26 s, peak resident memory 32.7 MB, idle CPU 0.0012 s (fraction 0.00022), and median cycle 0.288 s. This runs two AppModel profiles and a loopback mock server in one process. It is not a signed GUI-app run or a general memory-use guarantee. An earlier 15-cycle run measured 12.68 s and 0.026% idle CPU.

The file workload uses an injected metadata reader returning fixed values, not the native audio codec. No audible native preview decoding is established by these measurements. The driver used isolated synthetic profiles and a loopback mock server, not an owner account or real internet peer. Full details are in `.omo/evidence/visual-06.md` and `.omo/evidence/final-qa-06.md`. Transfer accounting intentionally retains one on-disk cursor per lifetime transfer UUID and looks it up by primary key. These records are unbounded on disk; do not infer that all application state is bounded.

## Important limitations

- This is a public development preview, not a production-ready macOS release. It uses pinned Apple Development certificate SHA-1 `52DFDB3AE69296BA6E137CDC8275FD0CF314DA38`, not Developer ID. The preview is not notarized. macOS may block it, and a valid development signature is not a Gatekeeper approval. If macOS offers it, use **System Settings > Privacy & Security > Open Anyway**. Do not advise Control-click > Open as a workaround.
- Download from the exact `https://github.com/Ashref-dev/soulseek-client-mac/releases/tag/v0.6.0-rc.1` GitHub prerelease page if and when it is published. The stable latest-release link and the updater do not provide prereleases. Do not use an API or latest URL to find this preview.
- Older stable clients may not offer this prerelease in their updater. Candidate designated-requirement compatibility with the installed 0.5.5 build was verified, but an actual in-app update was not run. Install the preview manually from its release page instead. Keep the existing app data and credentials.
- Current platform target is Apple Silicon with macOS 27 or later. Intel and older macOS support are not claimed.
- No clean-Mac quarantined install/upgrade receipt or independent-client network-transfer receipt is available. Do not infer either from automated tests.
- Automated renders and tests are not final native UI acceptance. The user must review the live menus, Settings, onboarding, dark mode, NSMenu bird, removal confirmation, keyboard/media behavior inside the signed app, VoiceOver, Reduce Motion and settings deep links.
- Soulseek's legacy protocol does not encrypt the password. Use a unique password. Usernames and IP addresses are public network metadata. Share only folders you intend to expose, and review the redacted report before sharing it.

## Prepare and publish

The script interface is:

```sh
bash scripts/release.sh prepare preview FULL_PUBLIC_MAIN_SHA
bash scripts/release.sh publish preview FULL_PUBLIC_MAIN_SHA [notes-file]
```

Production uses the same actions with `production` instead of `preview`, but is unavailable until every production prerequisite and receipt exists. `prepare` tests, builds, signs and verifies a candidate from the exact clean source revision. Review and exercise that exact archive and record its digest. `publish` validates the prepared archive and, for production, its matching acceptance receipts; it does not rebuild, resign, resubmit notarization or restaple. It verifies and uploads unchanged archive bytes. Both actions recheck the full source SHA, clean tree, signed artifact source/version and that the target is the exact `main` SHA in the actual public repository, `Ashref-dev/soulseek-client-mac`. The existing version tag must not point elsewhere.

The current candidate build/signing and local verification are not proof of publication. The public 0.6 release has not been created. F3 confirmed that its inspected archive came from an uncommitted tree, so the source SHA and digests in that evidence are not publication provenance and must not be reused.

## Publication and provenance

For preview publication, identify the exact pushed source SHA, Apple Development signing identity, `0.6.0-rc.1` release version and SHA-256 digest of the newly prepared archive. The bundle short version remains numeric `0.6.0`; the signed `ArpeggioReleaseVersion` carries the prerelease version. The uploaded archive must be the same reviewed and accepted candidate bytes. Do not describe it as published until the release exists and the uploaded digest is confirmed.

## Production is a separate gate

A stable production release needs owner-provisioned Developer ID signing, hardened runtime and timestamp, accepted notarization with a stapled ticket, successful Gatekeeper assessment of the exact artifact, a clean quarantined install and upgrade, and independent network transfer proof. Source SHA, signing identity, designated requirement and binary digest must match. None of the missing owner credentials or external receipts can be replaced by a passing unit suite. Updater rollback also has an explicit failure mode: if moving the rejected app or restoring/verifying the old app fails, it reports `rollback-incomplete` and retains copies. Do not promise restoration is guaranteed in every filesystem failure. Until every gate and final review passes, keep this release a clearly labeled development preview and do not claim 0.6 production readiness.

## Still required before final release review

- Final release review must bind source, security and exact artifact checks to the final clean public SHA. Previous candidate digests from an uncommitted source tree are historical and must not be reused as final provenance.
- F1 and F4 approved the integrated source before the final batch-reentrancy correction. That correction has a native failing regression and a subsequent 313-test full-suite pass. The earlier F3 artifact does not include that correction. Final clean-SHA preparation and artifact verification are still required.
- The user must perform and accept final manual native UI review. Automated geometry checks and generated screenshots are not that acceptance.
- No Developer ID certificate, accepted production notary ticket, stapled production artifact, clean quarantined Mac install/upgrade receipt, or independent-client internet transfer receipt is currently available. Production remains blocked.
- Automated preview/render tests do not establish audible native audio decoding. No audible preview claim is made from the injected-reader performance workload.
