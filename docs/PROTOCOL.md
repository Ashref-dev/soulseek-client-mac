# Protocol research and interoperability

Researched 2026-10-01. Soulseek is a proprietary protocol with a community-maintained, reverse-engineered specification, not a guaranteed official contract.

References:

- [Nicotine+ protocol](https://github.com/nicotine-plus/nicotine-plus/blob/31deddf9ddf212fadf899f76b8a9b600ee91a3dd/doc/SLSKPROTOCOL.md)
- [Nicotine+ serializers](https://github.com/nicotine-plus/nicotine-plus/blob/31deddf9ddf212fadf899f76b8a9b600ee91a3dd/pynicotine/slskmessages.py)
- [Soulseek.NET protocol](https://github.com/jpdillingham/Soulseek.NET/blob/e96485f5e336ab21c61db4a205e0ed4e515f16da/docs/Soulseek%20Protocol%20Documentation.html)
- [slskd configuration](https://github.com/slskd/slskd/blob/072a8338e92d154772db678cf5f182d9c6150fc3/docs/config.md)

Nicotine+ is GPL-3.0-or-later; Soulseek.NET is GPL-3.0; slskd is AGPL-3.0. This repository independently implements wire contracts in Swift; no implementation source is vendored or translated. System libraries: Network, CryptoKit, Security, SQLite, zlib. The app is not affiliated with Soulseek.

## Wire contracts

Little-endian integers; strings are uint32 byte count then UTF-8 bytes, with Latin-1 decoding for legacy peers. Server and P connections use uint32 length + uint32 code. Init and D connections use uint32 length + uint8 code. Length excludes the length field itself.

Server `server.slsknet.org:2242`. Login 1: username, password, experimental-client major 177, lowercase MD5(username + password), project minor 1. Password is transmitted by the legacy protocol without TLS; Keychain protects local storage, not the wire. Port registration 2 sends uint32. Search 26 and wishlist 103: token/query; wishlist timing comes from 104. User search 42: username/token/query. Room search 120, not obsolete 25. The experimental version avoids impersonating Nicotine+ or SoulseekQt. Server policy prohibits automated randomly generated accounts; live verification must use an account supplied by its owner.

Peer address 3; indirect connect 18: token/user/type. P, F, D are messaging, file and distributed connections. Direct init 1: local user/type/token zero. Callback init 0: rendezvous token. Neither server nor callback mechanism relays files; if both users cannot accept incoming connections, connectivity fails.

Arpeggio uses direct-first setup and requests callback only after direct failure. The documented legacy order remains interoperable and avoids a direct/callback race that discarded an initial reply in the two-client integration test. Modern clients may request both immediately; duplicate P connections use a deterministic initiator preference.

P9 search results and P5 browse responses use zlib-wrapped DEFLATE (not Apple's raw Compression ZLIB encoder). File tuples: byte 1, path, uint64 size, extension, attribute count, uint32 key/value pairs. Attributes: bitrate 0, duration 1, VBR 2, sample rate 4, bit depth 5. Search suffix: free slot, speed, queue length, optional unknown/private results. Browse paths carry directory separately from basename.

P43 queues a file; uploader sends P40 direction 1/token/path/size; recipient sends P41 token/allowed. Uploader opens F and sends raw uint32 token; downloader sends raw uint64 resume offset. File bytes are unframed. Downloader closes on exact expected length. There is no protocol checksum, so size verification cannot certify source-content integrity. Legacy direction 0 requests receive `Queued` and enter the regular queue. P44/P51 exchange queue position; P46 indicates upload failure; P50 rejects a queued request.

Private messages 22: recipient/text outbound; id/timestamp/sender/text/new inbound. Acknowledge every incoming id via 23. Room join 14, leave 15, message 13, room list 64. No standard typing notification exists.

Distributed: HaveNoParent 71; AcceptChildren 100; parent candidates 102. D3: identifier 49/user/token/query; D4 level, D5 root. Server 93 wraps a one-byte distributed code. Unwrap before dispatching; old Qt versions forwarded wrappers incorrectly. Wishlist searches must honor server timing, not aggressively repeat.

## Safety policy

Bound frames, decompression, strings, counts and result collections. Reject traversal components and unsafe local names. Never map incoming virtual paths directly to arbitrary disk paths. Only explicitly indexed regular files can be uploaded, and trusted-only shares require authorization at browse, search and transfer boundaries. Skip symlinks and hidden files. Do not log passwords or raw login frames. Peer usernames are protocol identities, not cryptographically authenticated identities.

Very large browse responses exceeding configured memory bounds are rejected rather than risking unbounded allocation. Automatic router mapping and obfuscation are separate interoperability features, not a relay guarantee.
