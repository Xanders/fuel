# Incremental adoption

Existing games should migrate one shared subsystem at a time. This guide does not authorize changes to a running game or its data.

The account-facade schema setup preserves pre-existing nonempty progress and progress with an earlier result receipt. Game-specific progress shape changes still require a deliberate migration; a new pure refresh hook must understand the stored shape before it is enabled.

1. Record current compiler, rules, transport, persistence and recovery behavior. Preserve behavioral fixtures for success, lost responses, duplicate commands, stale replies and hidden data.
2. Upgrade the game's compiler/dependencies independently when needed. Fuel currently validates Crystal 1.22.1 only.
3. Add Fuel behind an existing boundary, such as account lifecycle, leaderboard or session gateway. Keep game rules in pure hooks. Preserve live compatibility where needed; a coordinated zero-user migration may deliberately replace both peers and discard obsolete adapters with the owner's explicit scope.
4. Compare the same scenario before/after using isolated synthetic data. Measure removed common production code minus added integration code. Do not count tests, content or already-shared dependencies as game-code savings.
5. Choose the RAM-only session behavior explicitly. Games that currently restore turns, boards or campaigns cannot silently replace that behavior with Fuel session recovery. Keep permanent progression distinct from the transient run.
6. Plan a separately authorized data migration with backups, restore rehearsal, stable IDs, one authoritative writer and reversible schema expansion. Rollback code does not mean restoring an old database over newer progress.
7. Pilot one game and one subsystem before widening adoption. Record the actual integration glue and operations needed; no percentage reduction is promised in advance.

When a shared feature is missing or awkward, open an issue/feature request in Fuel and notify the maintainer listed in CODEOWNERS. A consumer is not required to implement a framework PR. Avoid local workaround copies of auth, matchmaking, retries or persistence that diverge from the common contract.

For an existing realtime wire protocol, the shared [transport adapter](TRANSPORT.md) and SDK transport engines provide an adoption boundary. Both canonical and compatible routes use the same engine. Keep the existing account/storage/rules contracts explicit; importing transport does not complete their migration. Reliable event queues, fresh physical-send authorization and lifetime/identity/request fences are acceptance requirements.

For full adoption, replace the consumer's generic store/identity/crypto, session registries, join/socket loops, receipt queues, retry/settlement workers, chat/moderation storage and analytics outbox with Store/AccountRules/Rules/Runtime plus the canonical SDK owners. Leave only domain rules, viewer projection, product schemas, configuration and thin OS ports. Remove old route aliases once the release contract permits; do not relocate them into the SDK. Inventory every originally promised subsystem and compare all authored shipping source/glue before claiming a reduction. Shared library growth is a separate cost and must be reported separately.
