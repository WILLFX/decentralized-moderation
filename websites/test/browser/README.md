# Moderator browser acceptance

Build the moderator with `bash websites/scripts/build.sh moderator`, then run from
the repository root:

```sh
python3 websites/test/browser/serve_moderator.py --output websites/receipts/moderator-ui
```

The helper prints its fresh URL and writes a public profile and session record.
It serves the normal built Rust/Wasm assets after checking their manifest hashes.
Only the HTML entry gets a test-provider bootstrap and guarded loader. Use a fresh
browser context without a real injected wallet. If a provider already exists or
the synthetic provider cannot be protected against replacement, the built
application is not started. The fixture must never fall through to a real wallet.
All listeners bind loopback. No RPC is forwarded, key used, or real transaction
sent. Stop the helper with Ctrl+C when inspection is complete.

This fixture checks the human-facing workflow, not contract execution or human
judgment quality. Existing contract tests remain the rule oracle. Two cases have
authenticated metadata that declares `image` with `text/plain` content. The content
is a plain text note. Case 17 is LIST; Case 18 is REMOVE targeting Case 16.

## Actor sequence through normal controls

1. Open Source & wallet, select the generated profile and review the candidate.
   No wallet access occurs before explicit connection. Choose Use reviewed profile,
   connect the synthetic account and verify deployment. Browse cases must expose
   checked rows that open the case workspace without supplying hidden case IDs.
   Read each case and load its review documents. The complete declared metadata,
   practical LIST/REMOVE question, removal target and equal practical choices must
   be visible. Open the content separately and read the pinned guidelines.
2. Open Recovery and create synthetic encrypted storage through the UI. Return to
   the case, acknowledge the reviewed documents, save a private choice, export
   recovery, select the saved file and verify it. Commit remains blocked until
   exact recovery is verified. Preparing only saves locally; the on-page action
   review and saved label must agree on its effect. A change must not
   discard earlier secrets or replace an attempted or uncertain choice. The
   current-session Change choice route requires fresh recovery verification. Check Cancel before
   choosing Continue with this action, including cancellation after navigating to
   another workspace. Focus must remain in a visible task. Continue must refuse
   if the account, case or private-storage context changed.
   Save Do not list for Case 17 and Remove for Case 18 as known-answer fixtures.
   Export a combined recovery file after both choices exist. Do not record its
   password, choices before reveal, or salts in a public evidence report.
3. Commit each choice through the UI. Inspect the original pending account, chain,
   case and action across navigation. A late response must not steal the selected
   workspace. Check the returned receipt, then use the retained case follow-up to
   collect fresh evidence. Reload, reacquire/accept the profile, reconnect, unlock
   and Refresh my work. Find both cases without supplying their IDs to the actor.
   Checked own duties must precede waiting/preparation/settled work, with explicit
   known-case coverage and failed reads. No partial batch may claim a global
   urgency ranking. Opening a work row refreshes evidence and identifies the duty.
4. After the observer selects finality-lag mode, open a committed case and Check
   reveal readiness. It must refuse. In reveal mode, fresh readiness may pass;
   Reveal must still run the original full guards. Reveal both choices. The model
   independently verifies that each revealed choice/salt hashes to its commitment.
5. In finalized mode, find and settle both votes through My work. Each becomes
   settled, with no further vote action required. Check the receipts separately.
6. Restore the combined recovery via the UI in a fresh storage origin. The same
   helper also accepts `localhost` instead of `127.0.0.1`, providing an isolated
   origin for this check. Download its matching profile from `/fixture/profile.json`.
   Check that import into an existing locked vault refuses overwrite and displays
   the safe alternative; do not clear the original vault.

Case/context changes must invalidate previous review and choice readiness. A
same-case refresh may retain acknowledgements only while their complete review
binding remains unchanged. Returning to the tab must prompt a fresh read without
erasing the saved choice or stealing focus. Evidence age is a local estimate,
not a countdown that authorizes a reveal. Check task-local feedback and keyboard
navigation. No observer-supplied hidden field or case ID may replace navigation.

Challenge stays gated on legacy deployments. The current execution-bound contract
and its focused fixture are described under Bound challenge checks below.
Current-session correction of a provably unsent private choice and interrupted
request recovery have separate checks. They preserve earlier secrets and unknown
sends; a missing hash or chain record never proves no send. Use the interrupted
moderator fixture below to exercise the durable pre-send journal.

