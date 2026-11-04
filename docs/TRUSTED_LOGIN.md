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
