# Wire API v1

All paths below have prefix `/fuel/v1/`. Successful responses are `{"wire_version":1,"data":...}`; errors are `{"wire_version":1,"error":"code"}`. Set `X-Fuel-Version: 1`; unsupported versions fail before mutation. Revisions, input sequences, scores, ranks and counts use decimal strings to preserve 64-bit precision on web clients.

Native credentials use `Authorization: Fuel <binding-id>:<secret>` over TLS. Browser credentials are host-only Secure HttpOnly SameSite=Strict cookies. Never put credentials into a URL. Mutating cookie requests require an allowed Origin. Deploy same-origin browser API; cross-origin CORS is not supplied.

| Method | Path | Body / result |
|---|---|---|
| GET | auth/prepare | Prepare a browser cookie before bootstrap; no database account created |
| POST | auth/bootstrap | Native credential must already be saved; idempotent account creation |
| GET | auth/bindings | Own bindings only |
| POST | auth/revoke | `{id}`; revoke one owned binding |
| POST | auth/delete | `{confirmed:true}`; purge Fuel-owned data, revoke all bindings |
| POST | auth/pair | Issue six-character five-minute transfer code and operation ID |
| GET | auth/pair/prepare | Browser candidate cookie separate from current guest |
| POST | auth/pair/request | `{code}`, authenticated by saved candidate; returns pending ID and phrase, no target account access |
| GET | auth/pair/pending | Owner sees pending candidate verification phrases |
| POST | auth/pair/approve | `{id}`; owner approves that exact request |
| POST | auth/pair/cancel | `{id}`; cancel pending own operation |
| GET | auth/pair/status | Candidate proof; pending/linked/expired/cancelled |
| POST | auth/pair/activate | Browser adopts linked candidate, preserves prior guest cookie |
| POST | auth/switch | Browser returns to prior saved binding |
| GET | progress | Permanent game-owned JSON progress |
| POST | sessions | `{mode,capacity,public,late_join}`; session_id, epoch and private code |
| GET | sessions?mode=duel | Up to 100 public joinable rooms; no codes |
| POST | join | `{code}` or public `{session_id}`; accepted snapshot |
| POST | match | `{mode,ticket_id}`; stable ticket generation, waiting or matched/session_id |
| POST | match/cancel | `{mode,ticket_id}`; cancelled or already-matched outcome |
| GET | sessions/:id | Current viewer-specific snapshot |
| POST | sessions/:id/commands | `{id,epoch,revision:"0",action:{...}}`; exact-ID retry |
| POST | sessions/:id/ready | Mark this member ready |
| POST | sessions/:id/leave | Leave; unsettled results must be saved first |
| GET | sessions/:id/events?epoch=...&cursor=... | Single-flight long poll, up to 15 seconds, returns full snapshot; revalidates access after waits |
| GET | stream?session_id=... | WebSocket upgrade; authenticated and Origin-checked |
| POST | chat | `{kind,target,text}` |
| GET | chat?kind=...&target=... | Bounded authorized history |
| GET | leaderboards/:board?limit=100 | Best score per player, descending score, earliest achievement then account for ties |
| GET | ratings/:board?metric=wins&hours=24 | wins, battles or win_ratio; draws count as battles and are excluded from win-ratio denominator |
| POST | analytics/enabled | `{enabled:false}`; requires configured analytics |

Snapshots contain `session_id, epoch, revision, state, server_time, last_input, ready`. Socket envelopes additionally contain `generation`; inputs are `{epoch,sequence:"1",action:{...}}`. Inputs are never replayed across reconnect; wait for the new generation and current snapshot. The server sends full snapshots about every 100 ms; a game's tick cadence is separate.

Chat kinds: `global` (instance), `session` (target room ID, membership required), `guild` (target guild ID, callback required), `private` (target recipient account). No account ID in a body grants the sender that identity. Private history keys are canonical participant pairs. Sender/recipient block policies can be added by the application; the default private channel permits messages between authenticated accounts and is not a full moderation system.

## Error/recovery contract

Retain one ticket_id for a matchmaking intent and its cancellation. A cancelled generation is rejected as match_cancelled for the five-minute ticket horizon; create a new ID for a new deliberate attempt. Do not retry old intents after that horizon. An already matched generation continues returning its room even after cancellation races.

- `unauthorized` / `forbidden`: stop private actions; preserve saved credentials. No automatic new guest.
- `session_lost`: the session is unavailable in this process; abandon session commands and offer a new session. Persistent progress remains.
- `session_ended`: stop gameplay inputs.
- `revision_conflict`: refresh the snapshot; do not silently rebase the old action.
- `conflict`: an ID was reused with different content.
- `stale_connection` / `stale_input`: discard old inputs; do not retry them as new actions.
- `unavailable` / network timeout: outcome may be unknown. Retry the same semantic command/result ID and payload.
- `rate_limited` / `capacity` / `poll_active`: back off and keep existing identity/session; do not spin new bootstrap requests.
- `invalid_code`: the same generic outcome covers missing, used and expired codes.

Persistent result submission is a trusted Crystal library API, never a public client-score endpoint. `Store#record_result` accepts an optional outcome and transactional effect block. Account IDs are pseudonyms, not authentication secrets. API, rules/payloads and schema versions are separate compatibility concerns.