Repeat setup, populated work, case review, recovery, reveal, receipt/follow-up and
failure states at narrow/intermediate/wide widths, portrait/short-landscape heights
and enlarged text. `/fixture/viewport?width=320&height=640` embeds the actual guarded
application; `&text=200` doubles root text through a test-only stylesheet. Check
scroll width, reachable controls and visible keyboard focus. These checks do not
establish physical-device, actual browser zoom or screen-reader acceptance.

## Observer controls and evidence

The observer may POST `{"mode":"finality-lag"}`, `{"mode":"reveal"}` or
`{"mode":"finalized"}` to `/fixture/control`. Each prepares a separate
UI read-state checkpoint with block timestamps and heights; it does not change any
existing local session or public chain. Repeating a mode refreshes evidence time.
No accelerated-clock claim is made: the fixture uses the actual browser wall clock
and current timestamps, with finalized state deliberately outside or inside REVEAL.
These checkpoints are not a coherent continuous blockchain history. Old eth_call
pins are refused after a checkpoint changes. The finality-lag case verifies the
UI's refusal when the finalized case is outside REVEAL; it does not establish
canonical-history correctness or network finality. Existing guard/protocol tests
and real provider evidence supply those separate checks.

`/fixture/status` reports synthetic sends and revealed/settled state without salts.
Capture the build/session identity, visible checkpoints, failures and assistance.
Distinguish this model from actual contract/provider behavior. A real injected
wallet path and short uncoached human comprehension checks remain separate evidence.

## Moderator timing checkpoints

For focused deadline and draw guidance checks, use
`serve_moderator_timing.py --output <local-evidence-directory>` with the same
built moderator assets. Its generated session identifies a synthetic provider
with no RPC forwarding or signing. Keep captured recovery and browser evidence
outside the source tree and website packages.

First save, back up and commit one synthetic vote through the normal controls.
POST `{"mode":"reveal"}` to `/fixture/control`, then check readiness. Inspect
the check time, latest/finalized sources, conservative remaining seconds and
configured budget. Check `budget-above`, `budget-at`, `budget-below` and
`window-expired`. These prepare 121, 120, 119 and zero conservative seconds
at the first finalized guard read, before real read time is deducted. Record the actual displayed values: crossing
a wall-clock second can reduce them. Native tests establish the exact cutoff.
No browser clock is replaced, and an advisory pass must never authorize a send.

Also inspect `finality-lag`, `stale-head` and `read-error`. A failed read must
replace an old pass with an unavailable result. After an advisory pass, change
to a short budget before revealing; no wallet send may follow. For the second
disclosure guard, prepare ample `reveal` evidence, open the normal reveal action
review, then POST `{"command":"wallet-boundary","mode":"finality-lag"}`.
Continue through the UI. The observer switches evidence at the next
`eth_accounts` read. `/fixture/status` records the preceding finalized reads and
wallet calls; verify that the repeated guard refuses before any reveal send.

These are legacy-deployment draw checkpoints: `draw-before`, `draw-at`, `draw-first`, `draw-near`,
`draw-last` and `draw-expired`. They place the observed height at T−1, T, T+1,
T+249, T+250 and T+251. Refresh case evidence at each checkpoint. Inspect case
facts, the primary next step and phase controls for recorded voters and
non-voters. The browser withholds a new draw at an already observed T+250;
the legacy execution window remains T+1 through T+250 inclusive. The current
recovery-capable protocol is exercised by serve_outcome_recovery.py below.
Open a draw review at T+249, change the checkpoint to T+250 or T+251 and
continue: fresh preparation must refuse. This helper does not execute draws.

Use `commit-b` to check the effective B deadline before stored A phase
synchronization. Use `reveal-closed` to check explicit phase-advancement
guidance. Legacy expiry must retain saved work and explain that this contract has no
target replacement or timeout escape; it must not invent settlement or refunds.
These prepared checkpoints establish UI behavior only. They do not establish
continuous chain history, actual wallet inclusion, or human understanding.

## Publisher wallet intent and recovery

Publisher profiles now load as candidates. Review their fingerprint/deployment
identity and choose Use reviewed profile before connecting. The fixture serves
its public profile at `/fixture/profile.json`; save those exact response bytes
and run `tools/publisher_setup.py` to create a realistic setup link. The saved
indented `profile.json` is for local-file checks and need not have the same exact
bytes as the HTTP response. Opening a link only fills inputs. Check `profileReads`
and `walletCalls` to establish no automatic fetch or wallet access.

Before payment, inspect the content and acknowledge the exact reference. The
fixture's original content is a short plain-text note. Local Bee settings can be
overridden with the `localhost` alias, another synthetic batch and a dummy local
authorization header. The observer logs only authorization presence, never its
value. Loopback CORS preflight permits the known upload headers and caller origins.

