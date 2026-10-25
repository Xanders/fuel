---
name: fuel-integration
description: Integrate the Fuel Crystal backend library into a new or existing game using its public contracts.
license: MIT
---

Read README, docs/GETTING_STARTED.md, docs/ARCHITECTURE.md, docs/API.md and SECURITY.md in the Fuel checkout first. Use the companion Dart SDK where appropriate; Flame is optional.

Inventory the consumer's actual runtime, auth, persistence, transport and rules. Separate permanent progress from transient gameplay. Do not promise session restore: Fuel loses all session state on process restart. Use PostgreSQL for permanent data.

Choose one shared subsystem and write a failing acceptance fixture before replacing consumer code. Preserve private projections, exact command/result IDs, revocation, known-commit recovery and the consumer's current external compatibility. Retain the game's authoritative rules. Configure limits, Origin allowlist and secrets through application configuration; never copy machine paths or private keys into examples.

For a new game implement AccountRules for pure permanent state/actions and Rules for gameplay/private projection. Instantiate Store/Sessions/Handler/Runtime and use the canonical SDK account/session owners. Run complete start/action/result plus disconnect/retry against disposable data. For realtime inputs validate intent in rules and never resend stale movement. Transfer retains the candidate, owner phrase confirmation and previous guest. Domain hooks must not implement generic SQL, identity, outbox or retry workers.

For an existing game follow docs/MIGRATION.md. Transport adapters are a limited incremental step, not full adoption. Preserve compatibility for live users; a separately authorized coordinated zero-user replacement can remove old contracts. Migrate every intended common subsystem and delete its consumer copy. Measure all removed common code and added shipping glue; report library growth separately. Do not change live data/secrets/recovery policy as an incidental upgrade.

When the public interface lacks a common feature, create a Fuel issue/feature request and notify the maintainer in CODEOWNERS. Do not implement a local workaround copy or require the consumer to submit a framework PR.

Finish with relevant tests, exact-candidate independent review, documentation of changed behavior and honest limits. Package/library review is distinct from the consuming game's release acceptance.
