# Wire API v1

Fuel 0.3 is an experimental API; pin the server and SDK to the same reviewed release. `wire_version: 1` identifies the envelope, not compatibility with every earlier development API. The default prefix is `/fuel/v1`; `Handler(prefix: ...)` and the SDK base URI can select another application prefix.

Success is `{"wire_version":1,"data":...}` and error is `{"wire_version":1,"error":"code"}`. Send `X-Fuel-Version: 1`. Revisions, sequences, receipt cursors, scores and counts are decimal strings; Unix timestamps are integers. Global operation cursors may have gaps between an account's entries.

Native credentials use `Authorization: Fuel <binding-id>:<secret>` over TLS. Browser credentials use namespace-specific host-only Secure HttpOnly SameSite=Strict cookies (current, previous, candidate). Cookie mutations require an exact allowed Origin; deploy browser API same-origin. Credentials never belong in URLs. Authenticated responses include `X-Fuel-Account`; `X-Fuel-Expected-Account` rejects a changed selected account before dispatching an action. Account IDs are public pseudonyms, not authentication.

| Method | Path | Contract |
|---|---|---|
| GET | auth/prepare | Prepare a browser proof without creating a database account; explicit `new=true` replaces only a definitively unauthorized active proof, retaining previous/candidate slots |
| POST | auth/bootstrap | Idempotent guest creation/restoration using the saved proof |
| GET | account | `{account_id,progress,analytics_enabled,analytics_revision,server_time}`; pure game initialization/refresh runs transactionally |
| POST | actions | `{id,action,payload}`; game public allowlist, atomic permanent action and durable receipt |
| GET | operations/:id | Own exact durable receipt or `not_found` |
| GET | operations?after=...&limit=100 | Forward durable history, ascending cursor; without after, latest page in ascending order |
| GET | operations?terminal=true&limit=1 | Latest terminal summary, even behind newer ordinary operations |
| GET | auth/bindings | Own bindings, current/revoked flags and created/last-seen metadata |
| POST | auth/revoke | `{id,confirmed_last:false}`; the last active binding requires explicit confirmation |
| POST | auth/delete | `{confirmed:true,account_id,proof}`; proof is a saved random 64-hex deletion-operation secret |
| POST | auth/delete/status | `{account_id,proof}`; narrow `deleted/removed_bindings` or `unknown`, works after login proof removal |
| POST | auth/pair | Issue ID, six-character code and five-minute expiry interval |
| GET | auth/pair/issued?id=... | Owner-only status, phrase and Unix expiry |
| GET | auth/pair/prepare | Browser candidate; `new=true` only deliberately abandons the old attempt |
| POST | auth/pair/request | `{code}` using candidate proof; pending ID/phrase, no target account access |
| GET | auth/pair/pending | Owner's pending requests and comparison phrases |
| POST | auth/pair/approve | `{id}`; owner confirms the displayed exact request |
| POST | auth/pair/cancel | `{id}`; cancel an own pending request |
| GET | auth/pair/status | Candidate's pending/linked/expired/cancelled status |
| GET | auth/selection | Browser current/previous public binding/account metadata and candidate public ID |
| POST | auth/pair/activate | `{target_id}`; adopt the frozen linked candidate and retain the previous guest |
| POST | auth/switch | `{from,to}` binding IDs; `from:null` permits selecting a surviving previous proof; repeating an already-selected target does not toggle |
| POST | sessions | `{mode,capacity,public,late_join}`; ID, epoch and private invite code; configured mode policy owns actual capacity/policy |
| GET | sessions?mode=... | Up to 100 public joinable rooms, without invite codes |
| GET | sessions/mine | Current own memberships for unknown admission recovery; never creates a room |
| POST | join | `{code}` or public `{session_id}`; authoritative viewer snapshot |
| POST | match | `{mode,ticket_id}`; stable waiting/matched intent |
| POST | match/cancel | Same mode/ticket ID; cancelled or already-matched outcome |
| GET | sessions/:id | Viewer-specific full snapshot |
| POST | sessions/:id/commands | `{id,epoch,revision:"0",action:{...}}`; exact command retry |
| POST | sessions/:id/ready | Mark this member ready |
| POST | sessions/:id/leave | Leave; pending persistent effects/results cannot be discarded |
| GET | sessions/:id/events?epoch=...&cursor=... | One long poll per binding, up to 15 seconds; revalidates after waits. Only request admission refreshes player activity; server-side waiting does not. |
| GET | stream?session_id=...&account_id=... | WebSocket; optional expected public account protects browser selection races |
| POST | chat | `{kind,target,text}`; authoritative name, membership, censor and bounds |
| GET | chat?kind=...&target=... | Accessible retained history, excluding muted players |
| GET | chat/mutes | Own muted players with display names |
| POST | chat/mute | `{target,muted}` |
| POST | chat/report | `{kind,target,message_id,reason}`; proof of an accessible retained message, bounded and idempotent |
| GET | leaderboards/:board?limit=100 | Best authoritative score/player; descending score then earliest achievement/account |
| GET | leaderboards/:board/page?limit=100 | Public `entries` and the authenticated player's own `player_rank`/`player_best`, including outside the page |
| GET | ratings/:board?metric=wins&hours=24 | wins, battles or win_ratio; draws count as battles, outside win-ratio denominator |
| POST | analytics/enabled | `{enabled:false}`; confirmed account consent revision, available without an analytics adapter |
| POST | analytics/events | `{id,name,session,properties:{...},revision:"0"}`; explicitly allowlisted client UI telemetry, requires configured analytics |

