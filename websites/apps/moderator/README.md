# Moderator website

A separate Rust/Wasm application with My work, Browse cases, Selected case,
Recovery, Stake, Source & wallet and Transactions workspaces. Navigation changes
presentation only; it does not authorize a transaction or a reveal.

## Review and vote

Get the public moderator profile from the intended deployment operator. Select
the file in Source & wallet, inspect its chain, contract addresses and
guidelines identity, then choose **Use reviewed profile**. Profile acceptance
does not request wallet access. Connect the intended account explicitly and
verify the deployment against its runtime pins. An encrypted recovery file is
not a deployment profile.

Browse cases opens a checked row without creating a vote obligation. The case
workspace keeps its practical LIST/REMOVE question, removal target, submitted
metadata and content route together. Metadata authentication establishes the
bytes, not the truth of their claims. Open content separately and read the pinned
guidelines before acknowledging review. Both practical vote choices have equal
emphasis.

Save a private choice in unlocked encrypted storage, export recovery, select the
saved file and verify coverage for that exact vote. Preparation sends no
transaction. Commitment is a separate reviewed wallet action and creates reveal
and settlement duties. Missing reveal can add frozen time. Change choice is available beside a choice created in the current unlocked session,
before a commit attempt. Save change retains the exact earlier secret, uses fresh
randomness, and requires a newly verified recovery file before commitment. Cancel
makes no vault change. Reloaded, imported, attempted or uncertain choices do not
gain correction authority from missing chain state or an empty request journal.
Wallet/vault context changes invalidate the session authority. Unfinished requests
use the existing Check transaction route; correction never clears them.

The encrypted envelope and authentication domain remain version 1. Payload version
2 adds retained earlier records; version-1 payloads still import. Record bytes and
fingerprints stay unchanged. The 512-record limit applies across active and retained
records. Recovery exports include both; an old file cannot cover a new choice.
Conflicting active imports fail closed. Commitment uses only the active choice;
reveal matches the actual mined commitment across all retained secrets. Older
application builds cannot read version-2 payloads; retain the new recovery file.

## Return and follow-up

My work combines this account/deployment's available private saved votes and
saved public transaction history. Checked own actions come first, followed by
blocked, waiting, preparation and settled work. Coverage and failed reads remain
explicit. Priority applies only to checked known cases; this is not a complete
on-chain duty index. Opening a row reads fresh evidence.

The selected case shows its observed deadline and evidence age. Local elapsed
time is an estimate, not a reveal authorization. Refreshing unchanged case/review
bindings retains acknowledgements. Changed bindings invalidate them. Returning to
the tab prompts a refresh without replacing the saved choice.

Reveal readiness is read-only. Reveal still repeats the unchanged finalized-state
and inclusion-time guards, including the second check immediately before calldata
disclosure. Draw recovery limits remain block heights. A pinned version-1
`outcomeRecoveryOf` response enables original-hash caching and the exact on-chain
expiry path. A cached original hash has no draw expiry. A failed capability read
never enables expiry or proves the deployment lacks recovery. Initial expiry is
unresolved/refundable; challenge expiry settles against the last completed outcome,
which does not prove responsibility for draw failure. Personal vote duties and
public advancement calls stay separate. Challenge requires verified intent-binding
support and binds the reviewed round and outcome. Legacy deployments stay gated.

A wallet request retains its original context across navigation. A returned hash
is not a confirmed receipt: check it in Transactions, then refresh the retained
case before continuing or settling. Before wallet disclosure, a public request journal saves the account, action,
case, destination, calldata digest and starting block. The saved nonce is supplied explicitly in the wallet request. It never
saves vote choices, salts or calldata. Web Locks serialize sends and receipt
updates across tabs. An unresolved request blocks further sends in its account
and deployment; reload does not clear it. Transactions restores the original
context. A wallet-activity hash resolves a hashless request only when the exact
intent, nonce and later mined block match, and the RPC reports chain finality.
Clear user rejection is recorded separately; ambiguous errors remain guarded.

The journal does not replace encrypted vote recovery. It cannot reconstruct
requests made by older builds, survive cleared site data, or automatically resolve
dropped requests or a hashless send whose actual nonce differs from the saved boundary. Same-nonce speed-ups require the verified original transaction; cancellation requires an empty, zero-value self-transfer. Both preserve the original hash and wait for finality. A missing original cannot authorize a replacement. Its 2,000-record capacity
fails closed without pruning. Keep site data and recovery files. RPC observations
do not independently establish consensus. No action is automatically resent.

## Browser checks

Build/package tooling is shared by the three websites. The isolated synthetic
provider and normal-control acceptance sequence are in
[`../../test/browser/README.md`](../../test/browser/README.md).
Check narrow/intermediate/wide layouts, portrait and landscape, enlarged text,
scrolling and keyboard focus. Fixture results do not establish actual wallet
behavior, physical-device support, assistive-technology acceptance or independent
human moderation quality. Private profiles, recovery exports and local receipts
are excluded from public website collections.


Reveal reservation finishes before the second, unchanged disclosure guard. The
success path from that guard to the wallet performs no journal IO. A guard failure
in the still-running pre-wallet path retains an explicit `not_sent` record. Reload,
a missing receipt or a current absence on chain can never make that classification.
If saving the abort fails, its unresolved guard remains in force.

## Bound public challenges

In a challenge window the reader checks `challengeIntentVersion()` at the same
canonical hash as the verified case/runtime. Only a strict ABI word for version
1 enables Challenge. Missing, unavailable, malformed or unknown replies keep the
legacy path blocked. This marker is a capability hint, not proof of safe code.

Confirmation retains the reviewed round and outcome. Fresh pre-wallet evidence
must still match; the three-argument calldata then binds both at execution. The
ordinary public opposing-vote consequences remain. No private vote is prepared.
The exact original public request digest and nonce survive interruption. Receipt
recovery cannot substitute another round/outcome or retry through the old ABI.
No deployment profile, old contract or live request is migrated by this change.