Build with `bash websites/scripts/build.sh publisher`, then run:

```sh
python3 websites/test/browser/serve_publisher.py --output websites/receipts/publisher-ui
```

This reuses the isolated provider, guarded entry, asset verification and loopback
server above. The publisher fixture enables controlled wallet events through an
external same-origin script; the production content security policy remains in
force. It holds each wallet send until an observer resolves it. The normal built
Rust form prepares the exact metadata and performs its actual journal/receipt checks.

Use the generated publisher profile, the known plain-text content reference from
the moderator fixture, a title and topic `biology`. Preview the metadata, load the
pinned guidelines, acknowledge and upload it through the normal controls. The
publisher fixture uses 16 decimal places: its 0.01 TEST minimum is exactly
100000000000000 base units. Refresh balances and deliberately choose the minimum
or enter another fee; ordinary refreshes must not overwrite that choice.
Approve exact fee to hold
the request. Inspect its saved account/chain/destination/amount, check that edits
are disabled, and attempt an ordinary edit without forcing a disabled control.

The observer uses `/fixture/control` with JSON commands:

- `{"command":"account","byte":"60"}` changes the synthetic wallet account and
  emits an EIP-1193 event. The old request must remain visible. Byte `50` restores
  the initial account. Reconnecting must recover the old account's saved requests.
- `{"command":"release","result":"broadcast"}` returns the original hash.
  `reject` returns code 4001 without a send; `unknown` records a synthetic send but
  loses the returned hash. No branch contacts an actual wallet or network.
- `{"command":"mine","hash":"<original hash>","kind":"replacement"}` prepares
  an exact same-nonce speed-up receipt. Kinds `original`, `cancel` and `wrong-nonce`
  prepare an original receipt, an empty zero-value self-transfer cancellation or
  a negative-control receipt. `drop` removes an original transaction lookup so
  retained nonce evidence can be tested. `allowance` resets the model allowance.

Treat the observer's transaction hash as the wallet-activity input a person would
copy. Select the intended request through its visible recovery card; do not inject
the selection into application state. Check a wrong nonce and a different saved
request's receipt before checking the intended replacement. The selected request
must remain unresolved after those refusals. Recovery must preserve the original
hash, retain other records and send no new transaction. A cancellation must not be
reported as publication or fee-approval success.

Repeat with an explicit rejection and a lost response. An unresolved approval must
block a later matching send. A matching mined post-request hash can reconcile a
new no-hash record; old receipts and ambiguous records must not clear it. Reload
and reconnect to check retained history. Imported files supply hints only: nonce,
starting-block and terminal-resolution authority are removed before merging.
Distinct uncertain requests must survive even when their calldata is identical.
Older/imported no-hash records without a trusted request boundary remain guarded.

The payment task has direct Check fee approval receipt and Check submission
receipt controls. Check an unmined approval, then a sufficient allowance before
checking its receipt: the unresolved journal must still block submission. A
verified approval receipt refreshes the current allowance but does not submit.
Existing sufficient allowance skips approval only when no uncertain approval
blocks the context. Inspect both readable and exact pending amounts.

Additional observer commands prepare only synthetic funding/read states:
`{"command":"funds","allowance":"100000000000000","balance":"0"}` changes
the indicated exact amounts; `minimum` is also supported. `fail-funds` with
`enabled:true` refuses funding reads. `wallet-chain` with `chainId:1` changes the
synthetic wallet network while the selected RPC remains on Chiado. Use these to
check insufficient funds, stale/failed reads and network guidance. Neither a
read-state change nor an enabled UI control may send a transaction automatically.

These are prepared UI/RPC states, not continuous blockchain execution. Existing
contract tests remain the protocol oracle. The fixture does not establish actual
MetaMask panel behavior, genuine user comprehension or independent moderation.

## Publisher drafts and publication follow-up

Before loading a profile, type incomplete authoring text, save a draft file and
reload the tab. Check that the exact text returns without an acknowledgement or
upload proof. A second tab must keep its own draft. The observer command
`{"command":"authoring-storage","fail":true}` makes only tab-authoring writes
fail; entered text and file export must remain usable. Set `fail` to `false` to
restore normal writes. Authoring files must never include profile credentials.

Mine an original submission through the observer and check its receipt through
the interface. Find the resulting case in My publications after reload and
reconnection, without supplying a case ID. Opening its card rechecks the saved
receipt, exact intent, current case and index membership. Imported case references
are hints only and must not replace the receipt-derived case identity.

