# Fuel

Fuel is an MIT-licensed Crystal game backend framework. A game supplies its rules, player-specific view and result; Fuel supplies identity, rooms, joining, matching, command receipts, transport and persistent results.

**Status: 0.1 development preview.** One backend process, latest validated stable Crystal (1.22.1), PostgreSQL. No published package-registry release or production deployment is implied.

## Deliberate limits

- All active session data lives in RAM, including positions, turns and solo runs. Restarting the backend loses those sessions. The client receives `session_lost`; reconnect cannot restore them.
- PostgreSQL is the only database for persistent data. Other database engines are not planned.
- Every session belongs to one backend instance. Cross-instance sessions and interactions between players on different instances are not supported.
- Multi-instance player stickiness, moving players for scale-down and automatic rebalancing after scale-up are separate [roadmap](docs/ROADMAP.md) items.

## Start here

[Getting started](docs/GETTING_STARTED.md) · [Architecture and storage](docs/ARCHITECTURE.md) · [Wire API](docs/API.md) · [Security](SECURITY.md) · [Migration guide](docs/MIGRATION.md)

```yaml
# shard.yml in your game
dependencies:
  fuel:
    github: Xanders/fuel
    version: ~> 0.1.0
```

Until a version tag is published, pin a reviewed commit instead of using the version constraint above.

Implement `Fuel::Rules#initial`, `#apply` and `#project`. Optional `#tick` and `#result` support realtime simulation and persistent completion. [The counter example](examples/counter.cr) is a complete neutral server.

## Included services

- Permanent guest devices, independent device bindings, owner-confirmed six-character transfer, revocation and account deletion.
- Private invite codes and HTTPS links, public rooms, FIFO automatch, trusted co-op party matching.
- Serial session commands, per-viewer revisions, epoch fencing, exact-ID receipts, realtime input sequences, bounded fixed-step catch-up.
- JSON HTTP, long polling and bounded WebSocket transport.
- Best-score leaderboards and outcome ratings; games own display names and scoring rules.
- Instance-global, session, guild-policy and private chat; bounded RAM history and optional PostgreSQL history for private/guild chat; configurable literal-word censor and glyph variants.
- Consumer-provided localized dictionary name generation.
- Optional Questmetry delivery with a PostgreSQL outbox, stable event IDs, retry and opt-out. No analytics service is contacted unless configured.

Only `pg` is a direct runtime shard dependency; `db` is transitive. EventWinder is not required.

## Test

```sh
docker compose -p fuel-test run --rm test
docker compose -p fuel-test down
```

The test database is disposable, has no host port and uses tmpfs. Override `FUEL_TEST_SUBNET` if its test network conflicts with your host. [Contributing](CONTRIBUTING.md) explains TDD and review.

The companion [Dart SDK and Flutter/Flame bridges](https://github.com/Xanders/fuel-and-flame) keep network code independent of the renderer.
