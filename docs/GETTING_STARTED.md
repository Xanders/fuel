# Getting started

Fuel is linked into your game's executable. PostgreSQL runs separately. Configure a dedicated database role and namespace per game/environment; the client cannot choose the namespace.

Requirements: Crystal 1.22.1, PostgreSQL 17 (validated), Docker for the supplied test workflow. The compiler compatibility range is deliberately narrow until another stable compiler has passed the suite.

1. Add Fuel to your shard and run `shards install`.
2. Implement `Fuel::Rules`; return fresh JSON state from `apply`. Validate phase, turn, ownership, quantities and legal actions in game rules. Never accept final scores or positions merely because a client sent them.
3. Supply `project(state, actor)` that returns only that player's permitted data. Fuel advances each viewer's revision only when that projection changes, or when that viewer's own action is accepted.
4. Create `Fuel::Store` with a PostgreSQL URL, a fixed namespace and two different random server keys of at least 32 bytes. Keep keys outside the database and Git; keep them stable across restarts. Call `migrate` explicitly during setup.
5. Create `Fuel::Sessions` and `Fuel::Handler` with an exact browser Origin allowlist, then give the handler to `HTTP::Server`.
6. Run periodic `sessions.cleanup` and `store.cleanup`. For realtime games run `Fuel::Ticker#advance` from one monotonic scheduler. A capped catch-up discards excess elapsed time rather than executing an unbounded burst.
7. Serve HTTPS/WSS. Configure connection/header/idle limits and trusted reverse-proxy policy at the application boundary. Forwarded IP headers are not trusted by Fuel.

See [examples/counter.cr](../examples/counter.cr) for working setup and result hooks. To run it in the supplied disposable test environment, use `docker compose run --rm --service-ports test crystal run examples/counter.cr` with `DATABASE_URL`, `FUEL_DEVICE_KEY` and `FUEL_PAIR_KEY` explicitly supplied. No public port is declared by default; map a loopback port deliberately when you need one.

## Result hook

`Rules#result(state, actor)` returns a `Fuel::GameResult` or nil. Fuel freezes each player's first result and writes it under a stable room ID. The HTTP adapter retries settlement after commands and state reads. The room is retained while it has an unsettled result. A lost response can be retried with the original command ID; rules are not applied again.

A result commits its receipt, replacement progress document and leaderboard/outcome row atomically. Use the block form of `Store#record_result` for additional game-owned database effects on that same connection. The Questmetry `enqueue` method can participate in that transaction. Never call a second connection or external payment service from that block.

If the process dies before the transaction commits, the unsaved RAM result is lost. If COMMIT may have succeeded, retry the same result ID and payload. Permanent progress/result receipts survive restarts. In-memory action receipts do not.

## Optional features

Construct `Questmetry` only when wanted. Its HTTP factory requires an explicit HTTPS endpoint and server-only key. Include `session_finished` in the allowlist when enabling automatic settlement analytics. Schedule `drain` outside user requests. Opt-out removes queued product events.

Construct `Handler` with `persisted_chat: ["private", "guild"]` to persist those channel kinds. Guild membership comes from the supplied `guild_access` callback; Fuel does not yet implement a guild system. The default callback denies guild access.

Use `Store#delete_account`'s transactional purge hook for game-owned tables, or supply `Handler.new(..., deletion_hook: ...)` to include it in the HTTP workflow. The default hook removes Fuel-owned data only; applications with additional data must supply the hook before exposing that route.
