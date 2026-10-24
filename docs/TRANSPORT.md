# Compatible transport adapters

`SocketServer` is the shared engine behind the canonical Fuel WebSocket route. Existing applications may use it with their current wire messages, credentials and mutable rules, without installing a second account schema. This adopts transport only; it does not turn retained application services into canonical Fuel services or authorize changing durable session recovery.

Construct `SocketServer.new(allowed_origins, ...)`, then call `upgrade(context) { |socket| peer }` from the application's route. The factory is pure setup; IO and admission belong in `peer.start`. Implement `SocketPeer` or supply `SocketCallbacks` for start, input, snapshot, reliable send and close. The engine owns frames, admission permits, one writer, bounded queues, deadlines and cleanup. The adapter owns authentication and all game effects.

## Admission and authority

GET, Upgrade/Connection tokens, version 13, canonical 16-byte handshake key, absent request body and Origin are validated first. Browser cookies require an allowed Origin. A failed HTTP header flush creates no application peer or permit leak. After transport handoff the engine atomically reserves a global permit before constructing the adapter. A capacity race after the preliminary HTTP check closes the connection before application admission. The default is 128 peers, including unauthenticated setup.

`start(socket)` authenticates an existing cookie/header credential or waits for the protocol's first native authentication frame. A native adapter must reject gameplay before authentication and reject a second identity selection. Authenticate, call `socket.admit(account)` exactly once, then perform admitted effects. Default account capacity is two peers; account permits are not room membership. The unauthenticated deadline is ten seconds. Call `socket.check_open` after awaited work before an effect; a deadline or close must not let late setup enter a game.

Every input and physical private send must freshly authorize. `send_message` must hold the appropriate account/binding guard through `socket.write(raw)`. `send_snapshot` must authorize, project private state and physically write within that same guard. Queuing a string is not authorization to send it later. The canonical adapter keeps `Store#with_actor` around projection/send. Database failures close the peer; cached identity does not grant continued access.

Keep lock order consistent with revocation/deletion and avoid nested account-mutating transactions inside a guard. Prepare a durable profile outside the short guard, then revalidate before applying RAM effects or sending. Admission counter locks contain no DB/IO or game callbacks. Rules must stay fast and nonblocking. Do not hold a global game lock across SQL or a slow socket.

## Bounded delivery

Incoming masked text is assembled with a fixed 4 KiB buffer, default 16 KiB per complete message. Fragmented text, interleaved ping/pong and close control frames are handled; binary, invalid continuation/control/header/UTF-8 and oversized input close the peer. Idle players continue receiving snapshots; no read deadline requires them to send artificial gameplay inputs.

The single writer generates a fresh snapshot at the configured interval (default 100 ms); snapshots are not placed in an accumulating queue. `socket.enqueue(raw)` retains ordered reliable events, default 32 entries and 64 KiB per outgoing message. Overflow closes the peer; the client must reconnect and refetch durable state or explicitly resynchronize. Do not use snapshots or a producer's latest-value map as a reliable event queue. `server.broadcast(account, raw)` enqueues to every admitted peer independently, with fresh authority enforced by each adapter's later send callback. One overflowing peer does not discard another peer's events.

Writes have a three-second IO deadline. Callback/IO failure closes the owner. The global/account permit remains held until its writer's awaited guard/send finishes, keeping failed DB work bounded; slow or failed infrastructure may temporarily consume capacity. Cleanup is idempotent and cannot release another peer's permit. The close callback runs after the server detaches this peer; `server.connected?(account)` reports remaining live peers for application disconnect policy.

`Limiter#check(key, count, seconds)` provides process-local monotonic fixed-window admission with a bounded key set (default 10,000). It raises `rate_limit` or `capacity`. Purpose-specific keys and policy belong to the consumer. Persistent auth/code issuance budgets remain in `Store`; replacing them with a RAM-only limiter would weaken restart protection.

## Client and rollout

Use the companion SDK's shared `FuelHttpTransport` and `FuelConnection` with a thin wire adapter, following its [lifetime/recovery contract](https://github.com/Xanders/fuel-and-flame/blob/main/docs/USAGE.md). Retain exact semantic mutation IDs, credential storage, response/header uncertainty and identity fences. Socket replacement must not dispose HTTP or cancel unrelated requests of the same account.

Follow [incremental adoption](MIGRATION.md): synthetic compatibility fixtures, actual external dependency pins, removed common code minus every adapter line, and independent review. Library tests do not establish a consumer release. One backend instance, PostgreSQL-only permanent data and RAM-only canonical sessions remain deliberate limits.
