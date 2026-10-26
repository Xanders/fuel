# Changelog

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
