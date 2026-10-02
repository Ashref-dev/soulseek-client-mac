# Arpeggio implementation plan

1. Establish standalone Swift modules, binary codecs, bounded framing and TCP ownership.
2. Connect/login, register listening port, negotiate direct and callback peers. Prove search/download vertical slice before expanding presentation.
3. Persist settings, transfers, users, wishlist and conversations in migration-versioned SQLite; store passwords only in Keychain.
4. Index public/trusted folders off the main actor, serve browse/search requests and queued uploads.
5. Present native search, transfers, browse, social and settings in one sidebar. Native tables and controls, glass only in navigation.
6. Exercise protocol fixtures, interrupted file writes, traversal, restoration, large-result processing and the running native app.

## Ownership

`SoulseekCore`: wire format, TCP sessions, peer negotiation and network events.
`Persistence`: SQLite records and Keychain.
`ShareIndexer`: actor-owned filesystem catalog.
`TransferEngine`: actor-owned queues, safe destinations and file streams.
`Sources/ApplicationServices` (module `ArpeggioServices`): main-actor presentation state; coordinates background actors, batches search results. The module name avoids colliding with Apple's ApplicationServices framework.
`Arpeggio`: SwiftUI scenes, commands and AppKit integration only where useful.

## Product shape

Library/pro-tool hybrid. One primary sidebar: Search, Wishlist, Browse, Downloads, Uploads, Messages, Rooms, Users, Shared Files. Toolbar actions are contextual; settings live in the standard Settings scene. Secondary details live in content columns, not a second navigation sidebar.

Standard copy/edit/window shortcuts remain system-owned. Search uses Command-F, global navigation Command-K, downloads Command-2, settings Command-comma. Controls use semantic labels; native lists/tables provide keyboard and VoiceOver behavior. Motion is not required for any operation.
