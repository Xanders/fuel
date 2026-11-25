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

## Device transfer at 0.4.0

Run `Store#migrate` as the schema owner before the new binary starts. This adds an issuer binding column and an index to `fuel_pairs` and a flag on `fuel_bindings` for recovering completed basic links after their notices expire. Current accounts, proofs, progress and successful links survive. Legacy pending rows lack an issuer proof. They cannot be completed on the new binary, so let any active five-minute transfer finish or expire before switching versions, or ask the issuer to generate a fresh code. The new library never turns a confirmed pending request into a basic transfer.

Deploy with the default confirmed policy to keep the existing client flow. At 0.4.0 approvals and confirmation polling use the device that issued the code. Switch a game to `PairMode::Basic` only after verifying both clients on the new SDK and allowing for cached or installed older clients. Older clients that attempt to issue in basic mode receive `transfer_update_required`. Keep `PairMode::Disabled` in services that forbid ordinary transfer; keep issuer/login settings and policies separate. Verify two devices, stored previous guest, existing progress, network loss and the project's version gates before enabling the new flow.

Rollback keeps the additive schema and current account data. Stop the writer and let outstanding codes expire (or cancel them) before accepting traffic on the previous binary. Older binaries cannot redeem basic codes or read basic completion notices, and cannot apply the new issuing-binding guard to pending confirmed codes. Already completed bindings work with the old ordinary credential verifier. Rehearse the upgrade and rollback on a restored copy with the project's own keys and disposable identities.

For an existing realtime wire protocol, the shared [transport adapter](TRANSPORT.md) and SDK transport engines provide an adoption boundary. Both canonical and compatible routes use the same engine. Keep the existing account/storage/rules contracts explicit; importing transport does not complete their migration. Reliable event queues, fresh physical-send authorization and lifetime/identity/request fences are acceptance requirements.

For full adoption, replace the consumer's generic store/identity/crypto, session registries, join/socket loops, receipt queues, retry/settlement workers, chat/moderation storage and analytics sender with Store/AccountRules/Rules/Runtime plus the canonical SDK owners. Analytics uses bounded RAM, not an outbox replacement; follow the [legacy analytics adoption precautions](SOCIAL.md#upgrading-an-existing-durable-sender) before retiring a durable sender. Leave only domain rules, viewer projection, product schemas, configuration and thin OS ports. Remove old route aliases once the release contract permits; do not relocate them into the SDK. Inventory every originally promised subsystem and compare all authored shipping source/glue before claiming a reduction. Shared library growth is a separate cost and must be reported separately.
