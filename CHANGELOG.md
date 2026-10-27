# Changelog

## 0.3.8 — prompt FIFO settlement

Completed workers schedule the next eligible FIFO heads through the existing bounded, fair runtime scheduler. Queued events and results no longer wait a discovery interval after every fast commit. Per-room ordering, worker limits and retry delays remain intact; a stopped runtime cannot schedule more effects. Wire-compatible with SDK0.3.7, with no database migration or new dependency.

## 0.3.7 — device handoff without reconnect contention

Canonical room sockets now send `connection_replaced` before detaching a displaced connection. SDK0.3.6 yields automatic reconnection while retaining the room for explicit reclaim. Transient inputs on the displaced socket do not race the single writer's notification. Other authorization and IO failures still fail closed.

Browser selection reads no longer clear rejected cookies. A rejected current proof exposes its public binding ID with null account metadata, preserving explicit previous-account selection and preventing ordinary startup from creating an unintended replacement guest. Explicit new-guest recovery remains unchanged. No database migration or new dependency.

## 0.3.6 — explicit browser guest recovery

`auth/prepare?new=true` replaces an existing active browser proof only when authentication definitively rejects it. A valid proof, retained previous account and transfer candidate survive. Ordinary preparation and database failures never rotate a proof. This enables SDK0.3.5's explicit browser new-guest action after revocation; no schema change is required.

## 0.3.5 — account consent without an analytics adapter

Analytics consent remains available when optional delivery is not configured. The account store owns the revisioned choice and retained outbox purge; `Questmetry#enabled` delegates to that same transaction and delivery fence. The HTTP endpoint no longer rejects this account operation as `not_configured`. Event submission still requires an adapter. Wire-compatible with SDK0.3.4.

## 0.3.4 — composable listeners and ranking pages

- `Runtime.listen` serves a prebound listener without installing process signals. Shutdown closes admitted and pre-authentication sockets and joins admitted requests and workers within a bounded deadline. A timeout is an explicit failure, never permission to close storage still owned by unfinished work.
- Authenticated leaderboard pages include the player's own rank and best score outside the requested Top N. A trusted server reader can provide an application-defined public ranking projection through the same authentication and validation boundary. Existing leaderboard arrays remain unchanged.
- Optional client product events use an explicit UI-event allowlist, current consent revisions and the existing bounded Questmetry outbox, without creating gameplay operations. Authoritative result events remain server-only.

## 0.3.3 — long-poll presence

- Long-poll admission refreshes player activity once. Subsequent server-side checks preserve credential, membership and game authorization checks without renewing presence for a disconnected HTTP client. Ordinary snapshot requests still refresh activity. Wire-compatible with SDK 0.3.0.

## 0.3.2 — private settlement publication

- Analytics-only effect acknowledgement no longer advances an unrelated viewer's revision when its projection and visible metadata are unchanged. Effect receipts notify their actual recipients; clearing visible saving backpressure still notifies all members. Wire-compatible with SDK 0.3.0.

## 0.3.1 — final snapshot after late input

- A transient input arriving after room completion leaves the result unchanged and sends a fresh authorised final snapshot. It no longer closes a valid connection merely because the client's previous snapshot was active. Lost epochs and authorization failures still fail closed. Compatible with SDK 0.3.0.

## 0.3.0 — shared account and service runtime preview

Pure AccountRules/AccountTransaction with sorted participant locking, durable public/server effect receipts, terminal summaries and bounded HTTP recovery. Shared mode admission, private projection checks, FIFO effects/backpressure and Runtime lifecycle/drain/health replace consumer service loops. Namespaced cookies, exact browser selection retries, deletion proof/status/tombstones, mutes/reports and privacy-revision-aware Questmetry delivery. Development API changes require coordinated server/SDK updates; PostgreSQL-only, RAM sessions and single-instance limits remain deliberate.

## 0.2.0 — transport adoption preview

Reusable bounded socket engine and process-local limiter, shared by canonical and compatible wire adapters. Adds account/global admission, strict bounded frame assembly, ordered reliable queues and account fanout. Canonical admission no longer invalidates a room connection on a rejected handshake; idle peers continue receiving snapshots. Public canonical wire shapes, PostgreSQL schema and credentials are unchanged.

## 0.1.0 — development preview

Initial Crystal framework: permanent guest identity and owner-confirmed transfers; RAM sessions and four join flows; HTTP/long-poll/WebSocket; persistent results, leaderboards/outcome ratings; optional chat history and Questmetry; dictionary name generation. Initial public API is experimental.
