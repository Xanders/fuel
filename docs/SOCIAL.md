# Chat, names and analytics

## NameDictionary v1

The consumer supplies the dictionary. Fuel does not choose a game's naming policy or guarantee uniqueness.

```json
{"version":1,"fallback":"en","separator":" ","locales":{"en":[["Bright","Quiet"],["Fox","Owl"]],"fr":[["Petit"],["Renard"]]}}
```

Each locale contains ordered token pools. A full-name list is one pool; compositional names use multiple pools. Locale lookup uses normalized exact locale, then primary language, then the declared fallback. Selection is deterministic: for each zero-based pool index, SHA-256 of Crystal/JSON tuple `[1,seed,index]`, first eight hex digits interpreted unsigned, modulo pool size. Join selected tokens with separator (default one space). Persist chosen display names when dictionary changes must not rename existing players. Dictionaries and their licensing belong to the consumer. Names may collide; use account identity separately.

## Censor

`Censor.new(words, variants)` treats all dictionary words and glyph variants as literals. It matches case-insensitively at Unicode letter/number boundaries and tolerates punctuation between letters. Matched text is replaced by asterisks. It is a small filter, not comprehensive abuse detection: contextual abuse, every Unicode confusable and adversarial language require game policy/moderation. No automatic punishment is imposed.

Chat messages are plain text. Render as text, never raw HTML. Membership is checked on reads and writes. Guild membership is checked again on each request. Optional persisted history is available only for guild/private channels and is bounded even when a channel becomes inactive. Session/global history stays in RAM. The supplied HTTP adapter limits message frequency per account. Game-specific mutes/reports and block policy need application hooks.

## Questmetry

Analytics is optional and off until constructed/configured. No public browser write key or server ingestion key is included. The server adapter accepts only configured event names/properties and bounded primitive values. Do not allow chat text, names, arbitrary URLs, account IDs or tokens as properties. Configure separate namespace/environment/version and server keys. Account/session identifiers are keyed pseudonyms.

Use `enqueue(connection,...)` inside the result transaction for authoritative events. `capture` is available for independent non-result milestones. The outbox keeps one stable event ID and original timestamp through delivery retries. HTTP 202 removes the row; 429/5xx/network errors back off; permanent 4xx removes invalid work. Each drain processes at most ten rows. The queue is capped at 10,000 rows; monitor capacity and permanent rejects.

Opt-out is stored per account, prevents new product events and deletes undelivered events. It does not revoke the account or alter gameplay. Downstream retention/deletion is the consuming game's analytics policy. Fuel neither creates analytics projects nor changes service retention.