## Snapshots and receipts

A late transient input after room completion cannot mutate the result. The socket sends a fresh authorised final snapshot so an input based on an older active snapshot does not cause a reconnect loop. Lost epochs and authorization failures still fail closed. Fuel 0.3.1 is compatible with SDK 0.3.0.

Snapshots contain `session_id,mode,code,epoch,revision,state,server_time,last_input,ready,saving_backlog,effect_error,receipt_cursor,receipt_base,receipts`. The domain `state` is always a private viewer projection. Socket envelopes also carry actual `account_id` and physical `generation`. Inputs are `{epoch,sequence:"1",action:{...}}`; never replay them after reconnect. About ten full snapshots/second are independent of the game's fixed-step tick.

Acknowledging an analytics-only effect leaves a viewer's revision unchanged when its projection and visible metadata did not change. Gameplay receipts advance their recipients' revisions, and clearing room-wide saving backpressure advances all members' revisions. Consumers must not infer another player's private action from an otherwise unchanged settlement acknowledgement.

The RAM receipt log contains `{sequence,operation}` entries, bounded by 64 entries and 16 KiB. `receipt_base` identifies its first retained sequence, or cursor+1 when empty. Coalescing snapshots must not be mistaken for complete reliable event delivery. The SDK recovers authoritative operations through durable HTTP history; a large presentation backlog explicitly resynchronizes rather than replaying every old animation.

A durable operation contains `operation_id,cursor,source,session_id,epoch,action,occurred_at,committed_at,terminal,reply`. Source is public, effect or internal event. Only trusted Crystal effects can mark a terminal result. Receipts, current progress, score descriptors and optional analytics enqueue commit together. Retry the same ID/action/payload; never install historical reply balances as present progress. Dedupe/history persists until account deletion. History pages have at most 100 entries and 480 KiB; resume at the last returned cursor even when a page is short.

## Recovery and authority

- `unauthorized/selection_changed`: stop private activity and reconcile the saved identity; never bootstrap a replacement guest automatically.
- `session_lost/session_ended`: abandon old RAM commands. Offer a deliberate new session; permanent progress and committed receipts remain.
- `saving_backlog/pending_result`: accepted work remains queued. Pause new play/admission until it settles. A quarantine is visible through effect_error/health and requires fixing its cause.
- `revision_conflict/conflict`: fetch current state or reconcile the exact original operation. Do not change its ID or silently rebase an uncertain intent.
- Timeout/unavailable: may have committed. Read the original receipt or retry the exact intent. An aborted client connection does not roll back the server.
- `rate_limited/capacity/poll_active`: bounded backoff, preserving identity/session.
- `invalid_code`: generic missing/used/expired-code outcome. Transfer preparation retains its proof through retry; owner phrase confirmation remains mandatory.

