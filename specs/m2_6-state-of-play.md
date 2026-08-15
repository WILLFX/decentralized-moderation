# M2.6 — state of play (milestone closed, plus a post-close regression pass)

**All P0 items are closed.** The re-audit should target the **`m2.6-close` tag**.
The last code change *before that tag* is `51af155`; everything between it and the
tag is documentation. Code has landed since — the post-close regression pass and
post-close items 2b, 4, 5, 8, 9, 10, 11, P1-3's residual, K-5 and the external-audit
findings — and the tag is
deliberately not moved to cover it; see the note below.

> **Post-close, read this first.** `m2.6-close` was independently verified, and
> that pass found **eight blocking regressions in items marked closed** plus three
> fixes that no test discriminated. One of them (H-03A) was a claim as much as a
> bug: P0-3's "eligibility is constant by construction, so there is nothing to
> grind" was overstated, and the overstatement is what kept the hole invisible.
> Its first fix then closed two levers rather than the property, and had to be
> reopened (H-03B) and replaced with a single invariant — see P0-3d below.
>
> All are fixed on top of the tag; see the "Regressions found after the close"
> table in `specs/m2_6-work-order.md`. The tag is deliberately **not moved** — it is the
> commit the audit ran against, and moving it would invalidate that verification.
> The pointers in this file still name it for that reason; a new tag is cut for the
> fixed state. Everything from here down describes the state **at the tag** unless
> it says otherwise.
>
> **The size position is resolved.** `Moderation` is at **20,012 bytes, 4,564
> free**, after the second structural split moved settlement into a delegatecalled
> library (`src/lib/Settlement.sol`) and its follow-up moved VOID disposal after
> it. K-1, K-3 and K-5 now fit — and K-3 no longer costs `Moderation` anything at
> all, since every site it touches is now in `Settlement`. What follows was written
> before that and is kept because the reasoning still stands:
>
> `Moderation` was at 24,137 bytes, 439 free, up 841 across the regression batch —
> and that margin was a consequence of those fixes, not an independent constraint.
> It was cited as the reason K-1, K-3 and K-5 were deferred, which made the
> reasoning circular unless said out loud. Saying it out loud is what made the split
> the next item rather than a permanent excuse.
>
> **K-5 was the last High and it is now BUILT.** It held that position when this was
> written, lost it to item 10, took it back when item 10 landed, and is closed.
> `StakeRegistry.setTrack` took no `caseRef` and wrote absolutely, so during a
> handover — when both logics are authorized by design — either could overwrite any
> moderator's track. `recordParticipation` replaces it, scoped to an obligation the
> caller drew. **Nothing at severity High is open.** What carries forward is not an
> item but an ACCEPTED SURFACE: three writes the registry permits and the honest
> logic never makes, all three because tightening them needs game state the registry
> deliberately does not hold. See the work order's "K-5" section.

Two notes on that pointer. First, why not the last code commit: the deployed
bytecode is byte-identical between `51af155` and the close, which touches only
comments, docs and deleted test harnesses — all four contract sizes match. But an
auditor reads more than bytecode, and at `51af155` the repository actively misleads.
The resolution record below does not exist, so the deviations from the work order's
prescription look like misses. This file still describes the mid-milestone system,
including a three-contract architecture that is now four. `test/spike/` is still
present and reads as product tests. And `StakeRegistry`'s header still asserts that
obligations are unscoped aggregates and that solvency holds "only if every
authorized logic is correct" — the exact claim P0-5 falsified. Pointing a
re-auditor at a header that contradicts the fix is how a false finding gets
manufactured.

Second, why a tag rather than a hash: a commit cannot contain its own hash, so a
pointer written inside the history can never name the commit it lives in. A tag
lives outside the commit graph and has no such fixed point — and it is the
conventional handle to hand an auditor anyway.

Read `specs/m2_6-work-order.md` for the item-by-item spec; its **Resolution record**
section at the end is the authoritative account of what landed, the four places the
implementation deviates from the prescription and why, and the residuals left open
deliberately.

## Where things stand

