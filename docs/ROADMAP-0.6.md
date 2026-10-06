# 0.6 release gates

## Connectivity and uploads

The diagnostics shown during investigation describe outbound peer failures and established peer connections closing. They do not establish whether the local listening port is reachable from the internet.

Arpeggio was observed listening on TCP 2234 with an established Soulseek server connection. An external check made after the app was closed returned CLOSED. That result cannot diagnose the router or an upload failure while the app is running. SoulseekQt used different listening ports, 61147 and 61148; successful uploads there do not prove that 2234 is forwarded.

The new user-initiated external check uses `https://www.slsknet.org/porttest.php?port=<PORT>`, the endpoint used by Nicotine+. It asks for confirmation, sends no account credentials, refuses redirects, and limits the response to 128 KiB and 15 seconds. Unexpected responses are unavailable, never automatically classified as closed. OPEN establishes TCP access from that checker at that time, not a completed Soulseek transfer or matching VPN route.

Before 0.6:

- Check externally while Arpeggio is connected and owns its listener.
- Confirm that indexing completes and the public share count is nonzero.
- Have an independent Nicotine+ or SoulseekQt client browse and download a small original file from Arpeggio across a different network. Compare exact bytes.
- Exercise direct and callback transfers, queueing, refusal, pause/resume, reconnect and offline peers.

Two new isolated tests explicitly exercise direct file transfers and forced server-mediated file callbacks with 300,000 exact bytes, including search, browse and metadata. They disprove the suspected callback-token reversal in those tested paths. They do not replace independent-client or internet validation.

## Stabilization implemented

- Unchanged Settings saves during an active scan no longer queue duplicate scans.
- Filesystem invalidations coalesce, without cancelling the caller that owns an active rescan. Exclusion changes made during a scan are applied by the follow-up scan.
- Share queries normalize each configured root once, rather than once per examined file.
- A persisted metadata-hint cache avoids reopening unchanged audio files after relaunch. Hints require a freshly enumerated matching source URL, path, size and non-nil modification time. Hints alone are never advertised shares or upload authorization.
- Metadata extraction runs sequentially at utility priority outside the index actor. Query handling can continue while a read is pending.
- Sharing status distinguishes no folders, pending indexing, active indexing, unreadable/empty folders and ready shares.

These changes eliminate reproduced unnecessary work. They do not prove the exact cause of the observed 102.2% CPU use. The owner closed the process before a stack sample could be captured. A genuinely cold scan still performs metadata reads before publishing its completed index, and a synchronous native decoder cannot be forcibly interrupted by task cancellation.

## Required reliability work

| Risk found in source review | Release gate |
|---|---|
| Cancel, enqueue the same file again, then resume the old row can assign two writers to the same deterministic partial path | Enforce one live partial-file owner on enqueue, resume and restore; test exact final bytes |
| Failed settings decoding can leave defaults that shutdown writes over the original record | Non-writing recovery state; malformed-record tests preserve original settings |
| The default 10,000-record restore limit can omit older queued/paused transfers behind newer completed history | Restore all nonterminal work independently of bounded history |
| Lifetime counters and transfer checkpoints are persisted separately | Durable replayable accounting; crash, failed-save and complete-then-clear tests prove no loss or duplication |
| The updater does not check target OS/CPU before replacing the bundle | Reject incompatible builds without modifying the installed app; retain a recoverable previous bundle |

These are review-supported failure paths, not all reproduced runtime failures. Each needs a failing regression before implementation. Keep improvements in separate changes rather than combining the entire release into one rewrite.

## Public distribution

The inspected 0.5.4 artifact had a valid Apple Development signature, no hardened runtime, no stapled notarization ticket, and failed Gatekeeper assessment. A valid signature alone does not make a downloaded build production-ready.

Before a public production label:

1. Decide the supported OS/CPU matrix. The current binary is arm64 and requires macOS 27. Changing the plist cannot make it run on an older OS or Intel.
2. Use an explicitly configured Developer ID Application certificate, hardened runtime and secure timestamp.
3. Notarize, staple, archive the stapled app, and test that exact quarantined download on a clean supported Mac.
4. Plan signing-identity migration. The existing updater pins the installed app's designated requirement; an ordinary switch from Apple Development to Developer ID will be rejected. Choose an explicitly tested bridge or a clearly documented manual replacement that preserves data.
5. Publish only after clean-install and upgrade tests pass. Account/certificate provisioning and clean-machine acceptance cannot be manufactured by unit tests.

## Performance budgets

Record cold and warm scans separately and test meaningful workloads:

- 50,000 search results: combined filter, sort and hierarchy publication, cancellation and peak memory.
- 100,000 shared files: cold scan, unchanged rescan, metadata-open count, query latency and main-actor responsiveness.
- 1,000 transfers: batch enqueue, progress updates, persistence and memory.
- Long session: idle CPU, incoming-search load, reconnect cycles and repeated preview changes.

Use machine-specific baselines for noisy timings, plus deterministic work-count bounds in ordinary tests. Existing optimized tests measured approximately 28 ms for decoding 10,000 results, 179 ms for the 50,000-row hierarchy case, and 1.61 s for the large-library codec case on the development Mac. These timings are not full-app UI or memory measurements.

## Operational UX

- Timestamped, categorized diagnostics should distinguish routine peer closure from failed requests and server failure.
- Provide a redacted support report instead of asking users to post raw peer names, paths and addresses.
- Show global pause state directly in Downloads and Uploads, with a Resume action and clear local-slot versus remote-queue reasons.
- Consolidate connection troubleshooting and make reconnect timing visible.
- Reduce player height on small windows and complete keyboard, VoiceOver and media-key coverage.

Preserve the existing violet identity and native controls. A cosmetic redesign is not a substitute for these gates.
