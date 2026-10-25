# Getting started

Fuel is linked into the game's executable; PostgreSQL runs separately. Use a dedicated database role and fixed namespace per game/environment. Clients never choose the namespace. Tested toolchain: Crystal1.22.1 and PostgreSQL17, with Docker for the supplied workflow.

1. Pin Fuel and the client SDK to one reviewed release and install dependencies.
2. Implement `AccountRules.initial/refresh/public_action?/participants/apply`. These are pure game progress/economy hooks. `apply` receives an AccountTransaction with copied declared account state and bounded notification/score/event descriptors; no SQL or credentials. Validate quantities, ownership and domain rules. `terminal?(action,reply)` marks final effect summaries for durable client recovery.
3. Implement `Rules.initial/apply/project`; context initialization can use mode/session/epoch and freshly prepared account progress. Optional join/leave/authorize/tick/effects/acknowledge/finished hooks implement the game's mechanics. Every projection must exclude the viewer's hidden data. Hooks are fast, nonblocking and side-effect-free.
4. Create Store with the PostgreSQL URL, fixed namespace and two distinct privately generated keys of at least32bytes. Preserve keys outside Git/database backups across restarts. Call migrate during setup. Configure mode policies for fixed capacities, shared hub, exclusive gameplay, readiness/late joining and immediate start where appropriate.
5. Create Sessions, Handler (account_rules, exact Origin allowlist and optional API prefix), then Runtime(store,sessions,handler,account_rules). Runtime owns HTTP, fixed-step ticks, FIFO effect dispatch, cleanup, signals and health. The counter example is a complete neutral executable.
6. Configure HTTPS/WSS and proxy-level connection/header/idle limits. Fuel uses the actual socket address and does not trust arbitrary forwarded IP headers.
7. Run start/action/known-result plus disconnect/retry/revocation/hidden-data scenarios against disposable data before integration acceptance.

```sh
docker compose -p fuel-demo run --rm -p 127.0.0.1:8080:8080 \
  -e DATABASE_URL=postgres://fuel:fuel_test@db:5432/fuel_test \
  -e FUEL_DEVICE_KEY=development-only-device-key-do-not-use-for-real-accounts \
  -e FUEL_PAIR_KEY=development-only-transfer-key-do-not-use-for-real-accounts \
  test crystal run examples/counter.cr
docker compose -p fuel-demo down
```

These public demo credentials apply only to the disposable database. The example port is loopback-only; browsers require HTTPS. Real credentials must be private and stable.

## Permanent effects

An HTTP account action uses a client-saved immutable operation ID and the game's public action allowlist. Server-only grants use Effect descriptors from Rules.effects. Freeze operation-local identity, actor, action, payload and occurrence; Fuel qualifies the ID by room/epoch. Return every pending descriptor until acknowledge removes it from the candidate state. Do not mint another ID after failure or put IO in a rule hook.

Runtime commits one head per room in FIFO order, outside room/registry locks, then acknowledges its confirmed receipt. The same transaction owns progress, per-viewer durable receipts, scores/outcomes and optional event enqueue. Unknown COMMIT is reconciled with the same ID before later effects proceed. Other rooms remain independent. Queue saturation rejects that state advance and exposes saving_backlog; accepted work is retained. Programming conflicts quarantine rather than discard it.

RAM work not committed before process loss is intentionally lost. Committed progress/operation receipts survive and the SDK recovers them through HTTP. Receipts never replace present balances with historical values.

The simpler Rules.result/GameResult hook remains for one final result/player, as used by the counter example. Its progress/leaderboard/result commit is atomic; it does not replace the multi-effect path for games with intermediate grants or cross-account changes.

## Optional services

Construct Questmetry only when configured. Its HTTPS factory needs an explicit endpoint, server-only write key and preferably a dedicated stable pseudonym key. Declare/validate product schemas; event time/ID/session/privacy revision is frozen with the originating effect. Delivery runs outside gameplay transactions. Opt-out clears queued events and fences delivery; queue capacity is diagnosed without rolling back a reward. No analytics request is made when the integration is absent.

Handler persisted_chat can select global/session/private/guild kinds; all have bounded retention. Guild access uses the supplied policy callback and denies by default; guild membership management is still roadmap work. Censor dictionaries/glyph variants and display-name hooks are game configuration. Mutes/reports use accessible retained messages, not caller-invented sender data. NameDictionary uses the shared version1 localized dictionary standard in ARCHITECTURE.

The default deletion workflow removes Fuel-owned data. Additional tables/providers must participate through the transactional purge hook or a separately correct provider workflow before that route is exposed. A deletion proof/status receipt reconciles unknown results after credentials disappear.
