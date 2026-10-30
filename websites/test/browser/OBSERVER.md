# Browser observer reference

Use these commands with the [browser fixture tools](README.md). They change
synthetic provider responses and prepared data. Perform participant actions through
the visible application; do not write its hidden state or delete uncertain records.
Use a fresh browser context without a real injected wallet. Keep outputs local.

## Start and send controls

Build the relevant application, then start one helper from the repository root:

```sh
python3 websites/test/browser/serve_publisher.py --output websites/receipts/publisher-fixture
python3 websites/test/browser/serve_moderator_requests.py --output websites/receipts/moderator-requests
python3 websites/test/browser/serve_search.py --output websites/receipts/reader-fixture
```

Run each helper in its own terminal when needed. Use its printed URL and generated
profile/session files. Restart it after rebuilding assets. Commands below go to
that helper's **application origin**, not its separate content origin. For example:

```sh
FIXTURE_URL=http://127.0.0.1:PORT
curl "$FIXTURE_URL/fixture/status"
curl -H 'Content-Type: application/json' \
  --data '{"command":"release","result":"broadcast"}' \
  "$FIXTURE_URL/fixture/control"
```

Replace `PORT` with the current session's port. The POST example is for Publisher
with a request already waiting. Inspect returned JSON; unsupported commands must
not be treated as successful state changes. Hash placeholders below refer to actual
synthetic hashes returned by status or observer responses.

## Publisher requests and receipt recovery

Load the generated profile, connect the synthetic wallet and prepare a publication
through Editor and Review. Use topic `biology`, valid article metadata and a plain
text file. The fixture's minimum fee is 0.01 TEST (100000000000000 base units).
Use the generated profile's upload connection. Load guidelines, inspect content,
upload metadata and refresh the fee through the normal controls.

Every wallet send waits for observer resolution, for up to 240 seconds. Click the
fee-approval button, inspect the displayed pending intent, then use:

| JSON payload | Effect |
| --- | --- |
| `{"command":"release","result":"broadcast"}` | Return the original hash without mining it |
| `{"command":"release","result":"reject"}` | Reject with code 4001 without broadcasting |
| `{"command":"release","result":"unknown"}` | Record a send but lose the returned hash |
| `{"command":"mine","hash":"<original hash>","kind":"original"}` | Mine the original request |
| `{"command":"mine","hash":"<original hash>","kind":"replacement"}` | Mine an exact same-nonce replacement; return its hash |
| `{"command":"mine","hash":"<original hash>","kind":"cancel"}` | Mine a zero-value, empty-data self-transfer cancellation |
| `{"command":"mine","hash":"<original hash>","kind":"wrong-nonce"}` | Prepare a mismatched receipt candidate |
| `{"command":"drop","hash":"<original hash>"}` | Remove that transaction lookup |
| `{"command":"account","byte":"60"}` | Change the synthetic account and emit its event; `50` restores it |
| `{"command":"wallet-chain","chainId":1}` | Change wallet chain while the RPC stays on Chiado; 10200 restores it |

Use a fresh run/context for each recovery branch:

1. Release an approval as `unknown`. Find its hash in `/fixture/status`. Reload,
   reconnect and select its saved request through the interface. Missing response
   evidence must keep the matching send guarded.
2. Prepare a wrong-nonce candidate, copy its returned hash to the selected request's
   receipt input and check it. The request must remain unresolved. Then prepare an
   exact replacement from the original hash and check that returned hash. The
   request must resolve without another send and retain the original identity.
3. Repeat with `cancel`. It must resolve as cancellation, not approval/publication
   success. Repeat rejection separately; that branch records no send.
4. With a held request, change account and inspect the original pending intent.
   Restore account `50`, reconnect and recover the original request. A late wallet
   response must not silently change the selected task.

A sufficient allowance alone must not clear an uncertain approval. Mine/check the
approval and refresh allowance before submitting explicitly. Submission is another
held send: release, mine and check its receipt. **My publications** must find it
again after reload without a manually copied case ID. A different request's receipt
must not resolve the selected record.

Additional public read controls:

| JSON payload | Effect |
| --- | --- |
| `{"command":"funds","balance":"0","allowance":"100000000000000"}` | Set exact balance/allowance; optional `minimum` is also accepted |
| `{"command":"fail-funds","enabled":true}` | Fail funding reads; `false` restores them |
| `{"command":"case-state","caseId":19,"state":"approved"}` | Finalize an existing synthetic submission and set membership |
| `{"command":"case-state","caseId":19,"state":"removed"}` | Remove its membership while retaining approval history |
| `{"command":"case-state","caseId":19,"state":"unresolved"}` | Prepare its refundable fee |

