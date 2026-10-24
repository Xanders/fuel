# Incremental adoption

Existing games should migrate one shared subsystem at a time. This guide does not authorize changes to a running game or its data.

1. Record current compiler, rules, transport, persistence and recovery behavior. Preserve behavioral fixtures for success, lost responses, duplicate commands, stale replies and hidden data.
2. Upgrade the game's compiler/dependencies independently when needed. Fuel currently validates Crystal 1.22.1 only.
3. Add Fuel behind an existing boundary, such as account lifecycle, leaderboard or session gateway. Keep game rules and public compatibility in game-owned adapters.
4. Compare the same scenario before/after using isolated synthetic data. Measure removed common production code minus added integration code. Do not count tests, content or already-shared dependencies as game-code savings.
5. Choose the RAM-only session behavior explicitly. Games that currently restore turns, boards or campaigns cannot silently replace that behavior with Fuel session recovery. Keep permanent progression distinct from the transient run.
6. Plan a separately authorized data migration with backups, restore rehearsal, stable IDs, one authoritative writer and reversible schema expansion. Rollback code does not mean restoring an old database over newer progress.
7. Pilot one game and one subsystem before widening adoption. Record the actual integration glue and operations needed; no percentage reduction is promised in advance.

When a shared feature is missing or awkward, open an issue/feature request in Fuel and notify the maintainer listed in CODEOWNERS. A consumer is not required to implement a framework PR. Avoid local workaround copies of auth, matchmaking, retries or persistence that diverge from the common contract.
