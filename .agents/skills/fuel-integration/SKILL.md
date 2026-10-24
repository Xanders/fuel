---
name: fuel-integration
description: Integrate the Fuel Crystal backend library into a new or existing game using its public contracts.
license: MIT
---

Read README, docs/GETTING_STARTED.md, docs/ARCHITECTURE.md, docs/API.md and SECURITY.md in the Fuel checkout first. Use the companion Dart SDK where appropriate; Flame is optional.

Inventory the consumer's actual runtime, auth, persistence, transport and rules. Separate permanent progress from transient gameplay. Do not promise session restore: Fuel loses all session state on process restart. Use PostgreSQL for permanent data.

Choose one shared subsystem and write a failing acceptance fixture before replacing consumer code. Preserve private projections, exact command/result IDs, revocation, known-commit recovery and the consumer's current external compatibility. Retain the game's authoritative rules. Configure limits, Origin allowlist and secrets through application configuration; never copy machine paths or private keys into examples.

For a new game implement Rules initial/apply/project and optional result/tick, instantiate Store/Sessions/Handler, then run the complete start/action/result plus disconnect/retry scenario against a disposable database. For realtime inputs validate intent in rules and never resend stale movement after reconnect. For device transfer keep the saved candidate, owner phrase confirmation and prior guest separate.

For an existing game use docs/MIGRATION.md. Measure removed common code and new glue separately; do not promise a percentage before a feature-equivalent pilot. Do not change live data, secrets or recovery policy as an incidental library upgrade.

When the public interface lacks a common feature, create a Fuel issue/feature request and notify the maintainer in CODEOWNERS. Do not implement a local workaround copy or require the consumer to submit a framework PR.

Finish with relevant tests, exact-candidate independent review, documentation of changed behavior and honest limits. Package/library review is distinct from the consuming game's release acceptance.