`{"command":"case-state","caseId":19,"state":"approved"}` prepares a final
approval and current membership. `removed` clears current membership while keeping
that historical approval. Use a separate submission for `unresolved`, which
prepares the refundable fee. Verify refund availability, withdraw it through the
held wallet request, mine/check its receipt and refresh the publication to see
zero refund remaining. These are synthetic UI states; they do not run moderation
or establish actual chain transitions. Unlike the moderator fixture, the publisher
model retains immutable read snapshots so receipt checks can revisit the original
submission block after current case state changes.

## Publisher journal capacity and archive acceptance

The observer command `{"command":"seed-journal","count":100,"uncertain":0}`
installs a synthetic prior journal through the test-only provider event route.
Use a fresh origin/context for each scenario. These are prepared local-history
facts, not a claim of 100 prior real transactions. `uncertain:1` or `100` creates
mixed or wholly unresolved history. Read the history through ordinary controls.

At capacity, download an archive backup, select the actual download, verify and
archive it through the UI. Test a wrong file first. Full records must remain in
paged history, reload must preserve the archive, and an uncertain record must
survive. After a new explicit synthetic submission, archive its confirmed record
and open it through My publications. No copied case ID should be needed.

`{"command":"history-storage","fail":true}` makes only publisher journal
writes fail in the test tab; false clears the fault. Use it after a wallet request
is held to check that the returned hash remains in an exported history page.
Use it on archive commit to verify that a failed single write retires nothing.
A second tab shares the local history and Web Lock. While one tab holds a wallet
request, another mutation must refuse without queuing. After confirmation/archive
in the second tab, retry the first tab's save and check that the newer result and
archive remain. Stop helpers only when no synthetic wallet request is awaiting.


## Reader find-and-open fixture

Build the search site, then run:

```bash
python3 websites/test/browser/serve_search.py --output /tmp/reader-ui
```

The saved session provides a loopback URL, a public profile URL and its fingerprint.
The helper serves the unmodified production search assets and a separate content
origin. There is no injected wallet, private dependency, signing or external RPC
forwarding. The category JSON is saved beside the session. Prepared states are
changed through a JSON POST to `/fixture/control` with `mode`: `normal`, `removed`,
`tamper`, `unavailable`, `rpc-failure`, `replaced` or `slow`. These are controlled
read states, not a continuous blockchain simulation. Status reports the read
methods observed. `test_search_fixture.py` checks the supplied ABI/documents;
actual browser tasks exercise the production Rust interface.

Browser tasks: review a source and reject a wrong fingerprint; Enter a mixed-case
topic; continue bounded collection; compare similarly titled items; edit without
applying; move Next/Previous at the original block; check a named row and Tab to
its separate opening link; inspect the opened text; recover from metadata/RPC
failure; refuse tampering and removed membership; stop on source replacement;
cancel and resume a read; compare category every/any groups and descendants.
Repeat populated, setup, failure and open-evidence states at narrow/intermediate/
wide widths, short landscape heights and enlarged text/zoom. Check focus and
reachable actions, not only absence of horizontal overflow.

The optional `/fixture/viewport?width=320&height=640` page embeds the real reader
in a viewport of that size, so media queries use the embedded window dimensions.
`&text=200` adds a test-only stylesheet that doubles root text size. The normal
route serves the exact packaged HTML. Embedded viewport and enlarged-text checks
are not physical-device tests, actual browser zoom or screen-reader acceptance.


## Publisher workspaces and responsive checks

The publisher starts in Editor; source setup is a separate navigation choice.
Use Review publication to build the immutable review, then load verified
guidelines, inspect/acknowledge the exact content, upload metadata, read balances
and choose a fee deliberately. Receipt-derived submissions are returned through
My publications; saved-request cards own recovery. During an open synthetic wallet
request, navigate without editing its locked fields and verify that the original
intent and local record stay visible. After a late response, the selected view
must remain selected. Reload and reacquire the profile/account before checking a
saved case; do not copy a case ID as a substitute for the return route.

`/fixture/viewport?width=320&height=640` embeds the guarded test application in an
actual document viewport. Add `&text=200` to double root text through a test-only
stylesheet. This does not change the production CSP or package. Check editor,
review, pending intent, local errors, saved requests and populated publication
states at phone/tablet/laptop/desktop widths, short landscape heights and enlarged
text. Measure scroll width and focused-control visibility; never hide overflowing
evidence as a repair. These checks are not physical-device, actual zoom or
screen-reader acceptance. Test helpers and observer controls are excluded from
public website collections.


## Wallet choice and provider sessions

`serve_wallet_selection.py` serves the built moderator or publisher with two
independent synthetic EIP-6963 providers. Their accounts differ and the browser
default intentionally points at Beta while the user can choose Alpha. No key,
real extension, external RPC or chain transaction is used.