Replace 19 with the submitted case's actual ID. For the unresolved branch, withdraw
the refund through the interface, resolve/mine/check that held request and refresh
the publication. These controls prepare states; they do not execute moderation.

## Publisher archives and storage faults

Use separate fresh contexts for empty, mixed and wholly uncertain history:

```json
{"command":"seed-journal","count":100,"uncertain":1}
```

`count` is at most 100; `uncertain` ranges from zero to `count`. Read history through
the interface. Export an archive backup, select the actual download, verify it and
archive resolved records. Try a wrong file first. Confirm that uncertain records
remain active and full archived records remain readable after reload. Imported
history supplies hints; it must not acquire trusted nonce or send-boundary authority.

`{"command":"history-storage","fail":true}` makes Publisher history writes fail;
`false` restores writes. Apply it while a request waits, release the response and
export retained history. Also apply it before archive commit: failed storage must
not retire records. `{"command":"authoring-storage","fail":true}` separately
fails draft writes; text editing and draft-file export must remain usable.

For cross-tab work, use two tabs on the same fixture origin. While one holds a send,
try a history mutation in the other. It must refuse rather than queue. After the
second tab saves a newer result/archive, retry the first tab's save and check that
it preserves that newer data.

## Moderator interrupted requests

Use `serve_moderator_requests.py` and its generated profile. Connect the synthetic
wallet, verify the deployment, refresh Stake and use **Approve exact stake amount**.
This is the simplest public request for these scenarios. Payloads differ from
Publisher's controls:

| JSON payload | Effect |
| --- | --- |
| `{"command":"hold-selection-send"}` | Hold the next synthetic response before sending |
| `{"command":"release-selection-send"}` | Release the hold; it times out after 120 seconds otherwise |
| `{"command":"lose-next-response"}` | Lose the next send's response after recording the transaction |
| `{"command":"reject-next"}` | Reject the next send without broadcasting |
| `{"command":"wrong-transaction"}` | Return a wrong-nonce candidate for the latest send |
| `{"command":"speed-up"}` | Return an exact same-nonce replacement for the latest send |
| `{"command":"cancel"}` | Return a cancellation for the latest send |
| `{"command":"advance-finality"}` | Refresh synthetic block/finality evidence |
| `{"command":"selection-event","event":{"kind":"request-storage-fault","enabled":true}}` | Queue a moderator request-storage fault; `false` clears it |

Queue hold/loss/rejection controls **before** the UI send. Status exposes
`sendWaiting`, `sends`, `selectionCalls` and event acknowledgements. Release a held
send explicitly. Replacement/cancellation commands require a previous send; copy
the returned hash into that request's recovery input in **Transactions**. Check a
wrong candidate first, then the intended replacement or cancellation. Reload and
reconnect to check retention. Reconciliation must not create another send or alter
the encrypted private vote vault. A storage-fault event must be acknowledged by
the fixture before relying on its effect.

`--timing` composes the moderator timing model for reveal-boundary work. Use its
own controls for those states; public-request recovery does not authorize bypassing
private backup requirements or either reveal guard.

## Reader source changes and interrupted reads

Use `serve_search.py`, accept its generated profile and search `BiOlOgY`. The
fixture supplies five biology items, a two-item display/scan size and a category
file. Use Enter, continuation, Next/Previous, named membership checks and separately
opened content through the visible interface.

Reader controls use `mode`, not `command`:

```json
{"mode":"normal"}
```

| Mode | Prepared condition |
| --- | --- |
| `slow` | Delay each RPC read |
| `removed` | Advance the source and remove the first item's current membership |
| `tamper` | Supply changed metadata bytes |
| `unavailable` | Make metadata unavailable |
| `rpc-failure` | Refuse RPC reads |
| `replaced` | Replace recorded block hashes |
| `normal` | Restore ordinary reads; it does not undo prior block replacement |

Start a slow search, type a new query before completion and check that focus and
unapplied text remain intact. Cancel through the UI and search again. Load results,
set `removed`, then check the first item's current listing. In separate fresh runs,
exercise tampered/unavailable metadata and a replaced source before continuation
or membership recheck. The UI must refuse unsupported evidence and provide its
normal retry/source controls. Return to `normal` for transient failures; restart
the helper/context to reset replacement history completely.

For source selection, use the saved profile URL/fingerprint. Try a wrong fingerprint
before accepting the correct one. After results are loaded, select another source
through the interface and confirm that old results no longer appear as evidence
from the new source. These are different operations from the `replaced` mode,
which changes the chain evidence behind an already selected source.
