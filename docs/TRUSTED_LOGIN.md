# Trusted issuer enrollment and login

For a custom identity HTTP service use `require "fuel/identity"`; it loads the
same Store and supporting primitives without the canonical game Handler/Runtime.
`require "fuel"` remains the complete game entrypoint. The split avoids Crystal
1.22.1 code-generation failure when canonical game handlers are loaded but not
constructed while an unrelated HTTP server is embedded. The isolated HTTP smoke
`crystal run spec/identity_entrypoint.cr` guards this integration boundary.

This optional server-side API is for an application which deliberately lets one
trusted issuer enroll an identity and grant a new device access. It is separate
from ordinary owner-confirmed device transfer. The canonical HTTP Handler exposes
none of these entrypoints; the embedding application must authorize every issuance,
validate the intended subject and implement exact Origin/Fetch Metadata protection
and host-only Secure HttpOnly cookies for browser candidates.

- `Store#enroll_account(request_id)` creates a permanent account without a device.
  Retry the same application-generated immutable ID after an unknown outcome.
  Capacity and a namespace-global issuance budget apply. The ID maps to the same
  account until deletion, after which it remains a tombstone and raises `deleted`.
  It is not a secret and never grants account access.
- `Store#issue_login(account, request_id)` issues a distinct 16-hex-character code
  for five minutes. Hyphens and case are presentation only. The receipt contains
  `id`, `code` and Unix `expires_at`. Only the trusted server may call this method;
  a public account ID does not authorize it. Exact retry returns the same code and
  original expiry, not another grant. Reissuance with a new ID cancels previous
  unconsumed grants for that account. An issuance ID cannot target two accounts.
- `Store#redeem_login(code, candidate, source)` consumes the code and attaches a
  previously unbound, privately retained `Credential` atomically. Save/prepare that
  proof before submission and keep it after an unknown response. Retry that same
  code and proof; a different candidate, forged/revoked proof, expired/cancelled
  grant, occupied or retired binding returns `invalid_code`. Exact successful
  retries check current binding authority; they cannot resurrect revoked access.
  Receipts are retained until account deletion so a delayed issuance retry cannot
  recreate an already expired or consumed code. Exact consumed-proof retry still
  requires an active binding; ordinary `authenticate` has no server expiry.

Redemption budgets are durable and committed before validation: 200/namespace/minute
and 10/source/minute. Issuance is at most five new grants/account/minute. Source
identifies the actual socket; an embedding reverse proxy needs its own trusted
edge admission. Do not trust arbitrary forwarded IP headers.

Grant codes have their own purpose-separated HMAC domain under the transfer key;
the database stores only keyed verifiers. Reproducible exact issuance receipts are
derived from subject and request ID; protect the transfer key and never log
receipts/codes or pass them in URLs. After transfer-key rotation, use a new issuance
ID; previous pending grants are intentionally invalid. Enrollment receipts
intentionally persist, like retired-binding tombstones. Grant receipts persist
until account deletion, like permanent operation receipts; budget this storage
alongside account/device records.

Use ordinary `authenticate`, `with_actor`, `bindings`, `revoke` and account deletion
after redemption. No provisioning/master device is created. Migration 006 adds
tables without changing existing state; account deletion removes grants and
tombstones enrollment receipts. Owner-confirmed six-character transfers retain
their phrase confirmation and existing routes. No native/browser SDK flow is
provided for this optional server-only capability; consumers own thin retained-proof
activation UX, not a parallel verifier/store.

## Optional authorization before activation

Configure every Store used for trusted redemption with `login_authorizer:` when
the application requires an additional factor. `Fuel::LoginAuthorizer` is
`Proc(DB::Connection, String, JSON::Any?, Nil)`: connection, server-only account,
and optional proof. Call `redeem_login(code, candidate, source, step_up: proof)`;
the default proof is nil. A supplied proof must be a JSON object of at most2KiB
or redemption raises `invalid_proof` before invoking the policy. Proofs are copied
for the callback and are neither persisted nor logged by Fuel.

The callback runs with the account and grant locked, before the first binding
INSERT. Return nil only when permitted; raise on missing, invalid or unavailable
verification. A policy can raise neutral `Fuel::Error` codes such as
`factor_required` or `invalid_factor`; never include an account ID, seed, code or
proof in errors. The application may ask for the factor while privately retaining
the original code and candidate. No account is returned and no binding becomes
active on a failed check. There is no public pending-account lookup.

Use only the supplied connection for transactional security state, with lock order
account then application security row. Factor replay counters or one-use recovery
records commit atomically with the new ordinary Fuel binding and consumed grant;
errors, occupied/retired candidates or wall-clock grant expiry roll them back.
The hook must be fast and database-local: no network, nested Store calls/new pooled
connections, irreversible effects, or catching a denial and returning success.
Configure the same policy on every redeeming Store/process, including after reopen.
An unconfigured Store deliberately retains the original trusted-issuer behavior.

With a configured authorizer, attempts against a currently live unconsumed grant
also cost at most10/account/minute. That budget commits **before** the activation
transaction, alongside the existing independently committed source/global limits;
policy failures cannot refund it. Do not implement a second counter inside the
callback transaction and assume it survives rollback. Consumed/expired/cancelled
grants do not charge this additional account budget at the initial lookup.

An exact consumed-code retry verifies the same active candidate and returns the
account without running the authorizer or consuming a factor again, even after the
grant's original expiry. Forged/revoked/deleted proofs and other candidates still
fail. This is recovery of an already authorized binding, not a new activation.

Fuel does not implement TOTP, seed encryption, factor enrollment/recovery UX or
sensitive-operation step-up. Those are application policy/state using this atomic
boundary. This hook protects only trusted `redeem_login`: authentication of existing
bindings, bootstrap, ordinary owner-confirmed transfer and other application login
methods are unchanged. Do not expose an alternate attachment route that bypasses
the application's required factor. Browser Origin/cookie and retained-proof
requirements above still apply; never store transient factors in a client journal.