**Branch:** `claude/determined-curie-nkf71s`, based on `main` @ `b09ce31`; open as PR #7.
**Suite at the `m2.6-close` tag:** `forge test` = **188 passing, 16 suites**, default
profile (`via_ir = true`), green at every commit. Baseline was 143 / 16.
**Suite now** (tag + the post-close regression pass + the post-close items): **272
passing, 21 suites**.
The seventeenth is `StalledDraw.t.sol` — the P0-6 family, moved out of
`CaseLifecycle.t.sol` when that contract outgrew the `via_ir` pipeline (a file
move, not new coverage). The eighteenth is `SeatDraw.t.sol`, the cross-batch
seat-draw family, which no registry-level fixture can reach. The last three are
`StallRound.t.sol` (item 2b's next-depth stall round), `Deploy.t.sol` (item 9's
post-deploy assertions) and `RewardScoping.t.sol` (item 10's per-depth reward
allocation).

(The peak during the milestone was 199 / 19. The difference is `test/spike/`, three
throwaway suites that existed only to produce the gas numbers behind the
checkpointed-tree rejection, the MAX_PANEL curve and the VOID curve. Those numbers
are recorded in `contracts/GAS_BUDGETS.md` and `ProtocolLimits`; the code that
produced them is deleted, because a measurement harness that outlives its decision
becomes something a reader mistakes for a test of the product.)

**Sizes at the tag** (EIP-170 limit 24,576; for current sizes see the end of this
section):

| contract | bytes | margin |
|---|---|---|
| Moderation | 23,296 | 1,280 |
| StakeRegistry | 12,876 | 11,700 |
| IndexRegistry | 5,511 | 19,065 |
| RulesetGovernor | 4,210 | 20,366 |

`Moderation` ends the milestone **smaller than it started** (23,795 -> 23,296)
despite eleven items landing in it, because the structural split gave back more
than they cost.

**Item 10 has landed** (`e072945`). It was the highest-severity open finding: the
reward denominator (`_settleInit`, every round) read a different seat set than the
outcome draw (`realizeOutcome`, `_cur(c)`), which made expected reward depend on how
you vote — where the deciding round splits evenly, which is where a single vote moves
the outcome most, appeal panels earned ~83% more for overturning than upholding at
identical freeze risk, on every appealed case with no attacker. The fix allocates the
distributable per adjudicating round in proportion to seats revealed over seats
sought, and divides each round's pool by the winning side at the deciding depth and by
all revealers at earlier depths. The work order's "Item 10" section carries the
derivation, the counterexample that bounds the claim, and what the build found that
the design did not.

**Nothing at severity High is open.** K-5 was the last one: `setTrack` is deleted and
`recordParticipation(moderator, caseRef, coherentUnits, decayFactor)` replaces it,
scoped to an obligation the caller drew, with the decay factor bound per case-round so
it cannot be varied between moderators once the outcome is known. The value stays
global — `m.track` is untouched, so standing still accumulates across logic versions,
which is the constraint that ruled out the obvious per-case-handle shape. The
`trackDecay < WAD` clause closed earlier with P1-3. K-1/K-2/K-3 and the P1/P2 list
remain, none of them a live defect.

Two things a re-auditor should carry from K-5 rather than treat as closed. The
**accepted surface**: the registry permits a track write for a drawn-but-uncommitted
holder, on a VOIDed case, and at any lifecycle point — all three because tightening
them needs game state the registry deliberately does not hold, which is the same fact
that rejected moving the update rule wholesale into the registry. And the
**compounding residual**: decay is multiplicative and obligations are per round, so a
logic can apply it up to N times per case — N is 16 at the shipped ruleset and 81 at
governance caps — and no floor that admits the shipped 0.95 bounds `0.95^81`. The
floor bounds the step; only the logic's own once-per-case rule bounds the count.

**Do not read the differential campaign as an oracle** (item 11, partly built).
`simulation/vectors/reference_int.py` is a **port** of the Solidity, not an
independent derivation, so 52 vectors agreeing at wei resolution proves the two have
not drifted apart — not that the arithmetic is right; a wrong formula would be wrong
in both. Two of the reference's assumptions are false in the contract and mirrored by
the injector, so no vector can express the difference: the last round pushed is
assumed to adjudicate (2b banks rounds, and `__injectRound` stamps `adjudicated` on
every one), and capacity sought is assumed to equal seats seated (`r.target` is
sought; `__injectSeat` does `r.target += seats`). Those are item 10's two degrees of
freedom exactly. Both shapes are covered by unit fixtures, so it is a coverage-shape
gap rather than an unchecked property — but the campaign is a regression net, and the
record previously described it in terms that invited an auditor to price it higher.

