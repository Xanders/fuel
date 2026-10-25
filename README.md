# Fuel

Fuel is an MIT-licensed Crystal game backend framework. A game supplies pure account/combat rules and player-specific views; Fuel owns identity, persistence, sessions, joining, matching, transport, reliable effects and recovery.

**Status: 0.3 development preview.** One backend process, tested Crystal 1.22.1 and PostgreSQL 17. Pin both peers to the same reviewed release; development APIs may change. No registry publication or production deployment is implied.

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
    version: ~> 0.3.0
```

Until a version tag is published, pin a reviewed commit instead of using the version constraint above.

Implement `Fuel::Rules` for RAM gameplay and `Fuel::AccountRules` for permanent game state/actions. `Fuel::Runtime` runs the shared lifecycle, fixed-step ticker, FIFO durable effects and optional analytics. [The counter example](examples/counter.cr) is a complete neutral server using the simpler completion hook.

## Included services

- Permanent guest devices, independent device bindings, owner-confirmed six-character transfer, revocation and account deletion.
- Pure persistent account hooks, sorted multi-account transactions, exact action receipts, terminal summaries and HTTP recovery after RAM session loss.
- Bounded per-room FIFO effects, one head in flight, explicit saving backpressure and shared drain/health lifecycle.
- Private invite codes and HTTPS links, public rooms, FIFO automatch, trusted co-op party matching.
- Serial session commands, per-viewer revisions, epoch fencing, exact-ID receipts, realtime input sequences, bounded fixed-step catch-up.
- JSON HTTP, long polling and bounded WebSocket transport.
- Best-score leaderboards and outcome ratings; games own display names and scoring rules.
- Instance-global, session, guild-policy and private chat; bounded RAM and optional PostgreSQL history per kind, mutes, reports and configurable literal-word censor/glyph variants.
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