```sh
python3 -m unittest discover -s test/browser -p 'test_wallet_selection_fixture.py'
python3 test/browser/serve_wallet_selection.py --role moderator --mode multi --output /tmp/moderator-wallet-selection
python3 test/browser/serve_wallet_selection.py --role publisher --mode multi --output /tmp/publisher-wallet-selection
```

Modes `single`, `announced-only`, `legacy` and `none` check a single announced
provider, discovery without window.ethereum, the
window.ethereum fallback and no wallet. Read the generated `session.json` for the
local URL and public profile. Discovery should not request accounts. Test the
normal profile/choice/Connect flow through the UI.

The loopback observer can queue `selection-event` commands for `replace-default`,
`emit`, `remove-failure`, `register-failure`, `duplicate` and `late-beta`. Each
processed event is acknowledged in status. `hold-selection-send` and
`release-selection-send` hold the synthetic wallet response without holding the
observer lock. Inspect `selectionCalls` and `sends` to establish which provider
received the actual request. Both approval send paths validate sender, chain,
recipient and exact calldata; these prepared states do not implement consensus
or prove real-wallet compatibility. Source profiles and browser evidence stay
outside public website packages.

Use `--same-account` to give both synthetic wallets the same public address.
Provider choice and event ownership must still stay distinct; matching account
and chain values alone do not establish which wallet received a request.

Use `--authorization-event` to emit accountsChanged inside the account-access
response. First connection must accept the authorized account without requiring
a second attempt, while subsequent context changes still invalidate readiness.


## Interrupted moderator requests

After building the moderator, run `python test/browser/serve_moderator_requests.py
--output <local-directory>` from `websites/`. This keyless loopback fixture uses
only synthetic approvals. Its wallet refuses a send without the journaled nonce.
Observer controls cover a held or lost response, rejection, storage write failure,
wrong-nonce candidates, finality, speed-up and cancellation. Actors still use the
normal interface. `python -m unittest test_moderator_requests_fixture -v` runs the
observer checks from `websites/test/browser/`.

These are prepared UI checkpoints, not a coherent consensus or contract test.
Restart after rebuilding: the fixture refuses changed asset bytes. Keep separate
checkpoint outputs; do not present an observer speed-up/cancellation as evidence
of a real chain replacement. No real key, extension, RPC or deployment is used.


Use `--timing` with this fixture to compose the existing reveal-boundary observer.
A public synthetic commitment and an encrypted recovery fixture model a returning
moderator. The wallet-account boundary can change finalized evidence after the
first guard, so the second guard must refuse without a send. A retained pre-wallet
`not_sent` record must never clear a separate later unknown send. No live chain
clock is modified, and these checkpoints are not consensus evidence.

## Bound challenge checks

`serve_challenge_intent.py --output <local-directory> --capability bound` serves
the built moderator with a keyless, loopback-only prepared challenge window.
Use `legacy`, `unknown` or `malformed` to check unsupported capability gates.
The fixture accepts only the new selector and exact zero-value/nonce envelope;
its receipts distinguish successful and stale reverted requests. Existing observer
commands can hold/release a request and lose its reply. `advance-challenge-review`
changes the prepared round/outcome while a request is held. No request is forwarded
to a chain or extension. These checkpoints do not establish live inclusion,
network consensus, wallet-extension support or independent moderator judgment.


### Original outcome recovery

`serve_outcome_recovery.py --output <local-directory>` serves the packaged moderator
with a keyless synthetic provider. Prepared checkpoints cover recovery, the last
history block, expiry, cached hashes beyond the boundary, and initial refunds.
The observer checks exact calldata/nonce and can lose a send response. It is not
an EVM implementation; contract regressions establish settlement semantics.

The moderator `/fixture/viewport` frame follows the available window automatically,
including orientation changes. It has no width/height settings form. Explicit
`?width=320&height=640` dimensions remain available only for repeatable synthetic
layout checks; `&text=200` doubles text. Product layouts use CSS and the viewport,
not device-name detection or a user-selected orientation.

### Publisher recovery follow-up

`serve_publisher_expiry.py --output <local-directory>` serves the built publisher
with prepared publication history. Use recoverable, boundary, expired, cached,
unverified, initial-final and challenge-final checkpoints to inspect compact
publication summaries and detailed evidence. The 8,191-block history boundary,
indefinitely cached original hash and unavailable-capability states must remain
distinct. A boundary alone cannot establish a completed expiry or refund.
Refund controls depend on the verified amount owed. This fixture does not execute
contracts; the Solidity regressions establish financial consequences.