There were **two** holes here and only one is closed. The driven one was:
`test_panel_short_of_target_when_capacity_is_scarce` produced a short panel and
stopped at COMMIT, so item 10's allocation was never exercised end-to-end on the shape
where its normalizer and divisor diverge. It now runs to settlement — 2 seats against
a target of 20, a divisor of 1 against 2 revealed, nine tenths of the pot back to the
fee payer — with both terms mutated to confirm it discriminates. **The corpus hole is
untouched by that**, and closing one should not be read as closing both: the vectors
still cannot express a banked round or `target > seats seated`.

After the post-close regression pass, the second structural split, the split's
follow-up, and every post-close item through the external-audit findings (src-only
build — see the pattern list on why that qualifier matters): `Moderation` **20,012 (4,564
free)**, `Settlement` 6,674, `StakeRegistry` 12,933, `IndexRegistry` 6,277,
`RulesetGovernor` 4,565.

`Moderation` rose 841 bytes across the regression batch, fell 4,173 in the split
and a further 761 when VOID disposal followed settlement across the seam, so it
ends well below where the milestone started. The margin is no longer
the binding constraint on work in the game contract; the seam analysis is in the
work order's "Size position" section.

## The architecture is four contracts and two linked libraries

`Settlement` (M2.6) is a DELEGATECALLed library, not a fifth contract: it runs
against `Moderation`'s own storage, so the bytes are outside the EIP-170 budget
while every `Case`/`Round` field it touches stays exactly where it was. A
re-auditor should read it as part of `Moderation`'s behaviour and as a separate
deployment artifact.

## The four contracts

`RulesetGovernor` was split out of `Moderation` when it hit EIP-170 mid-milestone.
The seam is **authoring vs enforcement**: proposing/validating/timelocking a ruleset
is cold and validation-heavy, enforcing one is on every hot path. Ruleset *storage*
deliberately stayed in `Moderation` — `_cp()` reads it per phase transition.

A re-audit scoped to "the three-contract architecture" is scoped wrong; it is four
contracts plus `Settlement` and the pure helper libraries.

## What changed, in one line each

- **Identity** is minted by the permanent registry, not by replaceable logic.
- **Dedup** lives in the registry too, so it survives a migration.
- **Legacy entries** are adjudicable through a replacement logic.
- **Duty reservations escrow real collateral**; all four bypasses are closed.
- **Eligibility changes only at fixed epoch boundaries**, so the sampling TREE is
  constant across any draw window and there is nothing to re-arm on. *(This bullet
  used to end "constant by construction, so there is nothing to grind". That was
  the one overstated claim in this document, and it was wrong — see M2.6-P0-3d
  below. The tree being constant BETWEEN epochs is not the seatable set being
  constant WITHIN one; the draw writing the tree is what turned that gap into a
  grind, and it no longer does.)*
- **Obligations are keyed** `(authEpoch, logic, moderator, caseRef)`, closing both
  cross-logic and cross-case discharge — for `lock`, `release`, `freeze` and
  `settleDuty`. **`setTrack` is the exception and is still unscoped** (K-5); the
  work order's P0-5 "Tests" line used to imply otherwise and is corrected.
- **Logic contracts retire** through `SETTLE_ONLY` before revocation, and revocation
  is gated on an on-chain drain signal.
- **Every panel-scaled loop is batched**: seat draw, settlement, VOID disposal.
- **A draw that cannot complete now ends**, permissionlessly.
- **The freeze arithmetic is bounded at both ends**, including the composite product
  the old validator could not see.

Added by the post-close pass:

- **Both registries gate revocation**, not just the stake side — a case's final step
  writes to both, so one gate was no gate.
- **The epoch drain commits.** `drawPanel` treats a settled epoch as a
  precondition; `realizeSeats` drains and returns, so draws recover with no keeper.
- **An abandoned draw releases without penalty on BOTH paths** out of
  `resolveStalledDraw`, not only the depth-0 VOID — and only when the round never
  widened, because a widen proves a commit window opened and closed. The blanket
  version was H-10 evasion.
- **Governance cannot orphan live obligation handles.** `executeLogic` refuses to
  re-authorize a logic that is already authorized and not drained.