Deletion status is retained for 30 days. It reveals only that operation's outcome and removed public binding IDs, never progress or a usable login proof. Retired binding IDs remain tombstoned so an old secret cannot recreate a deleted account. The consumer must include any additional data owners in its transactional purge hook.

Chat kinds are instance-global, session (room membership), guild (application policy callback), private (canonical participant pair). History/persistence are optional per kind. Default private chat permits authenticated accounts to message each other; game-specific consent/block policy and moderation operations remain application policy.

`Runtime` owns server/ticker/effect workers/cleanup and optional analytics delivery. GET `/health` reports database health, admissions, active sessions, in-flight/pending/quarantined work and safe_to_replace. USR1 drains new work; USR2 resumes. Replacement is safe only after drain, a healthy database and zero active/pending/in-flight/quarantined work. This never makes RAM sessions durable or supplies multi-instance routing.

For one application, `runtime.run(host, port)` binds its listener and installs process signals. To embed multiple isolated applications in one process, construct a separate Store/Sessions/Handler/Runtime per application, prebind **all** `runtime.server` listeners before starting any workers, and run each `runtime.listen` in an observed fiber. The embedding process owns signal fanout, stops every runtime if one fails, and waits for all completions before closing stores. If binding fails, stop all constructed runtimes without starting them. Use fixed server-owned namespaces, ports and allowed origins; sharing a process or database never links accounts automatically. Aggregate readiness and replacement checks across every runtime.

`stop` initiates shutdown; `listen` returns only after admitted HTTP requests, sockets (including authentication setup), effects and background workers have joined. `listen(shutdown_timeout: 10.seconds)` raises `shutdown_timeout` if that deadline expires, or `runtime_failed` after an unexpected background-worker failure. A failed join does **not** authorize closing a store or replacing a process as though work had finished. An admitted effect may remain pending in RAM; normal replacement still requires the drain/health gate. A stopped runtime cannot restart. Repeated startup raises `runtime_started` without stopping the active owner.

Ranking pages use `{entries:[{rank:"1",name:"Quiet Fox",score:"100",is_player:false}],player_rank:"500",player_best:"5"}`. Numeric values are decimal strings; the two player fields are null when the player has no score. Ranks are unique positions ordered by score descending, earliest achievement, then account. No account IDs appear in this public projection. Page limits are 1–100. The existing array endpoint retains its previous response shape.

The optional Handler `leaderboard_reader` is a trusted `Fuel::LeaderboardReader`: `(DB::Connection, namespace, actor, board, limit) -> JSON::Any`. Authentication, expected-account, Origin, board and limit checks precede it; the borrowed connection remains within the account's authority boundary. Return only the public page shape, at most 64 KiB, never proofs, profiles or another application's account identifiers. A combined board must define deterministic ordering and source-qualified identities in one database query/snapshot; matching strings from different namespaces or an unclaimed archive do not establish ownership. The default reader uses only the current namespace. This hook supplies no cross-instance session routing or account federation.

For UI telemetry, configure Questmetry `client_events: ["screen_viewed"]` as an explicit subset of the full event schema. It defaults to empty; clients cannot submit authoritative outcome events. The shared boundary validates properties with the configured schema/validator, checks current consent revision, pseudonymizes account/session, timestamps receipt on the server and assigns `source: "client"` with server-owned context. Raw client event IDs are validated and keyed by authenticated account in a separate server-owned domain; they cannot reserve another account's or a trusted event's dedupe ID. It creates no gameplay operation or reward receipt. Responses report `queued`, `duplicate`, `disabled`, `stale` or `capacity`; configured bounded outbox delivery owns retries after acceptance. Client-to-backend UI submission is best effort: no gameplay journal or automatic resubmission is created. Do not use this path for business-critical outcomes; emit those through trusted session/account effects. Never accept free text, names, credentials or arbitrary properties in the event validator.
