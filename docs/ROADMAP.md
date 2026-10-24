# Roadmap

Current implementation and future work are separate. See README for delivered preview services.

## Planned, not implemented

- Hard PostgreSQL player-to-backend stickiness with routing and admission for multiple instances. One player plays on one assigned instance; all participants of a session must be on that instance. No interaction with players on other instances.
- Explicit player movement and draining for scale-down. Without it, reducing the instance count cannot preserve affected players' sessions.
- Automatic rebalancing after scale-up. Adding instances alone does not move players or unload older instances.
- Guild lifecycle, roles and membership (the current chat module accepts an external guild-access callback).
- Achievements and idempotent grants.
- App Store server-verified purchases, restore and revocations.
- Google Play server-verified purchases, restore and revocations.
- Xsolla verified web payments, idempotent callbacks and refunds.
- Internal community: news, forum, ideas, questions, bug reports, private conversations with read receipts and contact with developers.
- Production qualification, registry distribution, additional consumer fixtures and measured performance budgets.
- Game-provided private-message block/mute/report policies and moderation workflow.

## Intentional limits

Active session data remains in RAM and is lost on restart. PostgreSQL remains the only persistent database. Cross-instance sessions are not planned. A single hot session is never split across backend instances.
