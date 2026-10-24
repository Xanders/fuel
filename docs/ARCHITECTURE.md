# Architecture

| Owner | Responsibility |
|---|---|
| Game rules | Legal actions, turns/phases, RNG, ticks, private projections, score/outcome/progress calculation |
| Room | Member authorization, serial mutation, viewer revision, bounded receipts, connection generation, input sequence, frozen results |
| Sessions | Bounded room registry, codes, public listing, matching and trusted parties |
| Store | PostgreSQL identity, device transfer, progress, result receipts, leaderboard, ratings, rate counters, optional chat and analytics outbox |
| Handler | HTTP/long-poll/WebSocket boundary, cookie/header authentication, Origin checks, input bounds and revalidation |
| SocketServer | Shared bounded frames, peer admission, ordered delivery and cleanup for canonical and compatible wire adapters; see [transport contracts](TRANSPORT.md) |
| Optional Questmetry | Allowlisted product events, pseudonyms, transactional enqueue and bounded retry |
| Dart / Flutter / Flame | Networking and recovery / platform lifecycle / presentation |

## Storage contract

All active gameplay is RAM-only for every mode. No snapshot, command journal or checkpoint restores a session after restart. PostgreSQL stores permanent identity/bindings, progress, result receipts, scores, aggregate-rating source results, technical transfer state/rate counters, configured chat and optional analytics outbox. It does not store object positions or the current turn.

A session has a random process-local ID and epoch. An unknown old session returns `session_lost`. A connection generation fences replaced sockets. Input sequence acknowledges transient inputs; it is not a persistent reward receipt.

Commands are scoped to actor + room epoch + ID. The same ID/revision/payload returns the original reply while retained (256 receipts per room). A changed payload conflicts. After receipt eviction, the old expected viewer revision rejects the old action, including after leave/rejoin: a room retains a monotonic actor high-water mark for up to 1,024 distinct admissions. Do not change the ID or revision to retry an uncertain intent.

Game code receives cloned JSON so failed rule validation cannot partially mutate stored state. All mutation of one room is serialized. Independent rooms do not share a gameplay lock. Game rules and projections must be fast, nonblocking and free of external side effects.

## Resource limits

Defaults: 1,000 rooms; eight simultaneous memberships per account created through the registry; 2,000 waiting ticket entries and 2,000 retained matched outcomes; five-minute ticket/outcome/cancellation horizon and invite codes; six-hour room TTL; 256 long polls, one per binding; 128 sockets; 64 KiB HTTP body; 16 KiB assembled WebSocket message. Empty settled rooms are reclaimed promptly; unsaved results are retained. A socket uses a 4 KiB receive buffer and one serial writer with a three-second write deadline. Full snapshots coalesce naturally at the writer; reliable events require resync on gaps.

Chat defaults: 2,000 RAM channels, 50 messages per channel, 24-hour TTL, 2,000 input bytes per message. Persistent private/guild history is trimmed per channel and by TTL cleanup. Configure application admission and total PostgreSQL storage capacity as well as these limits.

Guest creation is capped before insertion (default one million permanent accounts per namespace, plus per-source/global issuance budgets). Existing guests are never evicted to create space. Database failures return unavailable; there is no empty file-store fallback.

## Membership and matching

Public join rechecks listing and room capacity. Code/link join uses the same member admission. Manual rooms support PvP/co-op capacities, readiness and late-join policy. FIFO automatch pairs compatible modes; trusted `match_party` admits parties as indivisible units when they fill the requested capacity. Game code must validate each party member's consent before calling that library API; public clients cannot submit arbitrary account lists.

A matched ticket wins over subsequent cancellation and returns the same room during the retained horizon. Waiting cancellation or account deletion removes the whole waiting party. An already-full party starts immediately; multiple smaller parties are packed in FIFO order without splitting them. One account cannot queue twice across modes. After a room ends or the player leaves, a new ticket generation can start while the old outcome remains retryable. Leave/disconnect/reconnect remain distinct; merely losing a socket does not delete a membership.

Ticks begin after the first accepted action/input or after all capacity slots are ready. A waiting lobby is not started by a no-op global scheduler tick.

## Fixed decisions and trade-offs

PostgreSQL-only and RAM-only active sessions are intentional limits, not missing database adapters. This release supports one backend instance. Sharing PostgreSQL does not make session routing, matching, global chat or RAM budgets multi-instance safe.

Multi-instance support will require hard player-to-instance database stickiness and routing. It will still not allow cross-instance sessions or players to interact across instances. Scale-down requires explicit player movement/draining, and scale-up will not automatically unload old instances. Those are independently tracked in the roadmap.
