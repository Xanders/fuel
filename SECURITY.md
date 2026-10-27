# Security

Report vulnerabilities privately through the maintainer's GitHub security advisory channel. Do not include real device secrets, transfer codes, database URLs or player data in public issues.

Fuel's baseline validates authentication, current binding revocation, member access, epochs/revisions/input order, resource bounds and game-owned legal-action hooks. This is basic security/anti-cheat infrastructure, not a claim that arbitrary client results are trustworthy. Rules must enforce phase, turn, ownership, speed/range/economy and scoring constraints relevant to each game.

Device secrets are 32 random bytes. Only purpose/namespace-scoped HMAC-SHA256 verifiers are stored; separate server keys protect device and transfer domains. Short account-transfer codes are six distinguishable ASCII characters, five minutes, owner-confirmed and one-time. Code normalization rejects Unicode lookalikes. Permanent guest accounts and active bindings have no server expiry.

Keep server keys outside database backups and Git. Preserve previous device keys during ordinary rotation via `previous_device_keys`; valid logins rehash to the new key. Rotation is not revocation. Do not discard old keys while un-upgraded permanent bindings still depend on them. Pending transfer codes may be reissued when the transfer key changes.

Candidate status and pending-proof retries use the same retained-key verification and rehash policy as active logins. A device-key rotation with retained keys does not abandon a linked transfer awaiting native activation.

Browser cookies are Secure, HttpOnly, host-only and SameSite=Strict; mutating requests require an exact allowed Origin. Native storage is an application-supplied OS-backed secure vault. Browser clearing or loss of the only device can still destroy access; Fuel does not recover accounts from public IDs. A new transfer candidate does not overwrite the previous guest.

Cookie slots are namespaced by the configured store namespace, not shared global names between applications. Browser selection retries use frozen public binding IDs and expected account checks; unknown outcomes must be reconciled before new private actions. SDK browser journals contain public selection metadata and deletion-operation proofs, never device secrets. Web Locks serialize record changes across tabs; storage failure is explicit. Native record ports must use actual OS secure storage and one serialized vault per record pair.

Deleting an account requires confirmation, expected owner and a saved random deletion proof. Its keyed status receipt survives for 30 days and reveals only the deletion outcome/public binding IDs. It is not a general account recovery secret. Old deleted binding IDs cannot bootstrap again. Deleting the current account does not erase another retained account's proof. Revoking the last active binding requires separate confirmation.

Public account actions are allowlisted independently from server effects. Sorted participant locks protect transfers; binding authority is revalidated after those locks and retained through short private delivery boundaries. Domain hooks receive copied JSON and bounded descriptors, not credentials or database/network handles. Game code must still validate legal quantities, generations, ranges and reward eligibility.

The application must provide HTTPS/WSS, database access controls, secret handling, proxy-level connection/header limits, game-specific deletion hooks and a plain-text chat renderer. The source-address limiter uses the socket IP; behind a proxy add trusted-source admission at that proxy. Fuel does not trust arbitrary forwarded headers.

Long polls revalidate after waits; sockets revalidate before inputs and snapshots. No plaintext credential is accepted from database verifier columns. Database read compromise still reveals stored game/chat/progression data; HMAC does not make that data anonymous.

Only Fuel-owned data is purged by the default deletion route. The consuming application must include all additional data owners and provider obligations in its deletion workflow. No payment integration is implemented in this preview.

Browser Fetch Metadata also rejects cross-site/same-site API requests outside the same origin, including cookie preparation. An unrelated navigation cannot replace an existing Strict cookie merely because the browser omitted it on that request. Native clients without browser Fetch Metadata still require their own proof.

Explicit browser guest recovery replaces only a definitively rejected active proof through `auth/prepare?new=true`, under the same Origin/Fetch Metadata checks. Valid active proofs and the previous/candidate slots are preserved. Ordinary preparation and storage failures do not rotate existing proofs.

Reading browser selection does not mutate cookies, including rejected proofs. A rejected current binding exposes only its own public ID with null account metadata, so an explicit previous-account switch can still freeze its source. Removing that proof during an availability check would let later ordinary bootstrap create an unintended replacement guest.
