# Wire API v1

Optional trusted issuer enrollment/login is a [server-only Store API](TRUSTED_LOGIN.md).
It adds no anonymous canonical HTTP route. Its credentials and policy are independent of ordinary device transfer.

Fuel is an experimental API. Pin the server and SDK to a reviewed compatible pair. Fuel 0.4.0 and SDK 0.4.0 support both device transfer modes. `wire_version: 1` identifies the envelope and does not establish compatibility on its own. The default prefix is `/fuel/v1`. `Handler(prefix: ...)` and the SDK base URI can select another application prefix.

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
| POST | auth/delete/with-transfer | Same request plus `abandon_candidate_id` for the pending basic transfer. Browser uses the matching candidate cookie. Native also supplies `abandon_candidate_secret`. |
| POST | auth/delete/status | `{account_id,proof}`; narrow `deleted/removed_bindings` or `unknown`, works after login proof removal |
| POST | auth/pair | Issue ID, six-character code, mode and five-minute expiry interval. Basic mode requires `{"flow":"basic-v1"}` |
| GET | auth/pair/issued?id=... | Issuing device reads pending status, confirmation phrase or basic completion |
| GET | auth/pair/prepare | Browser candidate. Basic requires `flow=basic-v1`. `new=true` deliberately abandons an old candidate where the client has no unresolved selection |
| POST | auth/pair/request | Confirmed mode. `{code}` using candidate proof returns a pending ID and phrase |
| POST | auth/pair/redeem | Basic mode. `{code}` using native candidate proof, or browser candidate cookie with `{code,target_id,from}`. Binds the candidate; selects it in the same browser response |
| GET | auth/pair/pending | Issuing device's pending confirmed requests and phrases |
| POST | auth/pair/approve | `{id}` on the issuing device completes a confirmed request |
| POST | auth/pair/cancel | `{id}`; cancel an own pending request |
| GET | auth/pair/status | Candidate's pending/linked/expired/cancelled status. `target_id` fences the exact candidate and enables `retired` for a permanently unusable binding |
| POST | auth/pair/abandon | `{target_id}` with candidate proof. Retires the candidate if unlinked or revoked, or returns `transfer_completed` if it has a live link |
| GET | auth/selection | Read-only browser current/previous public metadata and candidate ID. A rejected current proof retains its binding ID with null account_id; rejected previous is null. No cookie is cleared |
| POST | auth/pair/activate | `{target_id}` for legacy activation, or `{target_id,from}` to fence both browser slots. Select the linked candidate and retain the previous guest |
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

## Device transfer

The server selects `Fuel::PairMode::Confirmed` (default), `Basic`, or `Disabled` through `Store.new(..., pair_mode: ...)`. The default and legacy request route retain confirmation. The `flow` field only declares that an issuing client supports the basic protocol. The server chooses the mode and includes it in its issue response. Turn on basic only with a compatible client. A legacy issuer gets `transfer_update_required`.

In basic mode, candidate preparation without the capability returns `transfer_update_required` without changing cookies. An older browser activation that omits `from` gets retryable `503 maintenance` before reading the candidate. This keeps a cached older SDK from discarding a newer client's shared recovery intent on a permanent error. Refresh or upgrade those clients before using transfer.

In **basic** mode, prepare and retain B's candidate proof before submitting the six-character code. A successful `POST auth/pair/redeem` links the candidate permanently and consumes the code in one transaction. No action or connection on A is needed. A native client then selects the already authorized proof in its vault. A browser sends the frozen candidate ID and former current binding ID (or null) from `auth/selection`. A changed slot returns `selection_changed`; an already-selected target permits an exact retry. On success the browser gets the active cookie in the redemption response and its former current proof becomes previous. Exact retries with the same code and candidate proof return the same completion within the receipt window. A different candidate cannot replay it.

Completion data is `{id,status:"linked",mode:"basic",account_id,emojis:[...three ordered strings]}`. The issuer can resume polling `auth/pair/issued?id=...` using the issued ID after coming online. The same receipt is available to both participating bindings until one day after the code's expiration. Poll while displaying the transfer and check on reconnect; Fuel has no push notification for this flow. After the notice expires, the linked candidate still reads `{status:"linked",mode:"basic",account_id}` through `auth/pair/status`. The strings are a post-transfer notice. Closing or omitting the notice leaves the binding intact.

If the original B proof is unavailable during recovery, `auth/pair/abandon` can settle the frozen candidate. A retired result is final and fences a late redemption. A live completed link wins and can still be recovered with the same proof. If the response is lost, check the exact `target_id` status again. Abandonment uses its own source and namespace rate limits.