- **The sortition tree is immutable for a whole epoch** (H-03A + H-03B).
  `drawPanel` reads it and never writes it; the only writers are `initialize` and
  `_drainEpochs` at a boundary. So the draw's address mapping is fixed before the
  seed is public, and live seatability inputs — which P0-2 requires — feed only
  accept/deny, changing how far the walk runs and never what the walk is. The
  attempt budget rose from 2 to 6 per seat to pay for not removing anyone, sized
  by measurement and free in every dense case.
- **The privileged registry surface is now exactly**
  `lock / release / freeze / reward / setTrack / drawPanel / settleDuty /
  advanceEpoch`, plus the index registry's `openCase / closeCase / writeEntry /
  deleteEntry / tryReserveContent / releaseContent`. `releaseDuty` and
  `penalizeNoShow` are gone; every write to duty escrow now names its case. That
  claim is about ESCROW — `setTrack` is on the list and is still unscoped (K-5).

Added by the post-close items, each with its own section in the work order:

- **A widen happens at commit close, not at reveal close** (item 2b), and a depth
  that cannot reach `minReveals` opens a **stall round** rather than deciding under
  quorum. Reward scoping follows: only the round that adjudicated at a depth counts.
- **A foreign token is unrepresentable** (item 4): `token == stakeReg.token()` is a
  constructor check over two immutables, not an activation gate, so the bad
  deployment cannot be constructed rather than being caught after the fact.
- **Five fixtures that could not discriminate were replaced** (item 5), and the
  standing conclusion from it is *mutate every repair* — a fix is a hypothesis about
  why a test was blind, and an unmutated repair never tests that hypothesis.
- **Non-participation is priced** (item 8): a withheld reveal now carries
  `s.freezeDur` rather than `failedRevealFreeze`, at all three sites.
- **There is a deploy script, and a test that drives it** (item 9), including the
  assertion that `verify` REJECTS each broken stack.
- **Reward is allocated per adjudicating round with a depth-dependent divisor**
  (item 10), so no depth's per-seat payout is a function of another depth's vote.
- **A short panel is driven through settlement** (item 11's driven half), so item
  10's normalizer and divisor are exercised on the one shape where they diverge.
- **Track decay must be STRICTLY below parity** (P1-3's residual): the validator
  accepted `trackDecay == WAD`, which is no decay at all — track then grew without
  bound on repeated coherent participation, and it feeds the §6.4 freeze curve.
- **Track writes are obligation-scoped** (K-5): `setTrack` is deleted, the registry
  computes the transition instead of accepting a value, and the decay factor is bound
  per case-round so it cannot be varied between moderators after the outcome is
  known.

## Judgment calls — don't silently reverse them

Beyond the four deviations recorded in the work order:

- **`globalId` starts at 1**, so `0` is a safe "absent" sentinel everywhere.
- **Any authorized logic may delete any entry by global id.** Deliberate: it is the
  registry-side prerequisite for cross-version removal. The *authorization* to
  remove is enforced by the game (an adjudicated removal case), not the registry.
- **`StakeRegistry.riskPerSeat` is immutable** and a ruleset may not exceed it. The
  two `riskPerSeat` values are different roles and must not be collapsed.
- **The moderator struct is the authority for what may be seated; the sortition tree
  is only the sampling distribution.** This is what makes P0-3's deferred tree
  updates safe alongside P0-2's escrow, and it is load-bearing in `drawPanel`.
- **`ProtocolLimits.MAX_PANEL` leads with which loop currently sets the bound.** It
  has moved twice; the number alone is not the useful fact.

## Traps that have already cost time

1. **`vm.prank` is consumed by an external call in the argument list.** Compute
   `mod.computeCommit(...)`, `getParams()`, `minFee()` into a local BEFORE pranking.
2. **`vm.warp`/`vm.roll` are invisible to hoisted `block.timestamp`/`block.number`
   under `via_ir`.** Always use `vm.getBlockTimestamp()` / `vm.getBlockNumber()`.
   The failure is silent.
3. **Stack-too-deep** in the settle loop. It is at the IR limit — this is why P0-5's
   `caseRef` is stamped on the Round rather than threaded through the helpers.
4. **`indexed` is a reserved word**; the case flag is `isIndexed`.
5. **A widen returns the round to `DRAW`** (fresh entropy). Drive loops must handle
   `DRAW` mid-round.
6. **Fixtures can go quiet.** The invariant campaign once silently stopped
   adjudicating cases while reporting zero reverts. There is an anti-vacuity test.
7. **New in M2.6:** weight staged in an epoch is not drawable until the next
   boundary, so any fixture that stakes and then expects a draw must call
   `_settleEpoch`. And a seed whose window would straddle a boundary is DEFERRED,
   so rolling a fixed `SEED_LAG + 1` is no longer enough — use `_rollToSeed`.

## The standing lesson, updated

Two milestones running, the lesson was *a safety property written in a comment
instead of enforced in code*. M2.6 adds a second one: **an aggregate is not an
identity.** Every P0 here reduces to the same shape — a caseId that was local where
it had to be global, a dedup map that died with its contract, a collateral pool that
could not say which case it backed, a version counter standing in for an epoch.
Conservation held throughout all of them, which is exactly why they were invisible.
Conservation is necessary and never sufficient.

M2.6-P0-3d adds the sharpest instance of all, and it is a lesson about scope:
**closing every lever you can name is not closing the property.** P0-3c enumerated
the two self-directed levers and suppressed them, which was correct about both and
wrong about the whole — the exhaustion asymmetry and the entire upward family
across batches were still open, and the second only exists because seat drawing is
batched, which is machinery introduced in the same milestone. Fix the mechanism
that makes levers possible, not the levers.

M2.6-P0-3c is a lesson about prose:
**a true statement one level away from the property you need is not a proof of it.**
"The sortition tree cannot move within an epoch" was true, verified, and tested. The
property actually required is "the draw cannot be reshaped after its seed is public",
and the gap between them — a live seatability read whose rejections remap the tree —
was where H-03A lived. The design comment at that check described the architecture
correctly; the summary sentence drew a stronger conclusion than the architecture
supports, and that sentence was then copied into two documents and treated as
settled. Prefer stating the mechanism over stating the conclusion.

The post-close pass added two more, both of the same family:

- **A gate on one of two registries is not a gate.** `StakeRegistry.canRevoke` was
  correct and useless on its own: a case's final step touches both registries, so
  revoking the ungated one stranded the case *and* pinned the gated one shut
  forever. Check the whole boundary, not the half you built first.
- **Bounded work followed by a revert is no work.** The epoch drain did 64 items
  and then reverted if that was not enough, discarding them. It looked like
  progress-plus-backpressure and was actually a permanent stall. If a function may
  revert, it must not be the one making the progress.

And one about tests rather than code: **three fixes could be reverted with the
suite green.** A fixture that cannot distinguish the old behaviour from the new is
not coverage, however green it is — the H-09 fixture used one address holding one
seat, which satisfies "count revealers" and "count seats" identically.

And a fourth in that family, which is NOT the same lesson: **a mutation's failure
count is not a coverage measure.** The first three instances were all "a fixture
asserts nothing". This one is subtler and was nearly missed. Mutating K-5's ordering
fix — pointing its checks at the field `settleDuty` consumes — failed twelve-plus
tests, which reads as heavily covered. All but one failed for the INJECTOR's reason
rather than the property's: `__injectObligation` leaves `dutyUnits == 0`, so every
injected fixture reverts the instant a check reads that field, regardless of whether
the ordering is right. Exactly one driven test actually pins the property, and it now
says so in its own body.

The standing rule: **an injector mirrors the production writer field-for-field, or
documents each omission at the injector.** Not topped up when a new check starts
reading a new field — that is how a partial mirror accumulates, and a partial mirror
turns a mutation run into a confidence signal pointing the wrong way. Where a
divergence is deliberate (the committed-side-only obligation, kept because full
fidelity forces a corpus regeneration), it is written at the injector as a scope
limit, with what it costs: no injected fixture exercises duty disposal.

And one about scope, from F2's second door: **a bound is a property of the FIELD,
not of the function you happened to be looking at.** The first F2 fix clamped
`freeze` — the writer the relay named — and left `settleDuty` writing the same
`m.frozenUntil` unbounded, which is the punish path and therefore the likelier of
the two to carry a hostile term. The suite went green and the docblock's confidence
went up while the property stayed open on one of two writers.

The rule: **before clamping a field, enumerate every writer of it reachable from the
trust boundary you are defending, and say in the commit which ones you clamped and
why the others need none.** `grep -n 'fieldName' src/` is the whole job. Where the
field has more than one writer, give it a single write point so a third one inherits
the bound by construction rather than by memory — `_extendFreeze` is that point for
`frozenUntil`.

And one about evidence: **an incremental `via_ir` build is not a source of record.**
One stale artifact set put a wrong size in a commit message, a wrong size in this
file, and three wrong entries in `.gas-snapshot` — all from the same build. Any
figure quoted as evidence (sizes, gas, EIP-170 headroom) comes off a clean build or
it is not quoted.

**And a clean build is not one number: `forge build --sizes` reports the artifact
compiled WITH `test/` and `script/` in the unit, which is not the artifact you
deploy.** Measured across F3 and F4, at one tree (`631ab50`):

| build | StakeRegistry |
|---|---|
| full (`forge build --sizes`) | 12,761 |
| src only (`--skip 'test/**' --skip 'script/**'`) | **12,933** |

At the previous commit both builds gave 12,933, so what moved the full-build number
was **a test fixture entering the compilation unit** — a test file changing a
production contract's compiled size by 172 bytes. `forge` hands the whole project to
one solc invocation and the `via_ir` pipeline makes size-sensitive inlining decisions
across it. The DEPLOYABLE figure never moved.

Two corrections this cost, both recorded because the second is the instructive one.
The F3 commit attributed the shift to a `src/RulesetGovernor.sol` edit; that was
wrong. The isolation run behind it reverted a single test FILE while the rest of
`test/` stayed in the unit, so it never removed the variable it was testing for — an
isolation that changes one file of a group and concludes about the group.

The operational rules: **quote src-only figures for anything deployable and say which
build a number came from.** Measure on a clean build of the commit you are reporting,
never carry a figure forward because a file was untouched, and do not write
"everything else byte-identical" without having just measured everything else. The
EIP-170 headroom the milestone steers by is unaffected — `Moderation` is 20,012 /
4,564 free in BOTH builds, as are `IndexRegistry`, `Settlement` and `RulesetGovernor`;
only `StakeRegistry` differs. That was luck rather than method, which is why the
method is now written down.

And one about triage: **a selector nothing calls is still a selector.**
`penalizeNoShow` was filed P1 because it had no production caller, then deleted as
a P0 — it wrote pooled `dutyBonded` with no `caseRef`, which is the class P0-5a
exists to make unrepresentable, and "no caller" is exactly the reasoning that
failed for `settleDuty`'s double-release. Reachability by any authorized logic is
the property; today's call graph is not.

And one about oracles: **a port is not a second opinion** (item 11). The differential
campaign was described in this record as an independent reference, and by me in
review as two implementations of the same arithmetic agreeing — "the strongest
confirmation available". It is neither. `reference_int.py` was written from the
Solidity, so what 52 wei-exact vectors establish is that a thing and its own port
have not drifted, which is a regression result and not a correctness one. The tell
was available without reading either file: the two assumptions the corpus cannot vary
are the two degrees of freedom the most recent change introduced, and a genuinely
independent derivation has no reason to land on exactly those. When a check and the
thing it checks share an author and a source, say what it catches (drift) rather than
what it feels like (confirmation).

Two bugs in this milestone were found by reading rather than by a failing test — the
cross-case escrow drain (written in P0-2, caught in P0-5) and the commit path
measuring the wrong bucket after the escrow moved. Both were invisible to the suite
because the fixtures were too generous to reach them.

## Standing recommendation

No deployment with material funds, and the index is not presented as reliable
safe-search certification, until an independent re-audit of the **four-contract**
architecture passes against the **`m2.6-close`** tag.

Point the re-auditor at:
1. This file and the work order's Resolution record — the deviations especially.
2. `contracts/GAS_BUDGETS.md` — every bound is measured, and it records which loop
   sets each one.
3. `StakeRegistry`'s header "what this does NOT yet guarantee" section, which was
   written before P0-5 and should be re-read now that obligation scoping has landed.

The open P1/P2 items are listed in the work order. **P1-1 (widen seats bypass
escrow) is the most substantive**: it is the one remaining place a seat can exist
without backing.
