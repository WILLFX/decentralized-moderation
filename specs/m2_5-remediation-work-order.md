# M2.5 Remediation Work Order — Post Senior-Audit Architecture Fixes

**From:** Fable 5 (orchestrator, M2.5 scoping pass)
**To:** builder
**Base:** `main` after M2 close (PR #5, `19904b8`).
**Branch:** `claude/determined-curie-nkf71s`.
**Trigger:** Independent senior adversarial review of `main` @ 2026-07-16
(1 Critical, 11 High, 4 Medium, plus L-series). Every Critical/High was
reproduced against `contracts/src/Moderation.sol` line-for-line before this order
was written; all confirmed. Three findings overturn deviations we had recorded as
safe (L-2, D-8 "minor", the F2 "benign residual").

This is a **reopen, not a patch pass.** Several fixes are architectural (duty
pool, versioned rulesets, batched settlement, eligibility epochs). Do not attempt
to shim them onto the current storage layout — the layout changes.

## The one sentence that matters

The M2 suite proved **conservation** (funds always balance) and never proved
**finalizability** (the settling transaction fits in a block for every reachable
state). C-01, H-03, and H-04 are three faces of that single gap. Every new item
below that touches settlement MUST ship with a *reachable-worst-case* gas test,
not a synthetic one.

## Rules

1. One work item per commit, `M2.5-<ID>: <summary>`, in the order below.
2. `forge test` green at every commit. A red suite blocks the next item.
3. Each code item ships with the regression test(s) named in it. The test must
   fail on the pre-fix code and pass after — verify that ordering explicitly.
4. Findings that overturn a prior deviation: update `DEVIATIONS.md` in the same
   commit (strike the old entry, cite the finding).
5. This order folds in the **storage/logic-registry split** (reviewer request)
   at P0-b, because it shares storage with the duty-pool and ruleset changes.
   Do the registry split BEFORE the fixes that rewrite that storage, so those
   fixes land once.
6. Do not present a fix as done until its reachable-worst-case test exists and
   passes. "Conservation still holds" is necessary, not sufficient.

---

## P0 — Deployment blockers. All required before any public-value deployment.

### P0-a. C-01 — Settlement must be O(1) in appeal contributors

**Confirmed:** `Moderation.sol:646` pushes every first-time contributor to
`bondContributors`; `:827-835` iterates the whole array inside `claim()`. Dust
contributions from N addresses make `claim()` exceed the block limit → pot and all
committed stake permanently stranded.

**Fix.** Remove all contributor enumeration from terminal settlement. Keep only
`mapping(address => uint256) bondContribs`. At settlement store aggregates on the
round/case: `winningContribTotal`, `bonusPool`, and a `settled` flag. Each
contributor withdraws via a new `claimAppealPayout(caseId, depth)` that computes
`contribution + bonusPool * contribution / winningContribTotal`, zeroes the
contribution before crediting, and is pure pull. Settlement gas must not depend on
contributor count.

**Test.** A winning appeal with 500+ unique contributors settles in one `claim()`
under the block ceiling; each contributor pulls the correct refund+bonus;
double-pull reverts. This test must OOM/revert on the current code.

### P0-b. Storage/logic/index registry split (reviewer request; do before P0-e/f/h)

Split the monolith into three deployables:
- **StakeRegistry** — token custody + free/pending/committed/frozen/exit
  partitions + the sortition/duty structure. Exposes a narrow privileged API
  (lock, freeze, credit, release) callable only by the current logic contract.
- **Logic** — submissions, draws, commit-reveal, appeals, settlement. Replaceable.
- **IndexRegistry** — the topic→entries structure (survives a logic swap).

**Guardrails (non-negotiable, preserve invariant §9.5).** The repoint switch is
the new trust root: it sits behind the existing timelock; `withdraw()` on
StakeRegistry never depends on the logic contract, so a moderator can always exit
during the timelock if they reject a migration; open cases keep the outgoing
logic authorized until they settle (handover window). Document the trust model.

**Test.** Repoint behind timelock; a moderator exits mid-migration without logic
cooperation; an in-flight case settles under the old logic after a new logic is
installed.

### P0-c. H-01 — Removals bound to a real, indexed target at submit

**Confirmed:** `_removeTarget` resolves `cases[c.targetCaseId]` at claim time
(`:918-925`); IDs are sequential (`:467`), so a removal can name a future ID.
**Overturns L-2.**

**Fix.** Dedicated `submitRemoval(uint256 targetCaseId, uint256 fee)`: require the
target is a settled, approved SUBMISSION with ≥1 live indexed position; derive
content/meta/topics from the target; charge fee on the target's real topic count;
snapshot an entry-generation nonce; emit target + hashes + topic count. Settlement
acts only if the snapshotted generation is still current.

**Test.** Future-ID target reverts at submit; stale-generation removal no-ops
cleanly; fee reflects target topic count. Strike L-2 in DEVIATIONS.

### P0-d. H-02 — Ownership-keyed dedup

**Confirmed:** `submissionExists` is bool (`:373`); `_clearDedup` unconditional
(`:1094-1100`). A stale removal wipes a newer resubmission's reservation.

**Fix.** `mapping(bytes32 => uint256) dedupOwnerPlusOne`. Set to `caseId+1` on
submit (require 0). Clear only when `dedupOwnerPlusOne[key] == thisCaseId+1`. No
obsolete case may clear a newer case's reservation.

**Test.** T indexed → R1,R2 both target T → R1 settles → identical N resubmitted →
R2 settles → N's reservation intact, no duplicate D admissible.

### P0-e. H-03 — O(1) index deletion

**Confirmed:** `_deleteEntry` linear-scans an unbounded array (`:929-938`) inside
atomic settlement.

**Fix.** `mapping(bytes32 => mapping(uint256 => uint256)) entryPositionPlusOne`;
write records position; delete does O(1) swap-pop and fixes the moved entry's
position. Removal becomes O(target topic count).

**Test.** Remove an entry at the end of a very large topic array in bounded gas.

### P0-f. H-04 + settlement batching — finalizability under the reachable worst case

**Confirmed:** reachable draws are 4×(5+11+23+47)=344, not 86; `_updateTracks` is
O(P²) (`:856-861`).

**Fix.** Split settlement into cursored phases
(`AGGREGATE → PARTICIPANTS → INDEX → SETTLED`), each processing a bounded batch
with a keeper bounty; record progress with cursors. Make aggregates O(rounds) by
accumulating side sums (seats, track-weighted sums, winning-contrib totals) at
reveal/close time instead of rescanning at claim. Remove the O(P²) participant
dedup (track membership incrementally).

**Test.** The genuine worst case: 4 depths × 3 widens each × mostly-failed reveals
× max topics × max contributors, settled to completion across batches, each batch
under the ceiling. THIS is the test M2 was missing.

### P0-g. H-05/H-06 — Eligibility epochs + domain-separated randomness

**Confirmed:** raw `blockhash` seed over the live tree (`:499-508`); widen seed
adds no entropy (`:999`); per-seat hash is only `(seed, offset+i)` (`:1075`).
**Sharpens D-8.**

**Fix.** Eligibility epochs: activations/exits apply to a *future* epoch; each case
pins an epoch whose membership+weight are frozen before its entropy exists; initial
and widen draws use that frozen state. Domain-separate every seed with
`(chainid, address(this), caseId, depth, purposeTag, epochId, entropy)`; widen and
outcome seeds get distinct purpose tags and fresh entropy.

**Test.** Two cases in one block draw different panels; a mature-but-unactivated
stake set cannot be activated into a case whose seed is already known. Rewrite D-8.

### P0-h. H-07/H-08 — Collateralized duty pool; widen never exceeds collateral

**Confirmed:** tree weight is full eligible free stake (`:1326-1331`) but commit
needs `riskPerSeat × seats` (`:526`); full-exit/min-stake bypass real
(`:190-193`, `exists` never reset). H-08 overturns the F2 "benign" residual:
`revealVote` tallies live `r.seats` (`:558`) against commit-time collateral.

**Fix.** Opt-in `dutyUnits`: a moderator commits N collateralized units; only units
are drawable; selection reserves a unit immediately; one unit = one seat's
collateral. Snapshot `committedSeats` at commit; widen-added seats on an already
committed address are inert unless topped up. Opted-in no-show → bounded penalty;
passive stake can't be drafted by submission spam. Fix the min-stake floor to test
current total, not `!exists`.

**Test.** Min-stake moderator drawn twice can collateralize its unit(s) or isn't
over-drawn; withhold→widen→reveal grants no uncollateralized weight; opted-in
no-show is penalized; full-exit→restake-below-min is rejected. Strike F2's residual.

### P0-i. H-09 — Under-quorum decisions never become supersafe

**Confirmed:** `if (reveals != 0)` arms on one seat (`:1011`); that entry is
`uncontested` → supersafe at 96h.

**Fix.** Track adjudication confidence (`FullQuorum | Degraded | Failed`) requiring
a minimum count of *independent* revealers (not seats). Only FullQuorum +
no-reject + uncontested + aged qualifies for the supersafe view; degraded
decisions may stay in the broader index. Consider voiding depth-0 rounds that never
reach quorum.

**Test.** A one-seat post-widen approval never enters supersafe; a 3-independent
clean case does.

### P0-j. H-10 — Refund appeals when the protocol fails to supply a quorum

**Confirmed:** zero-quorum appeal restores prior outcome (`:1022-1028`) and the
bond is distributed as "losing" to prior winners; no-shows skipped (`:802`,`:854`).

**Fix.** Distinguish "appeal lost on the merits" from "protocol failed to
adjudicate." On a zero-/under-quorum appeal round: preserve the prior outcome for
liveness, refund the bond **without** bonus, do not classify it as substantively
losing, and penalize the opted-in duty units that failed (needs P0-h).

**Test.** Attacker refuses to commit on an appeal panel → honest challenger's bond
is refunded, not confiscated; the no-show duty units are penalized.

### P0-k. H-11 — Versioned rulesets + snapshotted exits + parameter caps

**Confirmed:** only `guidelinesVersion` pinned (`:357`); exit terms recomputed live
(`:249-254`); `_validateParams` checks almost nothing (`:1300-1314`).

**Fix.** `mapping(uint256 => Ruleset)` + `currentRulesVersion`; each case pins
`rulesVersion` and all transitions read it. Snapshot `exitClaimableAt` and the
min-stake condition at `requestExit`. Add immutable protocol caps (MAX_DEPTH,
MAX_WIDEN, MAX_TOTAL_SEAT_DRAWS, MAX_TOPIC_COUNT, MAX_WINDOW, MAX_FREEZE,
MAX_BOND_MULTIPLIER, array-length caps) and cross-field checks
(minStake ≥ duty-unit collateral, minReveals ≤ smallest panel, max participants ≤
tested settlement bound). Validate proposals against them.

**Test.** A parameter change mid-case does not alter that case; a queued exit keeps
its original terms; out-of-cap proposals revert.

---

## P1 — Correctness and operational quality

### P1-a. M-01 — Bind commitments
`keccak256(abi.encode(chainid, address(this), caseId, depth, msg.sender, vote,
salt))`. Test: a copied commitment from another address/case fails to reveal.

### P1-b. M-02 — Hard commit/reveal deadlines
Entry functions require `block.timestamp < phaseDeadline`; close functions require
`>= phaseDeadline`. Test: a reveal after the deadline reverts; can't front-run the
close.

### P1-c. M-03 — Snapshot track; remove claim-order dependence
Snapshot each voter's track at reveal/close; accumulate side-specific
numerators/denominators then. `claim()` reads no mutable live track. Reconcile the
"time-decayed" doc claim with the code (decay-on-idle or fix the doc). Test: two
claim orders yield identical freeze durations.

### P1-d. M-04 — Reject duplicate topic keys; fee/emit hygiene
Require topic keys unique (sorted strictly increasing). Removal fee/topic count
derive from target (P0-c). Paginate `supersafeEntries(topic, cursor, limit)`. Emit
full immutable case identifiers (content/meta/target/topics/rulesVersion) and add
payload getters to `caseInfo`. Tests per item.

---

## P2 — Economic + deployment validation (no single "done" commit; a checklist)

- Two-step `proposeGovernance`/`acceptGovernance`, reject zero address.
- Non-zero initial guidelines in constructor (or submissions disabled until v1).
- Emit proposed ruleset hash; expose full pending ruleset.
- Document the canonical-xBZZ-only assumption; reject zero token; or measure
  balance deltas.
- `forge build --sizes` as a release gate against the exact deploy profile.
- Re-run the M1 simulation with **real** no-show/capacity/widen semantics and
  **repeated-submission** attack modelling (1-(1-p)^N), correlated-AI moderators.
- Stateful fuzzing over concurrent cases/removals/appeals/governance — with
  **finalizability** assertions, not only conservation.
- Independent re-audit AFTER the architecture changes (storage/state transitions
  moved substantially).

---

## Sequencing note

P0-a (C-01) first — it's the pure-liveness bleeder and is self-contained. Then
P0-b (registry split) before P0-e/f/h/k, which rewrite the storage the split
reorganizes. P0-g (epochs) and P0-h (duty pool) are the deepest changes and share
the sortition structure — do them adjacently. P1 and P2 follow. Nothing here is a
parameter tweak; treat the whole of P0 as a precondition for re-audit.
