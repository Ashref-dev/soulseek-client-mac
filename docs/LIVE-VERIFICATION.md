# Authorized live-network verification

The owner supplied an account and authorized live debugging. No credentials are recorded here, passed to research workers, stored in source, or committed.

## Observed results

- `server.slsknet.org:2242` resolved and accepted TCP connections.
- Authentication with client identifier 177.1 was accepted by the public server.
- The original connection refusal was caused by a persisted `127.0.0.1:2242` test endpoint, not an invalid account or unavailable public server.
- Successive global searches returned 1,020, 2,341, and 930 real peer results.
- A real user library returned 405 folders and 2,847 files.
- Independent-peer downloads completed at exactly 880 and 7,010,506 expected bytes.
- An independent aioslsk 1.6.4 client authenticated separately, browsed the native client's original test share, and downloaded exactly 70 expected bytes. The peer connection used an explicit same-Mac route; this verifies cross-client control/file protocol interoperability, not external router mapping.
- A self-addressed private message returned through the server and was persisted/acknowledged without unsolicited test messages to other users.
- The server returned hundreds of public rooms; no public-room message spam was used for testing.

## Search stability and presentation

- Results now default to an expandable user → full folder path → track hierarchy. Equal album basenames from different users or parent paths never merge.
- Detached preparation work propagates cancellation, checks ownership before publication, and retires stopped/replaced foreground tokens.
- Main-actor result admission stops at capacity instead of traversing discarded replies indefinitely. Publication is batched at 250 ms.
- Outgoing peer startup is bounded to 32 concurrent dials and is tracked for disconnect cancellation.
- Stress fixtures cover 50,000 results balanced across users, a single 50,000-track folder, and one user with 50,000 folders.
- Final native broad-search checks returned 16,078 results from 59 users while staying connected. User/folder expansion, filtering to an empty state, clearing filters, resizing and section navigation worked. After settling, observed CPU was 0.1% and resident memory about 258 MB on this Mac; these are observations, not universal performance guarantees.
- After the last UI fixes, a fresh signed build returned 1,842 results from 25 users followed by 13,630 broad-search results from 38 users while connected. The same interactions passed; settling CPU was 0.3% and resident memory about 233 MB. Independent visual review accepted five fresh states, including verified 1240×837 and 1040×700 window sizes. The narrower capture is not proof of every supported size.
- Result batches are coalesced while detached preparation finishes, rather than continually cancelling count-driven rebuilds. Query/filter changes still cancel obsolete work.
- An automation-only disappearance was traced to physical-keycode Command-A becoming Command-Q on ABC-AZERTY. The native QA helper now sends explicit shortcut characters and keeps search focus for submission. The process exited normally; this was not evidence of a product crash.
- No native crash report was found for the owner's reported forced-close event. A separately reproduced UI hang was sampled: the main thread was blocked in `SecItemCopyMatching` during sign-in-sheet presentation. Credential lookup/save now runs off the UI thread, and automatic lookup disallows authentication UI.

## Compatibility fixes

- Legacy direction-0 download requests enter the authorized upload queue rather than receiving a misleading `Queued` reply with no queue entry.
- Repeated offers cannot overwrite an already-accepted download token.
- Duplicate remote folder sections merge distinct files rather than silently losing earlier entries.
- Larger remote catalogs use explicit bounded decode budgets while small/default decoder budget regression tests remain intact.
- Requested large peer bodies are admitted before allocation, share a 256 MiB in-flight receive allowance, and have an absolute 30-second body deadline. This is not a limit on total decoded/cached memory. Repeated folder merging is incremental; 100,000 repeated sections with duplicate entries decoded in about 0.8 seconds in the regression run.
- Outgoing browse/folder replies omit files beyond the supported 16 GiB limit rather than hiding the entire remaining library.
- Delayed credential lookup cannot undo Disconnect, apply another account's credentials, or overwrite an edited sign-in password.
- Protocol initialization announces branch root and level, and username validation follows the public server's 30-character printable-ASCII contract.

## Remaining coverage

Extended outage/recovery, additional independent implementations, router mappings, very large remote catalogs beyond the configured budgets, and full VoiceOver traversal are not implied by these checks. Public accounts must be used with the owner's permission; do not automate random account creation.

Some broad-search runs observed server connection closures; manual sign-in recovered, and subsequent search runs stayed connected. An extended automatic-recovery soak was not performed.