In **confirmed** mode, B sends `auth/pair/request` and receives a pending ID and comparison phrase. A compares the same phrase and confirms that ID with `auth/pair/approve` on the issuing device. Only then can B use or select the candidate. Both modes refuse uncompleted codes whose issuing binding is revoked. The guest previously selected on B can be restored separately with `auth/switch`; progress is never merged. [Upgrade and rollback](MIGRATION.md#device-transfer-at-040).

## Snapshots and receipts

A late transient input after room completion cannot mutate the result. The socket sends a fresh authorised final snapshot so an input based on an older active snapshot does not cause a reconnect loop. Lost epochs and authorization failures still fail closed. Fuel 0.3.1 is compatible with SDK 0.3.0.

Snapshots contain `session_id,mode,code,epoch,revision,state,server_time,last_input,ready,saving_backlog,effect_error,receipt_cursor,receipt_base,receipts`. The domain `state` is always a private viewer projection. Socket envelopes also carry actual `account_id` and physical `generation`. Inputs are `{epoch,sequence:"1",action:{...}}`; never replay them after reconnect. The default 100 ms full-snapshot interval is independent of the game's fixed-step tick. Configure a positive `Handler(..., socket_interval: 500.milliseconds)` to change it; see [transport delivery](TRANSPORT.md#bounded-delivery) for latency and heartbeat limits. This does not change HTTP command handling or reliable-event semantics.

Draining independent analytics leaves viewer revisions unchanged. Gameplay receipts advance their recipients' revisions, and clearing room-wide business saving backpressure advances all members' revisions. Consumers must not infer another player's private action from an otherwise unchanged settlement acknowledgement.

The RAM receipt log contains `{sequence,operation}` entries, bounded by 64 entries and 16 KiB. `receipt_base` identifies its first retained sequence, or cursor+1 when empty. Coalescing snapshots must not be mistaken for complete reliable event delivery. The SDK recovers authoritative operations through durable HTTP history; a large presentation backlog explicitly resynchronizes rather than replaying every old animation.

A durable operation contains `operation_id,cursor,source,session_id,epoch,action,occurred_at,committed_at,terminal,reply`. New operations have source public or effect; older internal-event receipts may remain in historical data. Only trusted Crystal effects can mark a terminal result. Receipts, current progress and score descriptors commit together. Optional analytics is offered afterwards without waiting for admission/delivery and is never regenerated by an exact receipt retry. Retry the same ID/action/payload; never install historical reply balances as present progress. Dedupe/history persists until account deletion. History pages have at most 100 entries and 480 KiB; resume at the last returned cursor even when a page is short.

## Recovery and authority

`Sessions.new(rules, ttl: nil, invite_ttl: nil)` disables the absolute age limits for rooms and their invite codes. Defaults remain six hours for a room and five minutes for its invite, measured from room creation. Both options apply to the whole registry. A finite room TTL can expire an active room, subject to pending business work. Room disposal, capacity, admission checks, match tickets and account-transfer codes keep their own rules. An invite never outlives its room.

The optional server-side `Rules.apply(state, actor, action, presence, events)` and `Rules.tick(state, dt, presence, events)` overloads receive a `SessionPresence` snapshot. It provides copied `members` and `connected` lists, `connected?(actor)`, and the opaque socket `generation(actor)` or nil. Existing rules overloads still work. Presence reflects server socket bindings at the time of the action or tick. HTTP-only members have no socket generation.

`Rules.retain_idle_member?(state, actor, presence) : Bool` defaults to false. Idle cleanup calls this pure, nonblocking predicate with cloned state for an expired offline member while another socket remains connected. Returning true keeps the seat without updating activity. The next pass reevaluates the decision. A fully offline room follows normal cleanup. This hook cannot override explicit leave, deletion, room age limits or capacity.

Custom trusted identity services can configure a transactional `login_authorizer`
and pass optional `step_up` proof to `Store#redeem_login` before new-device
activation; [the server-only contract](TRUSTED_LOGIN.md) defines authority, limits
and exact retries. The canonical HTTP Handler and SDK expose no new endpoint.

- `unauthorized/selection_changed`: stop private activity and reconcile the saved identity; never bootstrap a replacement guest automatically.
- `connection_replaced`: another socket took this player's place in the same room. The old socket receives this error envelope before closing; stop automatic reconnection and wait for an explicit reconnect. Membership and RAM state remain. Use a matching SDK; older clients cannot yield this way.
- `session_lost/session_ended`: abandon old RAM commands. Offer a deliberate new session; permanent progress and committed receipts remain.
- `saving_backlog/pending_result`: accepted work remains queued. Pause new play/admission until it settles. A quarantine is visible through effect_error/health and requires fixing its cause.
- `revision_conflict/conflict`: fetch current state or reconcile the exact original operation. Do not change its ID or silently rebase an uncertain intent.
- Timeout/unavailable: may have committed. Read the original receipt or retry the exact intent. An aborted client connection does not roll back the server.
- `rate_limited/capacity/poll_active`: bounded backoff, preserving identity/session.
- `invalid_code`: generic missing/used/expired-code outcome. Keep the candidate proof through uncertain retries. Confirmed mode requires the issuing device's approval before access.

Deletion status is retained for 30 days. It reveals only that operation's outcome and removed public binding IDs, never progress or a usable login proof. Retired binding IDs remain tombstoned so an old secret cannot recreate a deleted account. The consumer must include any additional data owners in its transactional purge hook.

When B deletes its original guest with an unresolved basic transfer, use `auth/delete/with-transfer` with B's current proof and the exact candidate. Deletion retires an unlinked candidate in the same transaction and includes its ID in `removed_bindings`, so a delayed redemption cannot link it. If redemption already linked an active candidate, the operation returns `transfer_completed` and deletes nothing. Recover the linked selection before asking the user to select and confirm deletion of the intended account. Keep the native candidate secret out of logs.

Chat kinds are instance-global, session (room membership), guild (application policy callback), private (canonical participant pair). History/persistence are optional per kind. Default private chat permits authenticated accounts to message each other; game-specific consent/block policy and moderation operations remain application policy.

`Runtime` owns server/ticker/effect workers/cleanup and optional analytics delivery. GET `/health` reports database health, admissions, active sessions, in-flight/pending/quarantined work and safe_to_replace. Its process_uptime_seconds field is monotonic elapsed seconds since process startup. Runtime instances in the same process share the same starting point. A new process starts a new measurement. USR1 drains new work; USR2 resumes. Replacement is safe only after drain, a healthy database and zero active sessions and zero pending/in-flight/quarantined business work. This never makes RAM sessions durable or supplies multi-instance routing.

For one application, `runtime.run(host, port)` binds its listener and installs process signals. To embed multiple isolated applications in one process, construct a separate Store/Sessions/Handler/Runtime per application, prebind **all** `runtime.server` listeners before starting any workers, and run each `runtime.listen` in an observed fiber. The embedding process owns signal fanout, stops every runtime if one fails, and waits for all completions before closing stores. If binding fails, stop all constructed runtimes without starting them. Use fixed server-owned namespaces, ports and allowed origins; sharing a process or database never links accounts automatically. Aggregate readiness and replacement checks across every runtime.

`stop` initiates shutdown; `listen` returns only after admitted HTTP requests, sockets (including authentication setup), business effects and business background workers have joined. Disposable background analytics admission/delivery is detached and is not part of this join or business replacement health; closing Store stops new admission without waiting for a background validator or sender. Active client analytics HTTP requests remain part of the ordinary HTTP request join. `listen(shutdown_timeout: 10.seconds)` raises `shutdown_timeout` if that deadline expires, or `runtime_failed` after an unexpected background-worker failure. A failed join does **not** authorize closing a store or replacing a process as though work had finished. An admitted effect may remain pending in RAM; normal replacement still requires the drain/health gate. A stopped runtime cannot restart. Repeated startup raises `runtime_started` without stopping the active owner.

Ranking pages use `{entries:[{rank:"1",name:"Quiet Fox",score:"100",is_player:false}],player_rank:"500",player_best:"5"}`. Numeric values are decimal strings; the two player fields are null when the player has no score. Ranks are unique positions ordered by score descending, earliest achievement, then account. No account IDs appear in this public projection. Page limits are 1–100. The existing array endpoint retains its previous response shape.

The optional Handler `leaderboard_reader` is a trusted `Fuel::LeaderboardReader`: `(DB::Connection, namespace, actor, board, limit) -> JSON::Any`. Authentication, expected-account, Origin, board and limit checks precede it; the borrowed connection remains within the account's authority boundary. Return only the public page shape, at most 64 KiB, never proofs, profiles or another application's account identifiers. A combined board must define deterministic ordering and source-qualified identities in one database query/snapshot; matching strings from different namespaces or an unclaimed archive do not establish ownership. The default reader uses only the current namespace. This hook supplies no cross-instance session routing or account federation.

For UI telemetry, configure Questmetry `client_events: ["screen_viewed"]` as an explicit subset of the full event schema. It defaults to empty; clients cannot submit authoritative outcome events. The shared boundary validates properties with the configured schema/validator, checks current consent revision, pseudonymizes account/session, timestamps receipt on the server and assigns `source: "client"` with server-owned context. Raw client event IDs are validated and keyed by authenticated account in a separate server-owned domain; they cannot reserve another account's or a trusted event's dedupe ID. It creates no gameplay operation or reward receipt. Responses report `queued`, `duplicate`, `disabled`, `stale` or `capacity`; queued means accepted into a bounded RAM-only buffer, not durable delivery. Each batch is attempted once and may be lost. A request first received after opt-out is not queued; already accepted tail may finish without purge, filtering or a delivery fence. Client-to-backend UI submission is best effort: no gameplay journal or automatic resubmission is created. Business-critical outcomes still use durable session/account effects, with optional telemetry offered after commit. Never accept free text, names, credentials or arbitrary properties in the event validator. See [delivery and upgrade contracts](SOCIAL.md#questmetry).
