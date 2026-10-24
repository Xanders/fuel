# Backlog

- B-001 — deferred until production: joining/leaving can change the snapshot readiness flag without advancing an existing member's cursor. A consumer displaying readiness can retain the old flag until a subsequent action/ready transition. Source review round 1, minor finding 9. No current UI consumer is shipped; fix and add membership/readiness regression before production use of that flag.
