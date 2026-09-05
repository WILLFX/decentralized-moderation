# Moderation Contract v3 — Formal State-Machine Specification

**Milestone:** M3.0
**Status:** Specification, revision **v3.5**. Not implemented.
Revision history is the commit log; the marker exists so a reader can tell which
`design-v3` revision this file was last reconciled against (v3.4).
**Design:** `specs/design-v3.md` — mechanism, arithmetic, and the costs this
document takes as decided. Where the two disagree, the design document is wrong and
should be corrected; this file is normative.
**Supersedes:** `specs/state-machine-v2.md` entirely. That document specifies
challenge eligibility seeds, risk units, `MAX_ROUNDS` 2 and pooled tallies under a
linear lottery, none of which survive. It is kept as the record of the architecture
the external review was run against.
**Scope:** the on-chain moderation contract. All eight existing source files are
classified, because a partial list is how a file ends up unowned:

```
deleted outright     SortitionTree, FreezeMath                       ~210 lines
rewritten            Moderation, Settlement, StakeRegistry,
                     RulesetGovernor                               ~4,070 lines
survives with edits  IndexRegistry, ProtocolLimits                   ~650 lines
```

**Corrected from M2.6's port assessment against this commit's predecessor.** The
earlier grouping put `StakeRegistry` and `RulesetGovernor` under "survives with
edits", which invites editing them in place; measured, 47% of the first is gone and
the second retains its governance *pattern* and almost none of its content. The
port order is `StakeRegistry` first — it is what everything else is written
against, and getting it second means writing `Moderation` twice.

§10 carries the per-file edits. **No Solidity has changed since the pivot** — the
diff against `contracts/` is empty, and this document describes what must replace
it, not what is there.

The **Working value** column in §1 gives simulation inputs, not final values; the
parameters with no defensible working value at all are marked *(open — §10)* and
are listed there with what would decide them.

> **Decisions taken here, not in the design document.** The rules below follow from
> the design but are not stated by it. Each is consequential enough to be visible,
> and each carries its reasoning inline. The list is not numbered in the prose,
> because every revision that added one left a stale count behind.
>
> - §3.5 — **a challenge is a bond, not a vote**, and carries no eligibility
>   test. This removes the forced disclosure v2 §4.7 accepted as unavoidable, and
>   returns the challenge to the round-0 dissenters, who are the population `h`
>   depends on.
> - §3.5b — **round 1 opens on the schedule, not on the challenge.** Filing early
>   does not start the round early, so no seed depends on the challenger's chosen
>   block.
> - §4.5 — **one randomness per claim, realized once, at the last transition
>   before `FINALIZED`.** Not "evaluated against both tallies": an earlier revision
>   drew a provisional verdict at round-0 close and reused `u`, and §4.2 withdrew
>   that draw entirely. The verdict is monotone in the tally, so a challenge that
>   adds no votes changes nothing and there is no second roll to buy.
> - §4.6 / §5.3 — `MIN_CHALLENGE_REVEALS` is removed and `CHALLENGE_BOND` settles
>   on **nothing**: it is debited unconditionally. Every conditional available was
>   one the challenger could evaluate before registering, so the bond bit whoever
>   could least predict it. The extraction channel the old forfeit guarded is
>   closed at its source instead — the challenge reserve activates in proportion
>   to round-1 reveals, so registering a round moves no value.
> - §4.8 — one terminal `UNRESOLVED` with a reason, rather than separate
>   `NO_QUORUM` and `VOID` states. §4.8 later split the reason codes, because
>   they carry different debits and different retry rules.
> - §4.8 / §5.2 — **there is exactly one quorum gate and it is on commits.**
>   `MIN_REVEALS` is removed rather than relocated: it was a terminal-class gate on
>   observable state, and the only thing that ever made withholding attractive.
> - §4.9 — **round 1 has no quorum gate.** §4.5's monotonicity makes an empty
>   challenge round self-healing, and a gate there would let a rejected submitter
>   escape their rejection by challenging and staying quiet.
> - §5.1 — **penalties are balance debits, never time.** No moderator is ever
>   suspended; there is no `SUSPENDED` state anywhere in this document.
> - §5.4 — a debit that would exceed the posted bond is impossible by
>   construction, not clamped after the fact.
> - §2.4 — **liabilities are accrued, not recomputed**, and every case pins the
>   parameters its debits will use. A complete liability function evaluated
>   against a coefficient governance changed mid-flight is just as broken as an
>   incomplete one.
> - §8.2 — the index carries the round-0 **plurality** as a distinct value rather
>   than withholding the entry until final.
> - §4.2 / §4.5 — **the interim result is a plurality, not a draw, and the single
>   draw happens last.** Publishing a drawn provisional published `u`, and the
>   three tickets collapse to one number: it handed every party the exact flip
>   cost twelve hours before the challenge decision.
> - §4.8 / §7.3 — **a terminal settles every obligation whose input it has** (I30).
>   `UNRESOLVED(NO_RANDOMNESS)` holds a full tally and no verdict, so it charges the
>   tally-derived debits and pays nothing. That is what makes poking the draw
>   dominant for the plurality-losing side and closes I24 against *inaction*, which
>   the previous revision left to the size of `DRAW_BOUNTY`.
> - §8.6 — **permanence stays, and the argument it used to rest on is gone.** What
>   it costs is not the false-rejection rate but the part of it §8.5's recourse
>   cannot reach — 22.8% of safe content at `prior = 0.665`, 0.7% at 0.95. The
>   plurality-conditional repair buys an attacker the same margin it saves a
>   publisher, and both vanish as `prior` rises: `prior` decides whether either
>   failure exists, not which one dominates.
> - §8.1 — **the index is written at the transition that establishes a terminal**,
>   and there are four of those (I15). The rule named `FINALIZED` alone, so the
>   three `UNRESOLVED` rows wrote the index during settlement — the coupling §8.1
>   itself calls v2's mistake — and at launch registry sizes those rows are 92% of
>   cases. §5.5 sharpened it: pulled settlement may never complete at all.
> - §8.2 / §8.2b — **an index entry has a content-derived identity, and zero is
>   never a writable value** (I29). A claim key names a *set* of entries and cannot
>   name a member, so deletion had nothing stable to address; and the status enum
>   began at `PLURALITY_APPROVE`, so an unwritten slot read as a live interim
>   status in the section whose whole purpose is that those are distinguishable.
> - §3.1 — **the eligibility predicate is guarded on block height, not on the
>   value `blockhash` returns** (I29, second instance). Unguarded it does not fail
>   when the seed is unreadable: `H(…, 0, m)` is a good hash, so it silently
>   selects a set computable by anyone from the moment the case exists. The seed
>   block does not exist for the first three blocks of **every** commit phase, so
>   this was not a drift edge case.
> - §5.5 — **settlement is pulled per moderator, not swept per case** (I20).
>   The committer count has no ceiling, so a sweep funded by a fixed fraction of a
>   fixed fee is unbounded on one side and a case can become unprofitable to
>   settle — locking every participant's bond through economics rather than
>   through a missing discharge path. A cap would have been worse: entry is
>   passively eligible, so a ceiling is a gas auction the always-on attacker wins,
>   turning a liveness attack into a composition one.
> - §8.5 — **a re-review reopens a claim; it does not create one.** Three rules
>   rested on it and none defined it, and the default an implementer would have
>   reached for — a new `actionType` — has a different `claimKey`, so the permanent
>   reservation would not have bound it and permanence would have been worth one
>   byte. Reopening in place inherits the claim's `u` and its pooled tally, so
>   §4.5's monotonicity applies unchanged: no re-roll, and a failed reopening makes
>   the next one harder.
> - §5.3 / §9 — **every quantity a rule reads is re-derivable at the site that uses
>   it, and no number appears whose source is not named** (I33). `reveals1` was
>   written as a bare name with no field behind it, and its only available binding
>   activated the whole challenge reserve on every *unchallenged* case. It is
>   derived now, and zero on that path by arithmetic rather than by a reset nobody
>   performs.
> - §4.8 — **every obligation names the condition under which it fires** (I30), and
>   there are no groups. Sorting them into *reads nothing / tally / verdict* put the
>   challenge reserve in two places at once — it is sized by the tally and triggered
>   by the verdict — and the two rules paid the same twenty units out twice. A
>   condition is a property of the obligation; a group is a property of the
>   partition, and only one of those a new rule can be mis-filed into.
> - §2.4 — **a claim on a bond is a record, not a subtraction** (I32), and a
>   broken logic is **condemned** rather than force-discharged: once condemned,
>   anyone may release any of its claims, forever. Partial application is not a
>   state, so there is no list to lose and no moderator left worse off than before
>   the recovery ran. Only the case
>   that created it may discharge it, and only the logic that created that case may
>   act on it. I1's "structural" covered the arithmetic and not the authorization:
>   with `liabilities` a bare scalar the release amount had to come from the caller,
>   and any authorized contract could zero any moderator's liabilities. Obligation
>   handles were deleted as panel machinery when their job was custody.
> - §0 / §7.2 — **the schedule is denominated in block heights** (I31). The
>   previous revision compared a wall-clock deadline against a block-indexed
>   `blockhash` horizon via a `blockAt()` the EVM does not have, and the two sides
>   drifted apart at 2.7% of block time — killing every *challenged* case and
>   debiting its plurality-losing revealers for a clock mismatch nobody could have
>   prevented. One conversion survives, at case creation, from a pinned parameter.
> - §4.5 — **the draw is taken against `â = (A+1)/(N+2)`, not `A/N`.** A sample
>   proportion is not a population rate, and `f(1) = 1` let one revealed vote decide
>   a case with certainty. I11 and I12 both read true over that configuration and
>   neither covered it.
> - §8.4 — **`UNRESOLVED(NO_RANDOMNESS)` does not retry**, and holds the claim key
>   on `REJECTED`'s terms by reference. I26 already required it: that terminal is
>   tallied by definition, and a reservation that expires releases the key. Any
>   retry is worth more to the submitter than any draw, on *either* plurality,
>   because every draw has a permanent branch and a retry has none.

---

## 0. Conventions

- **xBZZ** amounts are integers in base units. No floating point anywhere.
- **Schedule is in block heights. Wall-clock time is a record, never a
  comparison.** A deadline is denominated in blocks **iff a block-denominated
  chain constant can expire inside it**. `BLOCKHASH_HORIZON` runs inside every
  case-phase deadline, so those are heights; it runs inside no moderator-lifecycle
  delay, so `MATURATION` and `EXIT_COOLDOWN` stay in seconds. `finalizedAt` is a
  timestamp because nothing is compared to it.
- **There is exactly one conversion between the two units in this specification**,
  and it happens once, at case creation, from a parameter pinned into the case
  (§1 `BLOCK_TIME`, §4.3). After submission no rule reads it. An earlier revision
  put the conversion *inside* the comparison — §7.2 called a `blockAt()` the EVM
  does not have — and §7.2 records what that cost.
- **Randomness** is `blockhash(eligSeedBlock)` per round and
  `blockhash(outcomeSeedBlock)` once per claim, domain-separated per case, round
  and purpose (§7). Never re-armed after expiry (§7.3). There is no
  `snapshotBlock`; that name is from v2, where one seed served both jobs.
- `H(...)` is `keccak256(abi.encode(...))` unless stated otherwise.
- **Rounds** are numbered from 0. Round 0 is the initial vote; round 1 is the
  single challenge round. There is no round 2.
- **Plurality** means: which side leads the pooled tally — a *fact about the
  votes*, carrying no randomness, published at `TALLY` and binding on nothing
  (§4.2). **There is no "provisional verdict" in this document.** An earlier
  revision drew one at round-0 close; publishing it published `u`, and with it the
  exact number of votes needed to flip the case, twelve hours before anyone had to
  decide whether to challenge.

---

## 1. Parameters

| Name | Working value | Meaning |
|---|---|---|
| `MIN_STAKE` | 10 xBZZ | Floor to hold an identity. Flat; more buys no voting power. |
| `BOND_MIN` | *(open — §10)* | Solvency floor. A moderator with less may not commit. |
| `PENALTY_DEBIT` `d` | `1.4 × E[P/N]` | Debited from bond for a vote incoherent with the final verdict (design-v3 §6). |
| `GAS_ALLOWANCE` `G` | *(open — §10)* | Conservative upper bound on the gas cost of one reveal, in xBZZ. Governance-set; enters `REVEAL_BOND` (§5.2). |
| `REVEAL_BOND` | **`= d + G`** | Covered at commit, debited on non-reveal (§5.2). Derived: §5.2's dominance argument floors it at `d + G`, because a reveal costs gas and withholding does not. |
| `LAMBDA` `λ` | **`= d + G`** | Bond required per open vote — `max(d, REVEAL_BOND)` per §2.4, which `REVEAL_BOND` now sets. |
| `CHALLENGE_BOND` | *(open — §10)* | Covered to register a challenge, **debited unconditionally** at settlement to the maintenance reserve (§4.6). A price for summoning a round, not a bet on its result. |
| `MATURATION` | *(open)* | Delay before newly staked value may vote. Set from the attack-preparation horizon, **not** from any penalty term. |
| `EXIT_COOLDOWN` | 7 d | Delay between exit request and withdrawal. **Stays in seconds** — no block-denominated constant expires inside it, so converting it would buy nothing and cost the wall-clock predictability the conversion exists to preserve (§0). Same for `MATURATION` and `RETRY_COOLDOWN`. |
| `TARGET_COHORT` | 40 | Expected eligible moderators per round. |
| `MIN_COMMITS` | 16 | Commits required at commit close, or the case ends `UNRESOLVED(NO_TURNOUT)` (§4.8). **This is the quorum gate** — decided before anyone can see a tally. |
| ~~`MIN_REVEALS`~~ | — | **Removed, §4.8.** It was a terminal-class gate on observable state, and it was the only thing that ever made withholding attractive. The draw needs `N ≥ 1`, which is arithmetic, not policy. |
| ~~`MIN_CHALLENGE_REVEALS`~~ | — | **Removed, §4.6.** §4.5's single-randomness rule makes an unchanged tally yield an identical verdict, so the floor has no job. |
| `SUPER_QUORUM` | *(open)* | Reveals required for the strict assurance class (§8.3). |
| `RETRY_COOLDOWN` | *(open — §10)* | Delay before a claim that ended `UNRESOLVED(NO_REVEALS)` may be resubmitted (§8.4). **`NO_RANDOMNESS` no longer uses it** — that row does not retry at all (I26). |
| `BLOCK_TIME` | 5 s | **The one wall-clock→block conversion in this document.** Governance-set, pinned per case at submission (I27), read exactly once (§4.3) and never again. It is a *scheduling* parameter, not a safety one: wrong by 50% and windows are 50% off in wall-clock terms; nothing terminates that would not have. It does carry one hard bound — see §10. |
| `COMMIT_WINDOW` | 20 min → **`ceil(1200 / BLOCK_TIME)` = 240 blocks** | Per round. The minutes are the human-facing intent; the blocks are what the contract compares. |
| `REVEAL_WINDOW` | 20 min → **240 blocks** | Per round. |
| ~~`FINALIZATION_GRACE`~~ | — | **Removed.** It named a deadline no transition established. The real one is `outcomeSeedBlock + BLOCKHASH_HORIZON` (§4.4), which `BLOCKHASH_HORIZON` already gives. |
| `CHALLENGE_WINDOW` | 12 h → **8,640 blocks** | From publication of the round-0 plurality (`TALLY`). |
| `SEED_LAG` | 2 blocks | Between arming and realizing a seed. |
| `BLOCKHASH_HORIZON` | 256 blocks | How long `blockhash` remains readable. A property of the EVM, not a choice. **Every deadline it can expire inside is denominated in the same unit** (§0), which is what makes §7.3's rarity argument checkable rather than dependent on an assumed block time. |
| `LATE_WIDEN_AT` | minute 12 of commit | Eligibility widening trigger (§3.3). |
| `LATE_WIDEN_FACTOR` | 1.5× | Threshold multiplier at widening. |
| `DRAW_BOUNTY` | 0.5 % of fee | Paid to whoever pokes the draw, or its expiry (§4.3). Separate from `CLAIM_BOUNTY` because the draw, not finalization, is the transition with a hard expiry (§7.3, F16). **It is a convenience, not the reason the poke happens** — §7.3 makes poking dominant for the plurality-losing side at any bounty, including zero. |
| `CLAIM_BOUNTY` | 1 % of fee | Paid to whoever triggers finalization. |
| `MAX_TOPICS` | 5 | Topics per submission. Unused slots in the fixed-width field read 0, which is why `topicKey == 0` is not a legal topic (§8.2b, I29). |
| `FEE_BASE`, `FEE_PER_TOPIC` | *(open — §10)* | Must pay `TARGET_COHORT` voters above gas. |

**The submission payment has four components** (design-v3 §2.1):

```
fee = initialPot + challengeReserve + DRAW_BOUNTY + CLAIM_BOUNTY + maintenance
```

`maintenance` is **nonrecoverable** — it is not refunded on `UNRESOLVED` and is not
recoverable by a successful attacker. It is the component that answers P0-3.

---

## 2. Moderator state

### 2.1 Storage

```
struct Moderator {
    uint128 stake;           // 0 or MIN_STAKE
    uint128 bond;            // posted, at risk, debited by penalties
    uint32  openVoteCount;   // committed votes whose case has not settled
    uint32  openChallenges;  // registered challenges not yet resolved
    uint128 liabilities;     // ACCRUED, not recomputed — §2.4. The SUM of this
                             //   moderator's open claims, and equal to it by
                             //   construction rather than by discipline (I23)
    uint40  maturesAt;
    uint40  exitRequestedAt;
    uint32  trackEpoch;
    uint128 track;           // reputation, WAD-scaled (§6)
}
```

Every claim on a bond is itself a record, because a scalar cannot say who is owed:

```
struct Claim {
    uint96  amount;          // what this claim covers — LAMBDA(c) or
                             //   CHALLENGE_BOND(c), PINNED at creation (I27)
    address logic;           // the contract that created it, and the only one
                             //   that may discharge or draw against it
}

claims :  keccak(moderator, caseId, kind)  ->  Claim      kind ∈ {VOTE, CHALLENGE}
```

The two fields are 96 + 160 bits, so a claim is **one storage slot**, written when
the claim is created and cleared when it is discharged. §2.4 explains why the
record has to exist and what it costs.

**There is no `suspendedUntil`, no `units`, no `unitsReserved`, and no `RiskUnit`.**
Nothing in this specification freezes a moderator for a period of time. §5.1
explains why, and §9 I8 states the property that replaces it.

`stake` and `bond` are distinct. Stake is the identity floor and is never debited.
Bond is the working capital that penalties consume and rewards replenish.

### 2.2 States

| State | Predicate |
|---|---|
| `NONE` | `stake == 0` |
| `PENDING` | `stake > 0 && now < maturesAt` |
| `ACTIVE` | `stake > 0 && now ≥ maturesAt && exitRequestedAt == 0` |
| `EXITING` | `exitRequestedAt != 0` |

Four states, mutually exclusive by construction. **There is no `SUSPENDED`.** What
varies for an `ACTIVE` moderator is whether they are *solvent enough to commit*
(§2.4), which is a predicate over `bond` and `openVoteCount` rather than a state.

`EXITING` moderators may still reveal votes committed while `ACTIVE`, and their
open cases settle normally. Nothing removes past judgment.

### 2.3 Transitions

| From | To | Trigger | Effect |
|---|---|---|---|
| `NONE` | `PENDING` | `stake(MIN_STAKE)` + `postBond(≥ BOND_MIN)` | transfer in; `maturesAt = now + MATURATION` |
| `PENDING` | `ACTIVE` | `now ≥ maturesAt` | none (predicate) |
| `ACTIVE` | `ACTIVE` | `postBond(x)` | `bond += x`. Permitted at any time, including to restore solvency |
| `PENDING` | `EXITING` | `requestExit()` | `exitRequestedAt = now`. **`PENDING` must have an exit path** — without one, stake is locked for `MATURATION` with no way out |
| `ACTIVE` | `EXITING` | `requestExit()` | `exitRequestedAt = now` |
| `EXITING` | `NONE` | `withdraw()` | see below; **clears `exitRequestedAt`** |

```
withdraw allowed iff  now ≥ exitRequestedAt + EXIT_COOLDOWN
                 and  liabilities(m) == 0                   (§2.4)
```

**The liability count is exact where a duration guess is not** (P0-5). A cooldown
alone let a voter commit, request exit, and withdraw before the case that would
debit them ever settled. It is `liabilities(m)`, not `openVoteCount`, because a
registered challenge is a claim on `bond` that no vote counter sees — the same
omission that broke I1 (§2.4).

Withdrawal returns `stake + bond`, less nothing, and **clears `exitRequestedAt`**.
Leaving it set makes `NONE` (`stake == 0`) and `EXITING` (`exitRequestedAt != 0`)
both hold at once, violating I16, and drops a re-staking identity straight back
into `EXITING`. `track` is retained (§6) — that is what makes identity replacement
expensive rather than the stake.

### 2.4 Solvency: one liability function, used in three places

**Decision.** Every claim on `bond` is a term in a single function, and that
function appears in every test that creates or releases a claim.

```
commit    on case c:  claims[m,c,VOTE]      = Claim(LAMBDA(c), msg.sender)
                      m.liabilities += LAMBDA(c)         ; openVoteCount++
challenge on case c:  claims[m,c,CHALLENGE] = Claim(CHALLENGE_BOND(c), msg.sender)
                      m.liabilities += CHALLENGE_BOND(c) ; openChallenges++

debit     on (m,c,k):  require msg.sender == claims[m,c,k].logic
                       require amount     ≤ claims[m,c,k].amount
                       bond -= amount                     -> maintenance (§5.1)
discharge on (m,c,k):  require msg.sender == claims[m,c,k].logic
                       m.liabilities -= claims[m,c,k].amount ; delete the claim

mayCommit(m)     iff  ACTIVE and bond ≥ BOND_MIN + m.liabilities + LAMBDA(c)
mayChallenge(m)  iff  ACTIVE and bond ≥ BOND_MIN + m.liabilities + CHALLENGE_BOND(c)
withdraw(m)      iff  cooldown elapsed and m.liabilities == 0
```

**The amount is looked up, never supplied.** An earlier revision wrote the release
as *"`m.liabilities -= the amount that case added"*, with `liabilities` a bare
scalar and no per-case record anywhere in §2. There is only one way to implement
that: the caller passes the amount, and the registry takes its word. Every
guarantee in this section then holds only of the arithmetic and none of it holds of
the **authorization**.

**Failure, and it does not need a second contract to bite.** Within one logic, a
bug that releases the wrong amount silently corrupts `liabilities` and nothing
catches it, because conservation still balances — which is exactly how v1's P0-2
drained escrow across cases inside a single contract, with a per-moderator pool
where a per-case one was needed. Across two, it is a complete break: governance
authorizes logic B while logic A still has open cases — which any workable
migration must permit, or every in-flight case strands at the cutover — and B calls
`discharge(alice, anyCase)` for `alice.liabilities`. Alice's liabilities reach zero
with three votes open under A, she withdraws stake and bond (I13 false), and A's
settlement then debits a moderator who has left. Or B debits her bond for a case
she never voted in (I1 false).

**I1's word "structural" was doing work it had not earned.** *"Every value the
specification can remove from `bond` is a term in `liabilities()`"* is a statement
about arithmetic. The property custody actually needs is different:

> **Only the case that created a claim may discharge it, and only the logic that
> created that case may act on it.**

That is what an obligation handle *was*. §10 deleted obligation handles as panel
machinery, and the deletion was right about the noun and wrong about the function:
v1's handle was attached to an assigned duty, which v3 does not have, but its job
was custody, which v3 does. **The handle was categorised by what it hung from
rather than by what it did** — the same error that lost `MIN_REVEALS`'s second job
(§4.8) and that I29 and I30 were both written about.

**Three properties fall out, and each replaces an argument with a construction:**

- **The release amount cannot be wrong**, because no caller states it.
- **A foreign logic cannot touch a claim**, so a migration settles A's cases under
  A and B's under B, and a moderator's `liabilities` is the correct sum throughout.
- **A debit cannot exceed what was covered.** §5.4 wants exactly this and currently
  argues it from `liabilities()` being complete. It is now enforced at the call
  site: you may draw against the claim you hold and nothing else.

And **I23 becomes checkable.** *"`m.liabilities` is the single point of truth for
claims on `bond`"* was an accounting convention; `liabilities == Σ claims` is now an
identity a view function can assert.

**What it costs, stated plainly.** One cold storage write per commit and per
challenge, cleared at settlement — roughly 20k gas in, some of it refunded out.
That is the price of custody and there is no cheaper encoding: the registry cannot
recompute `LAMBDA(c)` because it does not hold the case's pinned parameters, and
the whole point is that it must not have to ask. **It tightens §10's settlement-cost
crossover**, which is already the binding economic constraint, and the two rows are
cross-referenced there rather than left to be discovered.

**Discharge capability must outlive creation capability.** A logic barred from
creating new claims must still be able to discharge the ones it holds, or
deauthorizing it strands every moderator who voted under it — I13 and I20 broken by
the act of retiring a contract. So the two are separate capabilities, and
**`MAY_DISCHARGE` cannot be revoked from a logic that holds an open claim.** The
registry knows the count; the rule is a comparison, not a governance discipline.

The residual is a logic that *will not* discharge — a bug, not an attacker. The
recovery is **condemnation**, and it is one sentence:

> **Once a logic is condemned, any of its claims may be discharged by anyone,
> forever.**

Governance sets one timelocked flag. `dischargeCondemned(m, caseId, kind)` is then
permissionless, releases one claim, and is idempotent — no list, no ordering, and
callable by the affected moderator themselves.

**Condemnation adds a discharge path; it does not remove one.** The condemned logic
keeps `MAY_DISCHARGE` and may still settle claims it holds legitimately. So the
rule above — that `MAY_DISCHARGE` is not revocable while a claim is open — is never
excepted, and this section has no caller that breaks its own constraint.

**What this replaces, and why.** An earlier revision specified a *force-discharge*:
a timelocked action that walked a caller-supplied list of the logic's claims,
released them, and set `caps = 0` to bar the logic from debiting. Three things were
wrong with it and only one was the thing this document had worried about:

- **The bar was redundant.** Force-discharge deletes the claim, and §2.4's own
  construction — *you may draw against the claim you hold and nothing else* —
  already makes `debit` revert on a deleted claim. It was a rule stacked on a
  construction that gave the property.
- **The release and the bar had different arities, and the harm was the total
  one.** The registry holds a *count* of a logic's claims, not an enumeration, so
  the release was `O(claims)` from a caller-supplied list while the bar was `O(1)`
  and immediate. On a partial list the harm landed in full on the first
  transaction and the repair only if governance finished the walk. **A moderator
  omitted from the list was strictly worse off than before the hammer fell** —
  liability standing, and the only contract that could discharge it now stripped
  and barred. The hammer stranded the people it existed to un-strand, and a lost
  list stranded them permanently, because the registry can say how many claims
  remain and not which.
- **It set `caps = 0` while `openClaims != 0`**, which is the one case the
  paragraph above forbids. It was the sole caller that broke its own rule.

Condemnation has none of these because **partial application is not a state**.
There is nothing to leave half-done, so there is no list to lose and no ordering to
get wrong. It is also smaller: measured at **7,796 bytes against 8,209** for the
force-discharge in the same probe.

**Condemnation forgives the debits, and that is a decision rather than an
oversight.** Releasing a claim without assessing what it covered pardons the
pending penalty, so every moderator with an open claim under a condemned logic
withdraws clean. The registry cannot do otherwise: a claim record holds `amount`
and `logic` (§2.1) and **not the case's outcome**, which lives in the contract that
is broken. Charging the maximum instead would debit moderators who were about to be
*paid*, for a defect in code they do not control.

The cost is a payoff, and it should be stated rather than discovered: **wedge a
logic, hold losing positions, and governance's only recovery hands your bond back
intact.** It is bounded by the attacker's own liabilities, which are bounded by
their bond, and it requires them to first find a wedge in an audited contract —
that is a bug class, not a strategy. But *"a bug, not an attacker"* is a claim
about the **cause**, and whether it stays true is decided by the recovery's payoff
structure. This one pays. `RulesetGovernor`'s timelock and the visibility of a
condemnation are what stand between that and a routine move.

**`liabilities` is accrued, never recomputed, and the coefficients are the
*case's*.** `LAMBDA(c)` and `CHALLENGE_BOND(c)` are the values pinned into case `c`
at submission (§4.1, I27), not the values in force at settlement.

**Why accrual rather than `λ · openVoteCount`.** The product form is correct only
while `λ` is the same number at commit and at settlement, and no earlier revision
said it was. A moderator covering three votes at `λ = 100` holds `BOND_MIN + 300`;
governance raises `d` to 150; all three settle incoherent and debit 450 against
`BOND_MIN + 300`. Negative whenever `BOND_MIN < 150` — and §5.4 mandates
revert-not-clamp, so that moderator's presence bricks the settlement batch for
everyone else in the case. That is the failure mode `6de7284` fixed, reached
through a parameter change instead of through a missing term.

Storing the amount closes it by construction: **what was added is what is removed,
and no coefficient is read at settlement at all.** Both previous breaks of this
bound were *enumerative* — a missing term. This one was *temporal*, and a complete
function evaluated against a stale coefficient is just as broken as an incomplete
one.

**Nothing is transferred by any of these.** `liabilities()` is a *covered amount*,
not an escrow: no value leaves `bond` at commit or at challenge registration, and a
moderator who posts more bond can do more of both with no ceiling. What the tests
guarantee is that the balance can absorb every outstanding claim at once.

**The single-accumulator form is the point, not the arithmetic.** An earlier revision
wrote the commit test against `openVoteCount` alone, and the withdrawal test
against `openVoteCount == 0` alone. `CHALLENGE_BOND` is not attached to a vote, so
it appeared in neither: a moderator with `bond = BOND_MIN + 3λ` and three open
votes could register a challenge, then lose all three, and land at
`BOND_MIN − CHALLENGE_BOND` — negative whenever `CHALLENGE_BOND > BOND_MIN`. §5.4
mandates a revert rather than a clamp, so **that moderator's presence would brick
the settlement batch for every other voter in the case**, and by §4.8's discharge
path pin their `openVoteCount` too. One moderator, one challenge, one case frozen
for everybody in it.

I1's extension clause had been written as *"any new **per-vote** debit"*, which is
exactly the wording that let a per-moderator debit through. The rule is now: **any
value the specification can remove from `bond` is a term in `liabilities()`**, and
`liabilities()` is used unchanged in all three tests above (I1, I13, I23).

**Why `λ = d + G`.** A single open vote can produce two debits and they are
mutually exclusive — a vote either reveals, risking `d` if incoherent, or fails to
reveal, forfeiting `REVEAL_BOND` and risking no `d`. So its coefficient is the
larger, not the sum:

```
LAMBDA ≥ maxDebitPerOpenVote = max(d, REVEAL_BOND) = REVEAL_BOND = d + G
```

`REVEAL_BOND` is the larger because §5.2 floors it at `d + G` — revealing costs
gas and withholding does not, so a bond of exactly `d` leaves a band of beliefs in
which withholding wins. A smaller `LAMBDA` admits insolvency; a larger one rations
capacity for no safety gain.

**The exclusivity survives §4.8's `NO_RANDOMNESS` debit.** That row charges `d(c)`
to a revealer on the losing side of the plurality — the *revealed* branch of the
same disjunction, at the same coefficient, in a terminal where no verdict was
drawn. It is not a third debit and it does not raise `maxDebitPerOpenVote`, so
`LAMBDA` is unchanged and I1 stays structural rather than needing a new term.

**No value appears twice in this document.** An earlier revision derived
`LAMBDA = d` here, kept that after §1 moved to `d + G`, and instructed the reader
to "re-check whenever either parameter moves" — an instruction that was not
executed when the parameter moved. §1 is the only place a parameter's value is
written; everywhere else refers to it by name (I29).

**This is a price, not a reservation** — the distinction that separates it from the
withdrawn risk units. Risk units rationed a fixed allowance `K` that no amount of
capital could extend, and a *case* consumed one from a moderator. Here nothing is
consumed by a case, only by a moderator's own voluntary act, and the limit moves
with the bond. I2 forbids the protocol reserving from a moderator; it does not
forbid a moderator covering their own commitment.

**`CHALLENGE_BOND` needs no relation to `BOND_MIN`.** Requiring it to be *covered*
at registration is strictly better than constraining its size, because the coverage
test scales with whatever the parameter turns out to be.

---

## 3. Eligibility

### 3.1 The predicate

```
eligible(m, c, r)  iff  eligSeedBlock(c,r) < block.number
                                          ≤ eligSeedBlock(c,r) + BLOCKHASH_HORIZON
                   and  H(ELIGIBILITY_DOMAIN, chainId, contract,
                          caseId, roundSeed(c, r), m) < threshold(c, r)
```

Evaluated **off-chain** by each moderator and verified on-chain only when they
commit. The contract never enumerates the eligible set — see §3.6.

**The first line is the whole of this section's correction, and I29 already
required it.** An earlier revision had the hash and no height guard at all. §7.3
reasons carefully that `blockhash` returning zero is ambiguous — it means *expired*
and it means *has not happened yet* — but it reasons about the **outcome** seed
only. The eligibility seed had the same ambiguity, no guard, and one property that
makes it worse: `H(…, 0, m)` is a perfectly good hash, so an unguarded predicate
does not fail. **It silently selects a different eligible set**, and that set is
computable by anyone from the moment the case exists.

Both ambiguous states occur, and the one at the head occurs **every round**:

```
eligSeedBlock  = roundOpen + SEED_LAG                        = roundOpen + 2
readable       = roundOpen + 3  ..  roundOpen + 258          (SEED_LAG + HORIZON)
commit phase   = roundOpen + 0  ..  roundOpen + 240          (commitBlocks, §1)

head:  3 blocks, EVERY round, where the seed block does not exist yet
tail: 18 blocks of margin before the seed expires
```

**The head gap is the serious one.** For the first three blocks of every commit
phase the seed block has not been produced, so an unguarded implementation
evaluates every moderator against `roundSeed = 0` — a set that depends only on
`caseId`, and is therefore precomputable at submission, hours ahead. An attacker
computes which of their identities pass under the zero seed for every live case and
commits in those blocks. Everyone else is waiting for a seed that does not exist
yet. **That is not a tail edge case reachable under drift; it is every round, by
construction**, and it hands the opening of each cohort to whoever is watching for
it — the always-on party §3.3 and FINDINGS §C are already about.

**Both guards are block-height comparisons, never observations of the returned
hash** (I29). A guard phrased as "the seed is unavailable" is true in both states
and distinguishes neither, which is the defect I29 was written from — in the
*other* seed, one section over.

**When the tail guard fires, the failure is graceful.** Commits revert for the
remainder of the phase, turnout is whatever arrived before it, and a thin round
ends `UNRESOLVED(NO_TURNOUT)` — free retry, no debit for anyone (§4.8, and the
non-reveal debit does not apply there either). A round that loses its seed loses
its votes, not its participants' bonds.

**The arithmetic constraint, now that both sides are in blocks** (§0, I31):

```
commitBlocks  ≤  SEED_LAG + BLOCKHASH_HORIZON  =  258
```

At `BLOCK_TIME = 5 s` a 20-minute window is 240 blocks, so the margin is **18
blocks** and the bound on `BLOCK_TIME` is `1200 / 258 = 4.651 s`. `RulesetGovernor`
must validate it: a governance change below that bound does not fail loudly, it
re-points the tail of every commit window at a zero seed.

**The head gap is not a defect to be closed but a cost to be stated.** A moderator
cannot evaluate eligibility before the seed exists; that is arithmetic, not a rule.
So the *usable* commit window is `commitBlocks − SEED_LAG − 1` = **237 blocks**,
and §1's twenty minutes is the scheduled length rather than the workable one.

### 3.2 Domain separation

Every hash binds `chainId`, contract address, `caseId`, round and purpose. The
eligibility seed and the outcome seed are separate values with separate domains
(§7); neither can be substituted for the other.

### 3.3 The threshold, and in-window widening

```
threshold(c, r, t) = T                      for t < roundOpen + LATE_WIDEN_AT
                     T · LATE_WIDEN_FACTOR   thereafter
```

`T` is set so that the expected eligible count is `TARGET_COHORT`.

**The widening schedule is fixed when the round opens** — it is not conditional on
how many commitments have arrived. Conditional widening reads live state and
creates a race between the widening boundary and the commitments that trigger it.
A fixed schedule needs no keeper transaction, no fresh seed, and no state read.

Widening is **monotonic**: a moderator eligible at `T` stays eligible at `1.5T`.
And it is **uniform** — the threshold applies to every identity's hash equally, so
the expected honest/hostile composition of the marginal pool equals that of the
population. Widening cannot be used to shift composition.

This replaces v2's multi-day quorum-failure extension entirely (v2 §4.4). There is
no extension in this specification.

### 3.4 One vote per moderator per claim

A moderator may vote **once per case**, not once per round. Having voted in round 0
makes a moderator ineligible for round 1.

The rule is per *claim*, not per round, because a moderator who could vote twice
would be counted twice in a pooled tally, and the tally is what the verdict is
drawn from.

**A commit consumes the allowance, not a reveal.** Scoping it to reveals lets a
moderator commit in round 0, abandon for the price of `REVEAL_BOND`, and commit
again in round 1 with the round-0 tally in hand — the ballot secrecy of §4.7 buys
nothing against someone who can wait and re-enter. I3 is therefore about commits.

### 3.5 A challenge is a bond, not a vote

**Decision.** Registering a challenge requires being `ACTIVE` and posting
`CHALLENGE_BOND`. **No eligibility test, for any round.** It does not cast a vote
and does not disclose a direction. Round 1 opens at the scheduled close of the
challenge window, never at the moment the challenge lands (§3.5b).

v2 §4.7 made the challenge itself a public vote against the standing verdict, and
accepted the resulting disclosure as unavoidable: concealing the challenger's
direction and restricting challenges to disagreement are mutually exclusive.

Under v3 the constraint dissolves, because a challenge no longer needs to *be* the
objection. Round 1 is a full commit–reveal round; the challenger commits inside it
like everyone else, hidden. What the bond buys is the round, not a position in it.

**Why there is no eligibility test — three reasons, in order of weight.**

*It was circular and could not be implemented.* An earlier revision required the
challenger to be eligible for round 1, and §3.1 evaluates eligibility against
`roundSeed(c, 1)` — a seed the same transaction armed. The `require` would have had
to read a value from the future. This is P0-7, "next-round challenge seed is
circular", closed in v2 at `a4ac471` and reintroduced here by the new lifecycle.

*It excluded exactly the people the mechanism depends on.* §3.4 makes round-0
voters ineligible for round 1, so the eligibility test barred **the round-0
dissenting minority** — the only people who have read the content and know the draw
went against their reading. `h`, the probability the honest side challenges a loss,
is the single quantity deciding whether the challenge round halves the
false-approval rate or nearly doubles it (design-v3 O10), and the test removed its
best-informed contributors.

*A probabilistic filter on who may pay is regressive.* Eligibility admits about
`TARGET_COHORT / registry` of identities per round. Someone holding hundreds of
identities always has one that passes; a legitimate single-identity dissenter is
blocked with probability `1 − 40/|registry|`, which approaches certainty as the
registry grows. The filter inconvenienced attackers not at all and honest
challengers almost always.

**What still constrains a challenge**, now that eligibility does not:

- `CHALLENGE_BOND`, debited unconditionally (§4.6). Not forfeit *on a condition* —
  there is no condition, because every condition available was one the challenger
  could evaluate before registering.
- §4.5's monotonicity — a challenge that adds no votes returns the same verdict,
  so registering one buys nothing on its own.
- One challenge per claim (I17). The first valid registration wins; later ones
  revert rather than queue.

**Round-0 voters may register a challenge. They still may not vote in round 1.**
§3.4 is about the tally and is unchanged — a moderator counted twice would corrupt
the pooled tally the verdict is drawn from. Registering is not voting. A round-0
dissenter who challenges spends `CHALLENGE_BOND` and keeps their existing exposure
to `d` on the pooled tally. The bond is a price, not a stake: they are buying a
second round, and what they win or lose by it is the verdict, on the same terms as
every other voter (§4.6).

Two consequences worth stating:

- The challenger's direction is secret, so round-1 voters cannot herd behind it.
- A challenger who registers and then reveals *in agreement* with the published
  plurality has wasted a bond and gained nothing. No rule is needed to prevent it.

### 3.5b Round 1 opens on the schedule, not on the challenge

**Decision.** A challenge *registers* at any point inside the challenge window.
Round 1's commit phase opens at the window's **scheduled close**, the same instant
at which an unchallenged case would have finalized.

Without this, round 1's seeds are functions of the block the challenger chose:

```
        rejected:  eligSeedBlock₁ = challengeTxBlock + SEED_LAG
                                    -- the block the challenger chose

        adopted:   eligSeedBlock₁ = scheduledRound1OpenBlock + SEED_LAG
                                    -- submitBlock + commitBlocks + revealBlocks
                                       + challengeBlocks, fixed at submission
```

(There is no separate round-1 outcome seed: §4.5 realizes one randomness per claim
and §7.2 schedules its block from the submission height, unconditionally.)

The challenger has twelve hours of discretion over *when* to file. Under the
rejected form that is twelve hours of discretion over **which cohort is drawn and
which entropy decides the case** — the same free option §4.4 refuses to grant the
last revealer, handed to a party who gets to look at the round-0 result first.
Round 1's eligibility seed is now fixed at the scheduled window close, and the
claim's single outcome block is fixed at submission (§7.2), so I7 holds for both
rounds.

It also removes a targeting advantage the rejected form created: with round-1
eligibility derived from the challenge block, an attacker could search block
heights for one that makes their own identities eligible, then file there.

**The cost, stated.** A challenge no longer resolves a case sooner than leaving it
alone. Finality is `CHALLENGE_WINDOW + COMMIT_WINDOW + REVEAL_WINDOW + grace`
whether or not anyone challenges, so the challenge buys a second round rather than
an earlier answer. Uniform latency is the better property: it means the observable
timing of a case leaks nothing about whether it was contested.

### 3.6 What the contract may not compute

**The contract must never attempt to enumerate the eligible set**, and no
transition may depend on "all eligible moderators have acted."

Eligibility is a per-identity hash test over the whole registry. Membership is
cheap to prove; *completeness* — that no eligible identity was omitted — requires
touching the complement, which is `O(registry)` on chain. This is the same defect
as v2's `totalActiveModerators` (P0-9), and it is why §4.4 closes phases on the
clock alone.

---

## 4. Case state machine

### 4.1 Storage

```
struct Case {
    uint8   phase;
    uint8   round;             // 0 or 1
    uint8   terminal;          // APPROVED | REJECTED | UNRESOLVED | none
    uint8   unresolvedReason;  // NO_TURNOUT | NO_REVEALS | NO_RANDOMNESS
    uint32  paramsVersion;     // I27 — the immutable parameter block in force at
                               //   submission. Every debit this case produces is
                               //   computed from it, never from the live values
    uint128 pot;               // the initial pot, and it never grows: the
                               //   reserve is added at SETTLEMENT, not held
                               //   here (§5.3). An earlier comment said "grows
                               //   by the reserve on challenge", which was the
                               //   rule before the activation became proportional
    uint128 challengeReserve;  // escrowed throughout; refunded, or activated in
                               //   part at settlement (§5.3)
    uint40  phaseDeadline;     // a BLOCK HEIGHT, not a timestamp (§0)
    uint40  eligSeedBlock;     // armed at round open
    uint40  outcomeSeedBlock;  // armed at submission, from the SCHEDULED heights
    uint32  commitBlocks;      // the three window lengths in blocks, converted
    uint32  revealBlocks;      //   ONCE at submission from BLOCK_TIME(c) and
    uint32  challengeBlocks;   //   pinned with every other parameter (I27)
    uint32  pooledApprove;     // POOLED across rounds, never reset
    uint32  pooledReject;
    uint32  commitsThisRound;
    uint32  revealsThisRound;
    uint32  reveals0;          // round-0 reveal count, recorded for §8.3
    bool    unanimousDraw;     // were all three tickets the same side? §8.3
                               //   reads this; nothing reads `u` back, because
                               //   §4.5 realizes and uses it in one transaction
    Outcome plurality;         // which side led at round-0 close; a FACT, and
                               //   no randomness has been realized when it is set.
                               //   Total on any tally, ties included — §4.2
    Outcome verdict;           // written once, at the binding draw
    address challenger;
    bytes32 outcomeEntropy;    // blockhash(outcomeSeedBlock), stored at the FIRST
                               //   draw so u is re-derivable for the life of the
                               //   claim (§4.5, §8.5). blockhash expires; this
                               //   does not, and a re-review must not re-roll
    uint40  finalizedAt;       // a TIMESTAMP — a record, never compared (§0)
    // content, metadata, topics, ruleset/guidelines versions: as v2
}
```

Votes **pool**: `pooledApprove` / `pooledReject` accumulate across both rounds and
are never reset. The binding draw is taken against the pooled tally.

### 4.2 Phases

```
                              ┌──────────── challenge (§3.5) ────────────┐
                              │                                          │
COMMIT ──▶ REVEAL ──▶ TALLY ──┤                                          ▼
                       │      └── window closes, no challenge ──▶ … ──▶ DRAW ──▶ FINALIZED
                       │                     COMMIT₁ ──▶ REVEAL₁ ──▶ ┘
                       │
                       └── no commits / no reveals ──▶ UNRESOLVED
                           or outcome seed expired

both terminals are LEAVES. Settlement is not a phase: claim(c, m) runs once
per participant, whenever they choose, and changes nothing about the case
(§5.5). A re-review reopens a FINALIZED claim at COMMIT (§8.5).
```

**Both terminals discharge, and neither has a successor.** `UNRESOLVED` releases
escrows and liabilities without writing a verdict (§4.8), exactly as `FINALIZED`
does with one. **There is no case-level `SETTLED` state**, because §5.5 pulls
settlement per moderator: a case whose participants have all claimed is
indistinguishable from one where a single moderator has not yet bothered, and a
state the machine can be permanently unable to enter is not a state. `SETTLED` is a
fact about a *(moderator, case)* pair, and it is the claim record's absence
(§2.1).

**There is exactly one draw, and it is the last thing that happens.** `TALLY`
publishes the round-0 **plurality** — which side leads, a *fact* about the votes.
It is not a verdict, no randomness has been realized, and none exists until
`DRAW`, which sits after the challenge window and after round 1 if there is one.

**Why the interim result is a plurality and not a draw.** An earlier revision drew
a provisional verdict at round-0 close. Because §4.5 fixes the randomness once per
claim, that published `u` — and the three tickets collapse to a single number
`m = median(u)/2^128`, with `verdict = (a > m)`. Publishing it handed every party
the exact number of votes needed to flip the case, twelve hours before they had to
decide whether to challenge. A challenger no longer faced a lottery; they read the
price and acted only when it was cheap, which is 17% of the time at `a₀ = 0.3125`.
And in that branch §4.6 cleared their bond and §5.3 paid them, so a successful flip
cost gas.

Realizing `u` after all voting closes removes the channel rather than pricing it.
The challenge decision returns to what it should be — a judgement about whether the
pool will move — and the deterrence figures §4.5 quotes become the unconditional
statistics they were always computed as.

**The plurality is a total function of a tally, ties included.**

```
plurality(A, R)  =  Approve   iff  A > R
                    Reject    otherwise          <- a tie is a Reject plurality
```

It has to be total, because §7.3 debits against it when the seed expires and §8.2
publishes it to readers, and neither has a sub-case for "undefined". A partial
function would go silent at exactly the tally where the two sides are hardest to
separate, which is where a party would steer to reach the silence. (A third rule
used to read it — §4.6's forfeit, on whether round 1 *moved* it — and H7 removed
that one for reading it at all.) Ties break to Reject by
§4.8's rule that a bounded failure is correct and an unsafe success is not.

**This is not a tie-break in the verdict.** The verdict is drawn, and at `A = R`
the draw is `f(0.5) = 0.5` — unchanged, and I12 with it. The plurality decides who
*owes*, never who wins.

**Nothing is paid and nobody is debited before a terminal state.** The pot stays
escrowed throughout. The plurality credits no coherence, applies no penalty, and
moves no value **while the case is live**; §4.8 is where it acquires a settlement
role, and only in the one terminal that has a tally and no verdict.

### 4.3 Transition table

| From | To | Trigger | Effect |
|---|---|---|---|
| — | `COMMIT` | `submit(...)` | charge fee; split into pot / reserve / bounty / maintenance; reserve dedup keys (§8.4); pin ruleset and guidelines versions; **convert the three windows to block counts from `BLOCK_TIME(c)` and pin them — the only wall-clock→block conversion in the specification (§0, §7.2)**; `round = 0`; arm both seeds (§7); `phaseDeadline = block.number + commitBlocks(c)`. **No moderator is selected, reserved, or notified on chain.** |
| `COMMIT` **(r=0)** | `REVEAL` | `block.number ≥ phaseDeadline` and `commitsThisRound ≥ MIN_COMMITS` | `phaseDeadline = block.number + revealBlocks(c)` |
| `COMMIT` **(r=0)** | `UNRESOLVED` | `block.number ≥ phaseDeadline` and `commitsThisRound < MIN_COMMITS` | **`terminal = UNRESOLVED`**; `unresolvedReason = NO_TURNOUT`; **write the index entry** in `O(MAX_TOPICS)` (§8.1). Nobody could have steered this — see §4.8 |
| `COMMIT` **(r=1)** | `REVEAL` | `block.number ≥ phaseDeadline` | `phaseDeadline = block.number + revealBlocks(c)`. **No quorum gate in round 1** — §4.9 |
| `REVEAL` **(r=0)** | `TALLY` | `block.number ≥ phaseDeadline` and `pooled ≥ 1` | pool this round's reveals; publish the **plurality** (§8.2) — a fact, not a verdict; `reveals0 = revealsThisRound`; `phaseDeadline = block.number + challengeBlocks(c)` |
| `REVEAL` **(r=0)** | `UNRESOLVED` | `block.number ≥ phaseDeadline` and `pooled == 0` | **`terminal = UNRESOLVED`**; `unresolvedReason = NO_REVEALS`; **write the index entry** (§8.1). Not a policy gate — there is no tally to draw from — but **steerable**, see §4.8 |
| `TALLY` | `TALLY` | `challenge()` (§3.5): `mayChallenge(caller)` (§2.4), `block.number < phaseDeadline`, `challenger == 0` | **registers only.** `challenger = msg.sender`; `openChallenges++`. Nothing is transferred — the bond is *covered*, not escrowed (§2.4). No phase change, no seed armed, no deadline moved. A second call reverts (I17) |
| `TALLY` | `COMMIT` | `block.number ≥ phaseDeadline` and `challenger != 0` | `round = 1`; **`revealsThisRound = 0`; `commitsThisRound = 0`**; arm the round-1 **eligibility** seed from this scheduled close (§3.5b, §7.1); `phaseDeadline = block.number + commitBlocks(c)`. **`challengeReserve` is not touched** — it activates at settlement, in proportion to round-1 reveals (§5.3), so opening a round moves no value |
| `TALLY` | `DRAW` | `block.number ≥ phaseDeadline` and `challenger == 0` | enter the waiting state. **Nothing is enabled in `DRAW` until `block.number > outcomeSeedBlock`** (§7.2) — on this path that is ~40 minutes away, because the seed block includes the round-1 windows whether or not round 1 runs |
| `REVEAL` **(r=1)** | `DRAW` | `block.number ≥ phaseDeadline` | pool round-1 reveals. **No threshold** (§4.6), and none needed (§4.9) |
| `DRAW` | `FINALIZED` | `outcomeSeedBlock < block.number ≤ outcomeSeedBlock + BLOCKHASH_HORIZON` | **store `outcomeEntropy = blockhash(outcomeSeedBlock)`**, then derive `u[0..2]` from it and evaluate `verdict` against the **pooled** tally (§4.5) — **the only randomness in the claim's life**, re-derived unchanged at any later re-review (§8.5); **`terminal = APPROVED | REJECTED`**; store `unanimousDraw`; pay `DRAW_BOUNTY`; `finalizedAt = now`. `CHALLENGE_BOND(c)` settles at the challenger's `claim()`; the reserve activation is O(1) and is computed here, at `FINALIZED`, because `share` depends on it (§4.6, §5.3, §5.5) |
| `DRAW` | `UNRESOLVED` | `block.number > outcomeSeedBlock + BLOCKHASH_HORIZON` | **`terminal = UNRESOLVED`**; `unresolvedReason = NO_RANDOMNESS`; **write the index entry, retaining the plurality** (§8.1, §8.2); pay `DRAW_BOUNTY` to the caller. **The pooled tally survives into settlement** — this is the one `UNRESOLVED` row that leaves one behind, and §4.8 settles every tally-derived obligation against it |
| `FINALIZED` | — | `claim(c, m)` | **per moderator, not per case** (§5.5), and it never touches the index (§8.1, I15). Settles one participant's claim: pay `share` if coherent, debit otherwise, discharge their claim record and decrement `openVoteCount` / `openChallenges` / `m.liabilities` (§2.4, I32). Permissionless, self-funded, order-independent. **There is no case-level `SETTLED`** — see below |
| **`UNRESOLVED`** | — | **`claim(c, m)`** | **§4.8 — per-moderator discharge, same shape. The index entry was written at the transition into `UNRESOLVED` and settlement does not touch it (§8.1, I15). Fire exactly the obligations whose requirement this terminal meets (§4.8's table, I30): no verdict was drawn, so nothing is paid, no listing appears, no reputation is credited and `challengeReserve` does not activate; `CHALLENGE_BOND(c)` is debited wherever one was registered; the non-reveal debit applies wherever a reveal phase opened, which is every reason except `NO_TURNOUT`; the incoherence debit applies wherever a settled side exists, which is `NO_RANDOMNESS` alone. Decrement `openVoteCount`, `openChallenges` and `m.liabilities` per §2.4; refund per §4.8. Nothing is "returned" — `REVEAL_BOND` was covered, never escrowed (§5.2)** |

Every transition is permissionless. `DRAW_BOUNTY` pays for the draw poke — the only
transition with a hard expiry — and `CLAIM_BOUNTY` for finalization. **Neither
bounty is what makes its transition happen**; §7.3 derives the draw poke from the
plurality-losing side's own debit, and finalization has no deadline to miss.

**Guards must be pairwise disjoint** (§9 I18). Every row above is qualified by its
round where the round matters; a state reachable by two rows with different effects
is a defect, not an implementer's choice.

**The table covers phase transitions. The operations below are the other writers,
and I18–I19 quantify over these too.** Omitting them left the rules that police
`commitsThisRound`, `revealsThisRound` and the pooled tally silent about the calls
that write them, and gave I3 no row to live in:

| Call | Precondition | Effect |
|---|---|---|
| `commit(c, h)` | phase is `COMMIT`; `block.number < phaseDeadline`; caller eligible (§3.1); **caller has not committed to `c` in any round** (§3.4, I3); `mayCommit` (§2.4) | store `h`; `commitsThisRound++`; `openVoteCount++`; `m.liabilities += LAMBDA(c)` |
| `reveal(c, v, salt)` | phase is `REVEAL`; `block.number < phaseDeadline`; `h == H(…, v, salt)` binding chainId, contract, `c`, round, `paramsVersion` and the caller | pool `v`; `revealsThisRound++` |
| `challenge(c)` | §4.3's `TALLY → TALLY` row | as that row |
| `postBond`, `requestExit`, `withdraw` | §2.3 | as §2.3 |

`commit` consumes the one-vote-per-claim allowance, not `reveal` (§3.4).

**`terminal` is written by every row that reaches a terminal state**, and by no
other row. §8.2 and §8.4 both key on it, and an earlier revision left it unwritten
by the whole table — an I19 counterexample inside the invariant written to catch
exactly that.

**Every field in §4.1 must be written or provably preserved by every transition**
(§9 I19). `revealsThisRound` is the field this rule exists for: without the reset
above, the round-1 threshold reads round 0's count and §4.6 is unreachable for
every `reveals₀ ≥ 12`.

**No phase closes early.** Not when every committer has revealed, not when the
challenge window is quiet, not when a cohort appears complete. §4.4 and §7.2 give
the two independent reasons.

### 4.4 Deadlines are fixed and closure is never conditional

Each phase ends at `phaseDeadline`, **a block height** fixed when the phase opened
(§0). Every guard that reads it compares against `block.number`, and the seed
schedule of §7.2 is built from the same counter, so no comparison in this document
spans two units.

**Early closure on "everyone revealed" hands the last actor the entropy.** The
reveal set is on-chain, so whoever holds the last reveal would choose between
closing now and letting the deadline close it — a free binary choice over outcome
seeds. At a hostile 30% of reveals over `N = 34` — `â = 0.306` — that raises their
odds from `f(â) = 22.3%` to `1 − (1−0.223)² = 39.6%` (design-v3 §7). No stake, no
identities, no extra votes.

**Early closure on "everyone eligible has acted" is not computable** — §3.6.

**Starting a window at the first commit lets that committer choose the hour**, and
therefore which population is awake to vote. The relevant hostile share is of
*reveals*, not of registered stake (§9 I11), so this is an attack on the tally's
composition rather than on the votes.

The general result: **early termination is either useless or unsafe.** Keep the
outcome block fixed and closing early buys nothing, because the draw still waits
for that block. Let the outcome block move with the close and the last actor picks
the entropy. An external beacon does not change this.

What *is* permitted, and should be implemented: **permissionless immediate
finalization.** Once the outcome block exists, anyone may finalize in that block.
That removes the grace period from the common path without moving a deadline.

### 4.5 The draw — one randomness per claim, taken against a posterior

**Decision.** Three uniforms are realized **once per claim, at `DRAW`** — after
the challenge window and after round 1 if there is one. There is no earlier
evaluation to reuse them for.

```
u[i] = uint128( H(OUTCOME_DOMAIN, chainId, contract, caseId, i,
                  blockhash(outcomeSeedBlock)) )          i = 0,1,2
       -- realized and used in the SAME transaction (§4.3's DRAW row)

N  = pooledApprove + pooledReject
â  = (pooledApprove + 1) / (N + 2)                        -- NOT pooledApprove / N
ticket[i] = ( u[i] · (N + 2)  <  (pooledApprove + 1) · 2^128 )
verdict   = (ticket[0] + ticket[1] + ticket[2] ≥ 2) ? Approve : Reject
```

`u[i]/2^128` is uniform on [0,1), so `P(ticket = Approve) = â` and
`P(verdict = Approve) = 3â² − 2â³ = f(â)`. Verified at 400k draws over tallies of
`N = 34`, empirical against closed form: 0.2231/0.2230, 0.5004/0.5000,
0.7769/0.7770, 0.9801/0.9803.

**Why the draw is taken against `â` and not against `A/N`.**

`A/N` is a sample proportion of `N` votes, and `f` consumes it as though it were
the population's Approve rate. At `N = 1` that is a claim of certainty from one
observation, and the mechanism acts on it: `f(1) = 1`. `â` is the posterior mean of
that rate under a uniform prior — the add-one estimator. Three things follow.

**`f(â)` is an approximation, and an earlier revision of this paragraph claimed it
was not.** It said `â` is *"the quantity `f` was always meant to receive"*. That
does not follow, because `f` is not linear: `f(E[θ]) ≠ E[f(θ)]`. The exact
posterior predictive of the same three-ticket rule under the same uniform prior is

```
θ ~ Beta(A+1, N−A+1)

E[f(θ)] = 3·E[θ²] − 2·E[θ³]
        = (A+1)(A+2)·(3N − 2A + 6) / ((N+2)(N+3)(N+4))
```

— exact integer arithmetic, monotone in both directions (verified over `N < 120`),
and in `(0,1)` at every tally. **`f(â)` sits above it everywhere except the exact
tie**, in both directions, and the gap is largest where the estimator matters most:

```
unanimous tally     N=1     N=3     N=8    N=16    N=40
f(â)             0.7407  0.8960  0.9720  0.9911  0.9983
E[f(θ)]          0.7000  0.8571  0.9545  0.9842  0.9968
overruled: f(â)   25.9%   10.4%    2.8%   0.89%   0.17%
           exact  30.0%   14.3%    4.6%   1.58%   0.32%
```

**Decision: the plug-in is kept, and this document says why rather than implying
there is nothing to keep.** `f(â)` is what three independent ticket comparisons
compute, and the three tickets are the senior reviewer's rule (design-v3 §11) and
the shape the whole of §4.5's optional-stopping argument is written in. The exact
rule is one uniform against a rational and would be marginally cheaper, but it is a
third change to the core verdict arithmetic in one revision, and the residual it
removes is **0.15 points at the working cohort size**. The judgement is that churn
in this particular expression costs more than the residual does.

**What that decision buys and what it costs, stated so a later revision can
re-open it on evidence.** It buys stability in the one expression every other
section quotes. It costs a known over-claim, and *every figure in this document and
in design-v3 derived from `f` inherits it* — 1.97% censorship at `a = 0.95, N = 34`
is `1 − f(â)`; under `E[f(θ)]` it is 2.47%. Those figures are labelled with the
estimator they were computed under, per I33, so nothing here reads as exact that is
not.

**Shrinkage and plug-in error run in opposite directions**, which is why the
residual is easy to miss: `â` moved the small-`N` numbers a long way toward the
right answer and stopped short. At `N = 3` a unanimous cohort is overruled 10.4%
under `f(â)`, 14.3% exactly, and **100% of the way wrong under `A/N`, which said
0%.** The estimator change was the large correction; this is the tail of it.

**`â ∈ (0, 1)` for every finite `N`, so neither outcome is ever certain.** That is
what I12 asserts, and under `A/N` it was false at every unanimous tally — which is
also every tally a party who controls all the reveals can produce.

**It is parameter-free.** `α = 1` is the uniform prior and it is symmetric. Any
other `α` is a claim about content in general; an asymmetric pair is a thumb on the
scale, which §5.3 and §6 refuse elsewhere. There is nothing here to sweep.

**It converges, and the distortion is bounded and largest where the evidence is
weakest.** At `N = 34` the two rules differ by at most 1.4 points, and the
difference is symmetric about `a = 0.5`:

```
A/N        0.00    0.09    0.29    0.41    0.50    0.71    0.91    1.00
f(a)     0.0000  0.0220  0.2086  0.3690  0.5000  0.7914  0.9780  1.0000
f(â)     0.0023  0.0343  0.2230  0.3762  0.5000  0.7770  0.9657  0.9977
```

**I22 survives, and the proof is one line.** Adding an Approve vote takes `â` from
`(A+1)/(N+2)` to `(A+2)/(N+3)`, and `(A+2)(N+2) − (A+1)(N+3) = N + 1 − A > 0`
because `A ≤ N`. Adding a Reject vote leaves the numerator and raises the
denominator. Every added vote moves `â` strictly toward its own side — which is
what the optional-stopping argument below runs on, and it would fail for a
smoothing that was not of this form.

**What it denies, and how weakly.** At a unanimous tally the cohort is overruled
with probability:

```
N                     1       3       8      16      24      40     100
P(overruled)      25.9%   10.4%    2.8%   0.89%   0.43%   0.17%   0.03%
```

An attacker who owns all sixteen reveals of a minimum-quorum case still gets 99.1%.
**I12 is not a wall and this document should not pretend otherwise.** What it buys
is that no incentive argument here has a degenerate branch: §7.3's
`f(â)·(share + d) > 0` and §8.4's "every draw has an approval branch" are strict at
*every* tally under `â`, and both were ties at a unanimous one under `A/N`.

**What it costs.** `simulation/v3/FINDINGS-v3.md` §G measures it. False rejection of
safe content with no attacker rises by 0.3 to 2.1 points depending on `prior`; the
amplifier's crossover (§A) and the honest-accuracy table (§E6) move within noise.
The cost is real, it lands on the number this design is already weakest on (§10,
the permanence of `REJECTED`), and it is second-order against the 26–60% that
honest error contributes there.

**Note the comparison form.** `u · (N+2) < (approve+1) · 2^128`, *not*
`u mod (N+2) < approve+1`. Both are uniform, but only the first is **monotone in
`â`**: with `u` fixed, adding Reject votes lowers `â`, which can flip tickets from
Approve to Reject and never the reverse. The modulo form reshuffles on every change
of `N`, so a single added vote acts as a fresh re-roll. Simulated over 20,000
fixed-`u` draws sweeping `a` across [0,1]: zero monotonicity violations. Both
operands fit a `uint256` without care — `u` is 128 bits and `N+2` is at most 32, so
the left side is under 160 bits, and so is the right.

**Why this is the whole answer to challenge-round optional stopping.**

A challenger who adds no votes changes nothing — the tally is identical, so the
tickets are identical, so the verdict matches the round-0 plurality's draw. A
challenger who adds votes
moves `a`, and can only move the verdict *toward the side they added*. **There is
no second roll to buy.** The only way to change the answer is to change the
evidence, which is what the round is for.

What that costs an attacker who lost round 0 at 10 Approve, 22 Reject — `a₀ =
0.3125`, `â₀ = 11/34 = 0.3235`, which is the number the draw actually reads. The
median of three uniforms is `Beta(2,2)` whose CDF is `f` itself, so these are exact
quantiles rather than a simulation (I33):

```
Approve votes needed to flip the verdict
    median  22        10th pct  4        90th pct  103
    48.8% of the time they need more than 22 — parity in the pooled tally or worse
    6.7%  of the time two votes suffice

under a fresh round-1 draw they need ZERO extra votes for a 24.6% chance
```

So the rule converts *buy another lottery ticket* into *buy a majority of the
pool*. Priced deterrence is replaced by a structural one, which matters because the
prize — the listing — is external and cannot be priced.

**It also removes most of the design's exposure to `h`.** design-v3 O10 named
honest challenge reliability as the single quantity deciding whether the challenge
round helps or hurts. Simulated at 30% hostile, `TARGET_COHORT` 40, honest turnout
0.8:

```
                     h=0      h=0.25    h=0.5     h=1.0    none
fresh round-1 draw   0.483    0.434     0.383     0.285      —
same u (adopted)     0.598    0.613     0.608     0.606    0.592
```

**Source: `simulation/v3/FINDINGS-v3.md` §B, at the commit that last touched
`simulation/v3/` (I33).** The adopted row was quoted here for three revisions as
0.316 / 0.309 / 0.300 / 0.284, from a run predating the prior-aware model, and it
was not refreshed when the engine was. The *fresh-draw* row is from that same old
run and is kept only as the contrast the argument is about; what matters is the
range, not the level.

A fresh draw makes the challenge round a 20-point gift to an attacker when the
honest side is unreliable. The same-`u` rule flattens that to **1.6 points** — the design
stops depending on a quantity that lives outside the contract.

**Consequences elsewhere:**

- **One outcome seed per claim, not per round** (§7.1). Round 1 needs an
  *eligibility* seed only. `NO_RANDOMNESS` is therefore reachable at `DRAW` and
  nowhere else — one place, not "the round-0 draw", since there is only one draw
  (§7.1) — and the 256-block `blockhash` horizon never has to span the 12-hour
  challenge window.
- **The entropy is stored; the three uniforms are not.** An earlier revision
  realized `u` at round-0 close and had to keep all three for twelve hours. With
  the draw last, realization and use are one transaction — but §8.5's re-review
  reopens a claim after `blockhash` has expired, and it must return an identical
  verdict on an unchanged tally. So one word is kept, `blockhash(outcomeSeedBlock)`,
  from which all three tickets re-derive forever. One slot, not three, and it is
  what makes "one randomness per claim" true for the *life* of the claim rather
  than for one opening of it. §8.3's `unanimousDraw` flag also survives, because
  is the one thing read back.
- **Nothing about `u` is knowable while anyone is still voting.** `u` is realized
  at `DRAW`, after every reveal in both rounds. An earlier revision realized it at
  round-0 close and published it, which reduced the whole mechanism to one public
  threshold `m = median(u)/2^128` with `verdict = (a > m)`: the exact flip cost was
  computable twelve hours before the challenge decision, so a challenger read the
  price instead of facing a lottery. Deferring the draw removes that channel rather
  than pricing it.

**With replacement is still required**, and now trivially: `u[0..2]` are
independent, so a side holding one revealed vote keeps `f(â) = 0.997%` at `â = 2/34`.
Without independence a 31–1 tally would decide with certainty — though since §4.5
took the draw against `â`, so would a 31–1 tally *with* replacement under the old
`A/N`, and the estimator now carries that argument. Sampling with replacement is
still necessary; it stopped being what makes I12 true.

The implementation must guard `N > 0` explicitly: `MIN_REVEALS` is gone (§4.8), so
`N ≥ 1` is now the only thing standing between the draw and a division by zero, and
a revert inside the draw leaves a case permanently unfinalizable.

### 4.6 A challenge that does not move the tally

**Decision.** `MIN_CHALLENGE_REVEALS` is **removed.** There is no threshold, no
sub-threshold branch, and no second verdict rule.

The floor existed to stop a challenger buying a second draw against a nearly
unchanged tally. §4.5 makes that impossible by construction — an unchanged tally
yields an identical verdict — so the floor has no remaining job, and it carried
three defects of its own:

- **It judged voters against a tally they were excluded from.** A sub-threshold
  round-1 Reject vote was debited against a verdict drawn from the round-0 tally
  alone. Eleven dissenters against a 20–0 provisional had *zero* probability and
  were all penalised. That violated I12, the invariant §9 names as one of the two
  this design is least free to relax, and I11.
- **It was unsatisfiable exactly when it mattered.** `max(12, reveals₀/2)` scales
  with round-0 turnout while round-1 supply is capped near `TARGET_COHORT` and then
  reduced by §3.4. For `reveals₀ > 2 · TARGET_COHORT` the challenge round is
  unreachable by construction — so flooding round 0 both won the provisional draw
  *and* disabled the mechanism that exists to correct it.
- **It was a coordination trap.** Round-1 voters could see the commit count against
  the floor. Below it, revealing was pointless, so nobody revealed, so the floor was
  missed. Failure was self-fulfilling.

**`CHALLENGE_BOND` is settled on nothing. It is debited unconditionally:**

```
every terminal reachable from TALLY  ->  bond -= CHALLENGE_BOND(c), to the
                                         maintenance reserve
                                         openChallenges--, m.liabilities -= what
                                         this case added              (§2.4)
```

There is no branch, so there is no test, so there is nothing for a challenger to
steer. An earlier revision settled the bond on **whether round 1 moved the
plurality**, and that had two defects that are really one defect seen from either
end.

**The test is passed by whoever can supply its answer.** The plurality is published
with its tally at `TALLY` (§4.7), twelve hours before the challenge decision, so a
challenger reads the exact margin round 1 must swing. A party holding many
identities knows how many of them round 1 will admit, compares the two numbers, and
registers only when they already win — the bond never bites them. A legitimate
single-identity dissenter cannot know whether strangers will turn up, so the bond
bites *only* them. **The difficulty of the test is inversely proportional to how
much of the round-1 cohort you own**, which is the exact opposite of what a bond
against frivolity is for, and §10 names the single-identity dissenter as the party
it most wants to protect.

**And the test asked the wrong question.** The protocol does not want the challenger
to be *right*; it wants them to supply evidence, and evidence that confirms is as
informative as evidence that overturns. A challenge that draws twenty new voters
who uphold the round-0 plurality has told the system something real. The old rule
took that challenger's bond *and* their share of the pot. Paying only for
overturning makes the challenge a bet on the outcome — and a bet is precisely what
a party who can supply the outcome should never be offered.

**What the forfeit branch was actually holding up.** §4.9 identifies an extraction
channel: `challengeReserve` moved into the pot on registration, so a round-0
*winner* could register purely to enlarge a pot they would share in. The forfeit
closed that by taking the loser's share. It is closed at its source instead — §5.3
now activates the reserve **in proportion to the round-1 turnout it exists to pay
for**, so a challenge that attracts nobody activates nothing and there is no
over-provision to extract. Fixing the source lets the compensating rule be deleted
rather than kept and qualified.

Nothing was transferred at registration, so the debit is the first movement of the
bond. It runs at the challenger's own `claim()` alongside every other debit of
theirs, so it inherits §5.1's
commutativity and §4.8's discharge guarantee, and it goes to maintenance and never
to another moderator (I14, I21).

**The challenger is paid for their vote, if they cast one, on exactly the terms
everyone else is.** They have no special case in §5.3 any more. Their motive for
challenging is the verdict, which is what it should have been: the bond was a
second prize sitting beside the first, and it muddied which one they were playing
for.

The activated portion of `challengeReserve` stays in the pot and is distributed,
because the round-1 voters who turned up performed real work — and §5.3 activates
exactly the portion their turnout accounts for.

Round-1 reveals **always** pool and are **always** judged against the same fact
every other reveal is judged against — the final verdict where one is drawn, the
pooled plurality in the one terminal that has no verdict (§4.8). There is no round
whose votes are scored on a different basis from the rest of the claim's.

### 4.7 What may be published between rounds

Between `DRAW` and `FINALIZED` the contract may expose the pooled tally, the reveal
count, the round, and the `plurality`. It may **not** expose anything that lets a
round-1 voter learn a round-1 vote before round-1 reveals open — that is what
`REVEAL_WINDOW` and the commit hash exist for.

The plurality is published deliberately, and O11 in design-v3 records the cost: a
`PLURALITY_REJECT` is visible for twelve hours and has effect even when the draw
later goes the other way. **It carries no randomness**, so unlike the provisional
verdict it replaced, it tells an observer nothing about the outcome beyond what
the votes already say.

### 4.8 `UNRESOLVED`

**Decision.** One terminal state with a reason code, rather than separate
`NO_QUORUM` and `VOID` states as in v2. The code is not a label: it determines the
debits and the retry rule.

| Reason | Condition | Steerable? | Retry |
|---|---|---|---|
| `NO_TURNOUT` | `commitsThisRound < MIN_COMMITS` at commit close | **no** — commits are blind | free, full refund |
| `NO_REVEALS` | commits cleared the gate and `pooled == 0` at reveal close | **yes**, but only by holding *every* commit | claim reserved for `RETRY_COOLDOWN`, pot carried forward |
| `NO_RANDOMNESS` | the fixed outcome seed expired unread (§7.3) | **not by any party who can reach it.** Poking is dominant for the submitter at every tally (§7.3) and for the plurality-losing revealers at every non-unanimous one, so no coalition that *wants* the expiry can also produce it. **The plurality-winning revealers do gain** — they pay no debit either way and their gain is the gap between `f(â)` and certainty — and that residual is stated below rather than denied here | **no retry.** The claim carries `REJECTED`'s reservation by reference (§8.4, I26); the pot is refunded less maintenance |

**There is exactly one quorum gate and it is on commits.** Commits are made blind —
the tally does not exist yet — so no committer can steer it toward a result they
cannot see.

**The reveal-stage gate is removed, not relocated.** An earlier revision added the
commit gate and *kept* `MIN_REVEALS`, which left a second gate selecting between
terminal classes on state every revealer can watch. That gate was the only thing
that ever made withholding attractive, and it created two problems at once:

- **It was steerable, so I24 was false.** The `MIN_REVEALS − 1`-th revealer chose
  between a draw and a result-free `UNRESOLVED`, on observable state, for the price
  of one `REVEAL_BOND`.
- **Its treatment served the wrong attacker.** Reserving the claim and charging a
  fresh fee is right against a submitter converting a bad tally into a retry. It is
  a *payload* for a censor, whose prize is that the content stays unlisted: they
  paid `d` per withheld identity and received a lockout plus a levy on their
  victim. `RETRY_COOLDOWN` was one knob pulled in opposite directions by the two,
  and no value defeats both.

**Removing the gate makes withholding dominated twice over.** Your vote is on some
side; withholding removes it, which strictly lowers that side's probability —

```
tally     P(your side) if you reveal    if you withhold
13A/7R                        0.6995             0.6752
10A/10R                       0.5000             0.4643
 6A/14R                       0.2393             0.1983
```

— *and* forfeits `REVEAL_BOND` (§5.2). A censor who withholds now removes their own
Reject votes, moving the tally toward Approve. The lever is not priced; it points
the wrong way.

`N ≥ 1` remains, because a draw needs a tally. That is arithmetic, and no party can
force it without withdrawing every one of their own votes.

**`N ≥ 1` is a floor on existence, not on confidence, and it was carrying both
jobs.** With the draw taken against `A/N`, a single revealed vote decided the case
*with certainty* — and the two invariants that look like they cover it did not.
I11 was about "under-quorum", a phrase that has meant the commit gate since the
gate moved there, so a case can clear it and reach `APPROVED` on one reveal. I12
quantified over "every side with ≥ 1 revealed vote", which at a unanimous tally is
one side, and it has probability 1. **Both read true and neither said anything
about the configuration they exist to prevent.** §4.5's `â` is what separates the
two jobs: existence stays at `N ≥ 1`, and confidence becomes a function of `N`
rather than an assumption about it.

In every case: no verdict, and no listing, because both need a draw. **The debits
and the claim key are not uniform across the three rows**, because the three rows
do not leave the same facts behind.

**Every obligation names its own requirement, and a terminal fires exactly those
whose requirement it meets** (I30). Not three groups — the previous revision sorted
obligations into *reads nothing / reads the tally / reads the verdict*, and the
partition did not fit its own members:

```
obligation            fires iff                          NT  NR  NRand  A/R
------------------------------------------------------------------------------
CHALLENGE_BOND        a challenge was registered          -   -    y     y
non-reveal debit      a reveal phase OPENED               -   y    y     y
incoherence debit     a settled side exists               -   -    y     y
claim key held        a settled side exists               -   -    y     y
reserve activation    a verdict was drawn                 -   -    -     y
payment (§5.3)        a verdict was drawn                 -   -    -     y
listing status (§8.2) a verdict was drawn                 -   -    -     y
reputation (§6)       a verdict was drawn                 -   -    -     y

NT = NO_TURNOUT   NR = NO_REVEALS   NRand = NO_RANDOMNESS   A/R = APPROVED|REJECTED
```

**The settled side** is the verdict where one was drawn and the pooled plurality
(§4.2) where one was not. It is total wherever `pooled ≥ 1`, which is what lets the
incoherence debit name *one* input instead of an input and a fallback. §5.1 uses it
at the debit site.

**Why the groups had to go.** They partitioned obligations by what each *reads*,
assuming every obligation reads exactly one of the three. The reserve activation
reads two: the **tally** for its size (round-1 reveals over round-0) and the **verdict**
for whether it happens at all — it offsets the dilution of a payment, and with no
payment there is nothing to offset. The previous revision filed it under the tally,
while §4.3 and §4.8 both filed it under the verdict. Those are not two readings of
one rule; they are two rules, and the money does not balance between them.

**The failure, with numbers.** A challenged case reaches `NO_RANDOMNESS` with
`reveals0 = 30`, 20 round-1 reveals, `pot = 80`, `challengeReserve = 20`. Under the
grouping, the activation fires: `min(20, floor(80·20/30)) = 20` moves into `pot`.
The value-flow block below then refunds `pot + challengeReserve` in full. **Twenty
is paid out twice against an escrow that holds it once.** That is an insolvency,
not a bookkeeping quibble, and it exists because one obligation was asked which
group it belonged to when the honest answer was "both".

**A requirement is a property of the obligation; a group is a property of the
partition.** Naming the requirement per obligation means a new rule cannot be
mis-filed — there is no cell for it to land in wrongly, only a condition it must
state. Magnitudes are unconstrained: an obligation may compute its size from
anything the terminal holds. Only the requirement decides whether it fires.

`NO_RANDOMNESS` has a **complete pooled tally and is missing nothing but `u`**, so
every obligation short of the verdict fires there exactly as it would have on the
finalized path, the claim key included. No verdict is drawn in any of the three, so
none of them pays, lists, credits reputation or activates the reserve.

**The index still gets an entry** — §8.2's `UNRESOLVED` is a status value, not an
absence, and a reader must be able to tell "judged, undrawn" from "never
submitted"; what none of the three writes is a *listing*. Revealers are paid
nothing in any `UNRESOLVED`; what changed at H4 is that in `NO_RANDOMNESS` they no
longer *lose* nothing either.

**Non-revealers are debited wherever a reveal phase opened — and in `NO_TURNOUT`
none did.** `REVEAL_BOND` is charged for failing to complete a voluntary
commitment, which is not contingent on the case reaching a verdict; an earlier
revision waived it across all of `UNRESOLVED` and so made withholding free in
exactly the state withholding produces. But it over-corrected to *every terminal
state*, and `NO_TURNOUT` closes at commit close with the reveal phase never opened.
**Every committer is vacuously a non-revealer there, and all of them are debited
for a quorum failure the same table calls unsteerable and refunds in full.** A
debit for something nobody could have done is the shape item 1 removed from the
schedule; it is I29's class, and the requirement table above is what makes it
visible — the non-reveal debit's requirement is *a reveal phase that opened*, not
*a terminal state*.

Nothing is bought back by charging it there. `NO_TURNOUT` cannot be caused: commits
are blind and the only way to force it is to not commit, which is free regardless.
So the debit deters nothing and prices a market failure to the people who showed
up for it.

**`UNRESOLVED` discharges, like every other terminal.** An earlier revision made it
a leaf with no discharge path at all, which left `openVoteCount` permanently
incremented for everyone who had committed — and since `withdraw` requires
`openVoteCount == 0` (§2.3), their stake and bond were locked forever by the
design's own intended failure mode. **Every terminal state must discharge every
liability it created** (§9 I20).

**Value flow, stated exactly.** `challengeReserve` is escrowed throughout and
activates only at settlement, in proportion to round-1 reveals (§5.3). No terminal
here draws a verdict, so nothing is paid, so nothing activates:

```
every reason      ->  refund pot + challengeReserve IN FULL — the reserve
                      never activates here, because activation requires a
                      verdict and none was drawn (§5.3)
                      pay nobody, list nothing, credit no reputation
                      -- the index entry was ALREADY written, at the
                         transition that set terminal = UNRESOLVED (§8.1,
                         §4.3). Settlement never touches the index
                      decrement openVoteCount, openChallenges and
                      m.liabilities by what this case added   (§2.4, I20)
                      retain finalizationBounty and maintenance

NO_REVEALS,       ->  debit every non-revealer REVEAL_BOND(c)  (I25)
NO_RANDOMNESS,        nothing is RETURNED — the bond was covered, never
APPROVED/REJECTED     escrowed (§5.2), so there is nothing to give back

NO_TURNOUT        ->  no non-reveal debit. The reveal phase never opened, so
                      nobody failed to open a commit; the requirement is a
                      reveal phase, not a terminal (I25)

NO_TURNOUT,       ->  no incoherence debit: there is no tally to be incoherent
NO_REVEALS            with. No challenge can be outstanding in either row either
                      — both are reached before TALLY, which is where the
                      challenge window opens (§4.3)

NO_RANDOMNESS     ->  debit d(c) to every revealer on the losing side of the
                      POOLED plurality (§4.2), and debit CHALLENGE_BOND(c) as
                      every terminal past TALLY does — it reads nothing, so
                      there is nothing here it cannot read (§4.6)
                      hold the claim key on REJECTED's terms (§8.4, I26); the
                      index entry retains the published plurality beside the
                      UNRESOLVED status, since that is what was established
```

The reason code is load-bearing rather than diagnostic: it decides both the debits
above and the retry rule. `NO_TURNOUT` is a market problem nobody can cause,
because commits are blind. `NO_REVEALS` is steerable by a party holding every
commit, so its retry is delayed and its pot carried. `NO_RANDOMNESS` is the only
row that ends with the content **judged**, so I26 attaches to it and it does not
retry at all (§8.4) — which is also what removes the last party who wanted it.

**Why the `NO_RANDOMNESS` debits are here at all.** The full argument is §7.3; the
short version is that the losing side's debit is now charged in **both** branches,
so it cancels out of their comparison, and the draw is the only branch that can pay
them. Under the earlier rule — nothing debited in `NO_RANDOMNESS` — the losing side
of a visible tally strictly preferred the case to die, and §4.3 paid `DRAW_BOUNTY`
to whoever poked the *expiry*, so waiting it out was not merely free but funded.
That made I24 false by inaction, and the answer then on offer was to size a bounty
against gas: a parameter defending an invariant.

**What the rule costs.** A genuine failure of liveness now debits the
plurality-losing revealers. Three things bound that:

- **A chain halt cannot cause it.** `BLOCKHASH_HORIZON` is counted in blocks, not
  in wall time, so reaching `NO_RANDOMNESS` requires 256 blocks to be *produced*
  with nobody spending gas on a poke that pays a bounty. That is a market failure
  with every participant present, not an act of god.
- **Everyone who is debited had the whole horizon to prevent it**, and only one of
  them had to act.
- **Near a tied tally the debit falls on a side that was one vote from being the
  other side.** That is the sharpest edge of the rule, and it is off-equilibrium
  precisely because it is sharp: the party it falls on is the party who acts.

**Why `NO_REVEALS` is separated from `NO_TURNOUT`.** An earlier revision folded
"nobody revealed" into `NO_TURNOUT` and marked the whole row unsteerable. It is
not: a party holding *every* commit on a case can withhold all of them and reach a
terminal that, under the free-retry treatment, hands the claim back. The bar is
high — they must be the entire committing cohort — which is why this is a
reservation rather than a redesign. But I28 does not cover them, and §4.8's own
steerability column is what decides the retry rule, so the row has to be honest.

**`NO_RANDOMNESS` reserves the claim permanently and refunds the pot.** Both halves
matter and they answer different parties.

The reservation answers the **submitter**, for whom any retry is worth more than
any draw — every draw has a branch that ends the claim permanently and a retry has
none, so the preference holds on the Approve plurality as well as the Reject one.
§8.4 has the table. A cooldown is not a smaller version of this rule; it is the
same windfall at a discount, and `RETRY_COOLDOWN` was the knob that would have had
to be sized against `f(a)` to suppress it. The refund answers the *fee*: nothing is
levied, because levying the submitter for an outcome nobody drew would repeat the
mistake the `WITHHELD` treatment made — locking and levying the same party pays an
attacker twice. `maintenance` is retained, as in every terminal, because a cohort's
attention was really consumed.

**Every party who can gain from the expiry can now also prevent it, and prefers
to.** The plurality-losing revealers by §7.3's debit, the submitter by §8.4's
reservation. What is left is the **plurality-winning revealers**, who pay no debit
either way and whose gain is the difference between `f(a)` and certainty. That gain
is largest near a tie and vanishes as `a → 1` — and near a tie the losing side is
nearly as large, with every one of them facing a certain `d`. **The size of the
group that benefits and the size of their benefit move in opposite directions**,
which is the strongest form the argument takes without a mechanism that removes the
51-minute window, and §7.3 explains why no such mechanism is available under
`blockhash`.

**`UNRESOLVED` must never be reachable from an under-quorum pool by approving it.**
A bounded failure is correct; an unsafe success is not.

### 4.9 Round 1 has no quorum gate, and needs none

**Decision.** `MIN_COMMITS` is tested at round 0 only. Round 1
always proceeds to its reveal phase and always proceeds to `DRAW`, whatever
turnout it attracts — including none.

**Why no gate is needed.** By §4.5 the verdict is `u` evaluated against the pooled
tally, and `u` is fixed for the claim. A round 1 that adds no votes leaves the
pooled tally identical to round 0's, so the draw sees exactly what it would have
seen without the round *by arithmetic*.
An empty challenge round is self-healing; it does not need a rule.

**Why a gate is actively harmful here.** An earlier revision applied the
`MIN_COMMITS` gate to both rounds, and that recreated the defect F8 named — with a
cheaper trigger than the one F8 described. A submitter whose content was
shown a `PLURALITY_REJECT` could register a challenge, let round 1 go quiet, and take
`UNRESOLVED(NO_TURNOUT)`: claim released, pot refunded, resubmit freely (§8.4). A
permanent rejection escaped for the price of `CHALLENGE_BOND`, using nothing but
*inaction* — no seed expiry, no coordination, no votes.

The general rule this is an instance of, stated so the next revision cannot
reintroduce it a third time:

> **I26 — once a claim has been tallied, no reachable terminal may release that
> claim's key.** Monotone in "voting has happened", not in "a draw has occurred":
> the draw is now the last transition, so keying the rule to it would leave every
> pre-draw terminal outside it."

**`CHALLENGE_BOND` on an empty round 1.** It is debited, as it is on every round 1
(§4.6). There is no condition, so an empty round is not a special case of anything
— the challenger paid to summon a round and one was held; nobody came.

**Who funds what, stated correctly.** The reserve is prepaid by the *submitter*
(§1) and the bond is paid by the challenger to maintenance. An earlier revision
moved the whole reserve into the pot the moment a round opened, which meant a
registration moved the **submitter's** money to the round-0 coherent side — an
extraction channel, because §3.5 removed the eligibility test and a round-0
*winner* may therefore register purely to enlarge a pot they will share in. §5.3
closes it by activating the reserve in proportion to round-1 *reveals*: an empty
round activates nothing, the submitter's money comes back, and registering moves no
value at all.

**An earlier revision closed it by forfeiting the failed challenger's share** of
the pot on top of `CHALLENGE_BOND(c)` — they asserted the pool was not good enough
to draw from, it was, so they were not paid for the round they caused. That made
the extraction loss-making without needing any relation between `CHALLENGE_BOND`
and the reserve, which §10 could not have supplied anyway. It is withdrawn: H7
showed "the pool moved" is a test the well-resourced challenger passes by
construction and the single-identity dissenter fails by circumstance, so the
forfeit landed on whichever party could least predict it (§4.6).

**What that revision got right, and what carries forward.** Its reasoning about
*where* a forfeited share goes was correct and is worth keeping as a general rule
even though nothing is forfeited any more:

> A share removed from one moderator must go to the maintenance reserve, and the
> moderator must **stay in the divisor `W`**. Removing them instead would shrink
> `W` and hand every remaining winner a larger `share` — the same forbidden
> transfer wearing different clothing (I14). A penalty must cost the party it
> falls on and cost everyone else nothing.

That is now a statement about any future penalty rather than about this one, which
is the difference between a fix and a property (§9).

The reserve still activates on *turnout*, not on success: round-1 voters who showed
up did real work, and paying them out of a pot the extra turnout also dilutes is
what the reserve exists to prevent.

---

## 5. Settlement

### 5.1 Penalties are balance debits, never time

At `claim(c, m)`, for that moderator's revealed vote (§5.5 — per moderator, not a
sweep over the case):

```
coherent with verdict     -> bond += share           (§5.3)
incoherent with verdict   -> bond -= d(c)            -> maintenance reserve
committed, never revealed -> bond -= REVEAL_BOND(c)  -> maintenance reserve (§5.2)
```

**"Coherent with the verdict" is shorthand for coherent with the *settled side*,
which §4.8 defines once so this site does not need a fallback:**

```
settled side  =  the verdict, where one was drawn
                 the pooled plurality (§4.2), where one was not
```

It is total wherever `pooled ≥ 1`, so the incoherence debit names **one** input
rather than an input and an exception, and §4.8's table can state its condition —
*a settled side exists* — in the same form as every other obligation's. In
practice the substitution reaches exactly one terminal, `UNRESOLVED(NO_RANDOMNESS)`,
because it is the only one holding a complete tally it never drew from:

```
on the settled side       -> bond += share, but ONLY where a verdict was drawn;
                             payment has its own condition and no terminal
                             without a verdict pays anything (§4.8)
against the settled side  -> bond -= d(c)     -> maintenance reserve
```

**`d(c)` is the same coefficient either way** — not a second penalty with its own
parameter, but the same penalty reading the best fact the terminal has. And note
the asymmetry, which is deliberate and is what H4's dominance argument runs on:
the debit fires on the plurality, the payment does not.

**Every debit carries `(c)` — the case's pinned parameters, never the live ones**
(§2.4, I27). §2.4 says "no coefficient is read at settlement at all", and that is
only true if the debit sites say so too: an earlier revision pinned the
*accumulator* and left all three debits written as bare `d`, `REVEAL_BOND`,
`CHALLENGE_BOND`. A case pinned at `LAMBDA(c) = 100` whose settlement debits a
governance-raised 150 drives `bond` negative, and §5.4 mandates revert-not-clamp,
so **that one moderator's presence reverts the settlement batch for every other
voter in the case** — and by §4.3's discharge path pins their liabilities, which by
I13 blocks their withdrawal.

**Every value removed from `bond` has a named destination, and it is never another
moderator** (§9 I14, I21). `d(c)`, `REVEAL_BOND(c)` and `CHALLENGE_BOND(c)` all go
to the maintenance reserve. Routing any of them to the opposing side would create
punishment farming — an incentive to provoke losses rather than to judge content —
which design-v2 §5.5 forbids.

**No moderator is suspended for any period.** This replaces v2's per-unit freezing
and, before it, identity-wide suspension. Three properties follow, and each was a
finding under the old rule:

**Order-independence is arithmetic, not engineering (P0-6).** Debits commute:
applying the penalties of a set of settled cases in any order gives the same bond.
Time intervals do not commute — v2's identity-wide rule cost the same three losses
24 days or 19 depending on settlement order, and per-unit expiry was a mechanism
built specifically to recover a property that subtraction supplies for free.

**The cost of a loss does not scale with concurrency (§9 I9).** A loss costs `d`
and a win pays `share`; both are per case. The risk/reward ratio `d / E[share]` is
a chosen constant. Under identity-wide freezing the ratio was `freeze_days ×
concurrent_cases` — unbounded when concurrency is, and perverse in direction, since
the more a moderator participated the more confidence they needed to vote. It
produced zero honest turnout at every fee from 3 to 300.

**Nothing needs to be released.** A freeze must expire, which means storage that
must be written, read and expired. A debit is done when it is applied.

### 5.2 Non-reveal

`REVEAL_BOND` is **covered** at commit, not posted. Nothing is transferred: §2.4's
`mayCommit` test requires the balance to be able to absorb it, and a committer who
never reveals is then debited it **to the maintenance reserve**. A committer who
reveals is debited nothing — there is no return, because there was no transfer.

An earlier revision said "posted at commit" two sentences before "debits nothing at
commit". Those cannot both be true of one balance, and the ambiguity decided
whether `max(d, REVEAL_BOND)` was the right coefficient or whether committing
carried an unstated liquid-capital requirement outside `bond`. It is covered, not
moved, so the coefficient stands and committing is free.

It must not go to the opposing voters. Transferring a penalty to the other side
creates punishment farming — an incentive to provoke non-reveals rather than to
judge content — which design-v2 §5.5 forbids and which no version of this design
has ever permitted.

This is a *price* on the free option that commit–reveal creates, not a
reservation: it debits nothing at commit, caps nothing, and enters §2.4 only
through `LAMBDA`'s `max(d, REVEAL_BOND)` term.

**`REVEAL_BOND = d + G` is derived, not chosen.**

A committer holding belief `p` that they are coherent with the eventual verdict
compares:

```
reveal    ->  p · share − (1 − p) · d
withhold  ->  − REVEAL_BOND

reveal is at least as good  iff  p · share − (1 − p) · d + REVEAL_BOND ≥ 0
```

**Revealing costs gas and withholding does not**, and an earlier revision of this
comparison had no term for it. With `g` the gas cost of a reveal:

```
reveal    ->  p · share − (1 − p) · d − g
withhold  ->  − REVEAL_BOND
```

At `REVEAL_BOND = d` the difference reduces to `p · (share + d) − g`, so
**withholding strictly wins below `p = g / (share + d)`** — and §10 calls the
fee-over-gas margin the binding constraint in every simulation so far, which is
exactly the regime where that band is wide:

```
 gas / share      withholding wins for p <
        0.10                        0.042
        0.25                        0.104
        0.50                        0.208
        1.00                        0.417
```

**Dominance therefore requires `REVEAL_BOND ≥ d + G`**, with `G` a conservative
bound on `g`. At that value the minimum of `reveal − withhold` over `p ∈ [0,1]` is
exactly 0 for every `g ≤ G`, and §2.4's `LAMBDA ≥ max(d, REVEAL_BOND)` then gives
`LAMBDA = d + G`.

So `REVEAL_BOND` is **not** closed, and removing it from §10's sweep list was
wrong: it is floored by a quantity that moves with gas price, and bounded above
only by the capacity cost of a larger `LAMBDA`. The "two constraints meet at one
point" result was an artefact of the missing term.

**What the deferred draw already closed.** The sharper half of this was that `p` is
not a *belief* in round 1: with `u` published, a round-1 voter could compute that a
flip was out of reach, sit at `p = 0` exactly, and be pushed the wrong way by any
positive gas. §4.2 now realizes `u` after all voting, so nobody can compute `p`
while it still matters. What remains is the ordinary band above, which `G` closes.

**What this closes and what it does not.** It closes selective reveal for anyone
optimizing *inside* the protocol's payoffs — the ordinary case, and the one
`design-v3` O5 is about. It does not close it for an attacker whose
prize is a listing, which is external and cannot be priced against. Against those,
the second reason of I28: withholding removes the withholder's *own* votes, so it
strictly lowers the probability of the side they were pushing. §4.8 removed the
`MIN_REVEALS` gate that was the only way to convert withholding into a result, so
there is nothing left for an external prize to buy here.

### 5.3 Payment

```
reveals1  = (pooledApprove + pooledReject) − reveals0     -- round-1 reveals
activated = min( challengeReserve , floor(pot · reveals1 / reveals0) )
P         = pot + activated
W         = votes matching `verdict`, from either round
share     = floor(P / W)
remainder = P − share · W                 -> maintenance reserve, never to moderators
challengeReserve − activated              -> refunded to the submitter
```

**`reveals1` is derived, not stored, and that is the whole of the fix.** An earlier
revision wrote it as a bare name. It is not a field: §4.1 has `revealsThisRound` and
`reveals0` and nothing else, so the only binding available to an implementer is
`revealsThisRound` — and `TALLY → COMMIT` resets that for round 1 while
`TALLY → DRAW` does not. **On the unchallenged path `revealsThisRound` still holds
round 0's count**, so

```
activated = min(reserve, floor(pot · reveals0 / reveals0)) = reserve
```

and the entire challenge reserve activates into the pot of a case nobody
challenged. The submitter's refund of `challengeReserve − activated` is zero, on
most cases, which is the exact inverse of what the next paragraph says this rule is
for. An implementer who binds it that way is not misreading the specification; the
specification does not say.

Written as `(pooledApprove + pooledReject) − reveals0` it is **zero on the
unchallenged path by arithmetic**, not by a reset someone has to remember to
perform, and both operands are fields §4.1 declares and every path maintains.

`reveals0 ≥ 1` is guaranteed by the `REVEAL(r=0) → TALLY` guard, so the division is
total wherever this formula runs — and by §4.8's table it runs only where a verdict
was drawn, which is downstream of that guard. Both counts are **tally facts, fixed
at reveal close and independent of the verdict** — the reserve must not become a
second quantity a party can steer by choosing an outcome (I30).

**The reserve activates in proportion to the dilution it exists to offset.** Its
job (design-v3 §2.1) is that opening a challenge must not tax the round-0 voters by
splitting one pot more ways. Holding their share roughly constant needs
`pot · reveals1 / reveals0`, which is what the formula pays, capped at what the
submitter prepaid. Beyond the cap the reserve is exhausted and dilution resumes,
which is honest and bounded. Below it, the unspent remainder goes back to the
submitter, who prepaid for a round that did not happen at the size it was priced
for.

**This is what closes §4.9's extraction channel, and it closes it at the source.**
An earlier revision moved the whole reserve into the pot at round-1 open, on a
boolean — so a challenge that attracted nobody still enlarged the pot for the
round-0 coherent side by the full reserve, and a round-0 *winner* could register
purely to collect that. §4.6's forfeit existed to take it back, and H7 showed the
forfeit fired on the wrong party.

**Registration now activates nothing; reveals do.** That is the whole of the fix:
the challenger's lever is decoupled from the money. What remains is that a marginal
reveal marginally enlarges the pot and its caster shares in it — but that is the
general property that turnout is subsidised, it applies to every voter equally, and
one extra reveal is worth `pot / reveals0` split `W` ways, which is under a
thousandth of the pot at working sizes. It is not a channel a challenger has
privileged access to, which is what the old rule's `challengeReserve`-for-one-bond
was.

It also moves the reserve's activation to **settlement**, where every other value
movement in this document lives. Activating at round-1 open changed what §4.8 would
refund before any terminal was reached.

Four things are irrelevant to both payment and penalty, **for every voter including
the challenger**: which round they voted in, whether their own ballot was sampled as
a ticket, whether their side won the round-0 plurality, and whether the challenge
reversed it. The exception a previous revision carved out for the challenger is
gone with §4.6's forfeit.

**Expected cash is not direction-neutral, deliberately** (design-v3 §5). A majority
voter expects `(P/N)·f(a)/a`, a minority voter `(P/N)·(1−f(a))/(1−a)`. `design-v2`
§4.2's neutrality theorem is no longer a requirement of this design; it remains
correct as the statement of what was given up.

### 5.4 A debit can never exceed the bond

By §2.4, `bond ≥ BOND_MIN + liabilities(m)` held after every operation that added
a claim, so the total debit from every outstanding claim resolving against the
moderator at once is covered by construction. **Write `liabilities(m)`, not
`LAMBDA · openVoteCount` and certainly not `d · openVoteCount`** — the narrower
forms are equal only under today's parameter choices and today's set of debits, and
recording the value rather than the property is how a bound gets broken by a change
made somewhere else. It already happened twice here: once when `REVEAL_BOND` was
omitted from `LAMBDA`, and once when `CHALLENGE_BOND` was omitted from the
liability function entirely.

**Two bounds, and only one of them was ever stated.** The paragraph above bounds
the debit by what the *moderator* covered. §2.4 now also bounds it by what the
*claim* covered — `amount ≤ claims[m,c,k].amount`, enforced at the call rather than
argued from completeness. The second is the stronger of the two and it is the one
that survives a second logic contract: a caller with no claim on a moderator can
debit them nothing at all, whatever their bond says.

**The implementation must not clamp.** A `bond -= d(c)` that would underflow indicates
a broken invariant, not a case to handle gracefully, and clamping would hide it.
Revert, and treat it as I1 having failed.

A moderator whose bond falls below `BOND_MIN + m.liabilities` after debits is
not penalised further and is not suspended. They simply cannot commit to anything
new until they post more bond or their open votes settle. This is the whole of what
"insolvency" means here.

### 5.5 Settlement is pulled per moderator, not swept per case

**Decision.** `claim(caseId)` settles **one moderator's** claim on one case. There
is no sweep, no batch cursor, and nothing that has to walk the committer list. Each
call is permissionless and each is paid for by the party it settles.

Order-independence is unchanged and is what makes this safe: debits commute (§5.1)
and `verdict` is fixed at `FINALIZED`, so no interleaving of claims produces a
different result from any other. `share` is `floor(P / W)` with `W` maintained as
`pooledApprove` or `pooledReject` — **O(1) at `FINALIZED`, not a pass over
ballots** — so a claimer needs no aggregate to be computed before they can be paid.

**Why the sweep had to go: `bounded` was load-bearing and was not true.** I20
requires every terminal to discharge every liability *within a bounded number of
permissionless calls*, and an earlier revision funded that with `CLAIM_BOUNTY`, a
fixed fraction of a fixed fee. The committer count is not bounded: eligibility is
`H(...) < T` with `T` calibrated so the **expected** cohort is `TARGET_COHORT`, and
the realized cohort is `Binomial(registry, T/2^32)` with no ceiling. Sweep cost is
linear in committers; the funding is constant. Past the crossover **nobody settles
the case, and by §2.4 every moderator in it has `liabilities != 0` and cannot
withdraw** — the permanent lock §4.8 was written to prevent, reached through
economics instead of through a missing discharge path.

That is reachable two ways and only one of them is an attack. `simulation/v3/FINDINGS-v3.md`
§D already measures the other: with `T` calibrated for a registry of 1,000, a
registry of 10,000 gives an expected cohort of 400. **F9's "too large is an
economic failure" and this are the same finding from two sides**, and the design
had a cap for it once — v1's `MAX_PANEL = 128`, which the governor validated,
because `drawPanel` at 128 seats measured 1.83M gas. v3 replaced a validated cap
with an expectation.

**A cap is the wrong fix here, and it is worth saying why so it is not
reintroduced.** Eligibility is passive and evaluated off-chain by each moderator
independently. A ceiling on commits makes entry first-come-first-served, which is a
gas auction — and the party who wins a gas auction against a human with a push
notification is the always-on attacker the cap was meant to stop. **A cap converts a
liveness attack into a composition attack**, which is strictly worse: instead of
locking the case it hands them the tally.

**Pull removes the aggregate cost rather than bounding it.** There is no sum that a
fixed bounty has to cover, because there is no sum: `n` participants make `n`
independent calls, each paying their own gas for their own settlement.

**Winners claim because they are owed. Losers claim because not claiming costs
more.** That asymmetry is what makes the rule need no bounty at all:

```
settle a losing vote   ->  bond -= d(c), and LAMBDA(c) of capacity is released
leave it unsettled     ->  LAMBDA(c) = d + G stays encumbered, forever
```

`LAMBDA(c) > d(c)` by §2.4, so **abandoning a loss locks strictly more than paying
it costs**, and the encumbrance is permanent: §2.4's `mayCommit` charges it against
every future commit and I13 blocks withdrawal outright. A moderator who walks away
from a debit has paid more than the debit to avoid it. Nobody needs to chase them,
which is the same dominance shape as §5.2's reveal argument and §7.3's poke.

**`CLAIM_BOUNTY` survives, scoped to what is actually unbounded-in-nothing:**
finalization, which is one `O(MAX_TOPICS)` transaction (§8.1) that must happen for
readers even if no moderator ever claims. It is no longer trying to fund a sweep
whose size an attacker chooses.

A finalized losing vote still counts against `openVoteCount` until **that
moderator's** claim settles, so it cannot be reused before its debit lands.

---

## 6. Reputation

`track` is a decayed, saturating count of coherent participations, updated at
settlement and retained through withdrawal.

**It does not weight votes and does not scale penalties in this revision.** v2 used
it to scale freeze duration, which made the penalty depend on the winning side's
track record and so made total utility direction-dependent even where cash was not.
With cash neutrality already abandoned (§5.3), adding a second direction-dependent
term compounds a cost this design has not priced.

Its role here is narrow and worth stating precisely: **it is what an identity
forfeits by being abandoned.** Maturation alone is not churn resistance, because a
funded attacker pre-ages identities in bulk. What makes replacement expensive is
that track record does not transfer.

Whether `d` should scale with `track` is `design-v3` O6 and triage D4, and it is
open. The update must be order-independent whatever is decided.

---

## 7. Randomness

### 7.1 Two seeds per round

| Seed | Scope | Derived from | Used for |
|---|---|---|---|
| `eligSeedBlock` | **per round** | that round's **scheduled** open height + `SEED_LAG` | §3.1 eligibility |
| `outcomeSeedBlock` | **per claim** | the schedule in §7.2 — the submission height plus **all four** windows | §4.5 — realized once at `DRAW` |

**Both are heights derived from heights** (§0). Neither is a prediction about when a
wall-clock instant will arrive, which is what the previous revision's
`blockAt()` was and why it drifted (§7.2).

**There is one outcome seed per claim, not per round** (§4.5), and it sits after
every window whether or not round 1 runs. Round 1 has an eligibility seed and no
outcome seed of its own.

Two consequences, both corrected from an earlier revision that left this table
deriving the seed from round 0's reveal close:

- **`NO_RANDOMNESS` is reachable at `DRAW` and nowhere else** — which is one place,
  not "the round-0 draw", because since `78bf686` there is only one draw and it
  serves the challenged path too.
- **The `blockhash` horizon never spans the challenge window.** The seed block sits
  *after* it, so the readable interval runs from a point every case has already
  reached rather than racing twelve hours.

Every schedule is fixed at submission. Round 0's open is the submission block;
round 1's scheduled open is the close of the challenge window, which §3.5b makes
independent of when a challenge was filed. So **no seed in this specification is a
function of any transaction's timing**, which is what I7 asserts.

An earlier revision armed round 1's seeds in the `challenge()` transaction. That
gave the challenger twelve hours of discretion over both the round-1 cohort and the
entropy that would decide the case, after seeing the provisional verdict — and made
the challenger's own eligibility check circular. §3.5 and §3.5b close both.

### 7.2 The outcome block is fixed from the schedule, never from the transaction

```
at submit, once, from the pinned BLOCK_TIME(c)  -- the only conversion (§0)
    commitBlocks(c)    = ceil( COMMIT_WINDOW    / BLOCK_TIME(c) )
    revealBlocks(c)    = ceil( REVEAL_WINDOW    / BLOCK_TIME(c) )
    challengeBlocks(c) = ceil( CHALLENGE_WINDOW / BLOCK_TIME(c) )

outcomeSeedBlock = block.number                                // submit height
                 + commitBlocks + revealBlocks                 // round 0
                 + challengeBlocks
                 + commitBlocks + revealBlocks                 // round 1, always
                 + SEED_LAG
```

**Both sides of every comparison now come from `block.number`.** `phaseDeadline` is
a height, `outcomeSeedBlock` is a height, `BLOCKHASH_HORIZON` is a block count, and
the case reaches `DRAW` at exactly `outcomeSeedBlock − SEED_LAG` by construction.
Drift is not tolerated; it is not expressible.

**`ceil`, not floor** — rounding a window down shortens the notice a human
moderator gets, and §1's minutes are the intent that the blocks approximate.

**The round-1 windows are in the formula whether or not round 1 happens.** An
unchallenged case waits for the same block a challenged one does, so the outcome
block does not depend on when the final reveal arrives, whether the case was
challenged, **when** it was challenged, who called the transition, whether everyone
revealed early, or when round 1 opened. There is exactly one such block per claim.

This is what makes §3.5b's uniform-finality claim true rather than aspirational: an
earlier revision finalized unchallenged cases at the challenge-window close and
challenged ones ~40 minutes later, so the observable timing of a case leaked
whether it was contested. This is what makes §4.4's "no early closure" rule enforceable
rather than advisory, and it closes both M2.5-F10 and the selective-realization
surface (P1-2).

**The `blockAt()` this formula used to call does not exist.** An earlier revision
wrote the schedule in wall-clock seconds and the seed as a block height, with no
way to convert between them except `block.number + seconds / ASSUMED_BLOCK_TIME`.
That put a conversion *inside* a comparison, and the two sides then drifted apart
at the difference between assumed and actual block time. Measured at the §1 working
values:

```
path            reaches DRAW at   needs actual block time ≥   fails if blocks run
challenged           48,000 s              4.869 s                   2.7% fast
unchallenged         45,600 s              4.626 s                   8.1% fast
```

Three things made it worse than a tolerance:

- **Fast blocks were fatal and slow blocks were benign**, so the failure was
  one-sided and the safe direction was the one nobody optimizes for.
- **The challenged path was tighter**, so under drift contested cases died first —
  the exact inversion of this section's uniform-finality goal.
- **`NO_RANDOMNESS` became unreachable-by-anyone rather than chosen.** The horizon
  burned while the case was still in `COMMIT₁`/`REVEAL₁`, so `draw()` reverted for
  every party, and §4.8 then debited `d(c)` to every plurality-losing revealer for a
  clock mismatch none of them could have prevented. §7.3's rarity argument — "256
  blocks produced with nobody spending gas on a poke" — was false in exactly the
  state that produced the terminal.

That last one is I29's class in the section written to satisfy I29: a rule correct
in isolation, firing in a state its own justification does not describe. The fix is
not a wider tolerance or a guard on the `DRAW` row. **It is that a schedule
compared against a block-denominated constant is denominated in blocks** (§0, I31),
which is a property of the schedule and cannot be satisfied one row at a time.

### 7.3 No lazy re-arming — and "unavailable" is not a test

If the seed block has **passed out of reach** — `block.number > outcomeSeedBlock +
BLOCKHASH_HORIZON` — the case terminates `UNRESOLVED(NO_RANDOMNESS)`. **A fresh
future block is never selected.**

**The condition is a block-height comparison, never an observation of the returned
hash.** `blockhash` returns zero both for a block that has expired and for a block
that has not happened yet, so a guard phrased as "the seed is unavailable" is true
in two states the rule is meant to distinguish. That matters because `DRAW` is
entered up to 40 minutes before `outcomeSeedBlock` on the unchallenged path (§7.2
puts the round-1 windows in the formula unconditionally), and an implementation
testing the hash would let any party terminate a live case during that window —
collecting `DRAW_BOUNTY` for killing a case that was going to draw.

The `NO_RANDOMNESS` debits (§4.8) narrow who profits from that but do not repair
it: the plurality *winner* near a tie, and any submitter heading for rejection,
still gain, and a case that should have resolved does not. **A guard that fires in
a state its justification does not describe is a defect whatever the payoff
table says** — pricing is not a substitute for a correct condition.

Generalized as **I29**: no guard may be expressed as an observation whose value is
the same in states the guard is meant to separate. **§3.1 was the second instance
and it was live when I29 was written** — the eligibility seed had the identical
ambiguity, no guard at all, and a worse failure mode: an unguarded outcome-seed
read terminates a case, while an unguarded eligibility read *succeeds* against a
publicly precomputable eligible set. Writing the invariant in this section did not
find it in the next one, which is the argument for I33's mechanical form over
another prose generalization. Disjointness (I18) does not
catch this — the two `DRAW` guards *are* disjoint under the correct reading; the
defect was one guard being true in a state its own justification does not
describe.

Re-arming lets a party inspect whether a seed is favourable, use it when it is, and
let it expire when it is not — a free option over outcomes. Expiry is rare because
the case is **drawable for the whole horizon**: `DRAW` opens at
`outcomeSeedBlock − SEED_LAG` and the hard deadline is
`outcomeSeedBlock + BLOCKHASH_HORIZON`, both heights on the same counter, so the
256 blocks are 256 blocks in which somebody could have called and did not (§4.4).

**That sentence was false until the schedule moved to block heights.** Under the
wall-clock schedule the horizon could burn while the case was still in a voting
phase, so `NO_RANDOMNESS` was reachable with *nobody able* to poke — and the
argument below, which prices inaction, has nothing to say to a party that had no
action available. §7.2 has the measurement. Every claim in this section is
conditioned on the case having been drawable throughout, and that is now true by
construction rather than by assumption.

**`DRAW_BOUNTY` pays for the poke that reads it** — not `CLAIM_BOUNTY`, which is
paid at finalization, a different transition with no expiry. An earlier revision
named the wrong payment here, leaving the one transition with a hard deadline
unfunded.

**This closes the option of a better seed. The option of *no* seed is closed by
§4.8's debits, and the argument does not mention the bounty.**

There is a fifty-one-minute interval in which the seed is public, so every party
can compute the verdict, and recording it is still optional. That interval is
irreducible under `blockhash`: it becomes readable the instant it exists and
expires 256 blocks later, and any scheme built on it has a window in which the
outcome is known and the accounting is not yet done. The question is therefore not
how to remove the window but what a party gains inside it — and §4.8 makes the
answer *nothing*, for every revealer, at every tally.

> **Claim.** At every reachable non-empty tally, at least one party strictly prefers
> poking the draw to letting the seed expire, and that preference depends on no
> parameter of this specification.
>
> *Proof — the submitter, at every tally.* The draw lists their content with
> probability `f(â) > 0`, and `â ∈ (0,1)` for every finite `N` (§4.5), so the
> probability is strictly positive at **every** tally including a unanimous Reject.
> Expiry lists it with probability zero and holds the claim key on `REJECTED`'s
> terms (§8.4). The submitter is not a moderator: `d`, `share` and `DRAW_BOUNTY` do
> not appear in their comparison at all. ∎
>
> *Second and independent, at every non-unanimous tally — the revealers.* Take any
> revealer on the losing side of the settled side; one exists unless the tally is
> unanimous. Let `a` be their own side's share, so `0 < a ≤ 0.5`. §4.8 debits them
> `d` if the seed expires, and the draw debits them `d` only in the branch where
> their side loses it:
>
> ```
> expire         :  −d
> draw           :  f(â)·share  −  (1 − f(â))·d
> draw − expire  :  f(â)·(share + d)   >  0        for every â > 0
> ```
>
> The `d` terms cancel — charged in one branch, risked in the other — and what
> remains is a chance of being paid that only the draw supplies. ∎

**The revealers do not carry the unanimous tally, and the previous revision claimed
they did.** Its proof ended *"if the tally is unanimous, every revealer is on the
winning side, faces no debit in either branch, and the draw pays `share > 0`."*
That was true under `A/N`, where `f(1) = 1` and a unanimous side never loses. Under
`â` a unanimous cohort is overruled with probability `1 − f(â) > 0`, and in that
branch every one of them is incoherent with the settled side and debited. There is
also no losing side on expiry, so nobody is debited there and the `d` term has
nothing to cancel against:

```
expire  :   0                          (no dissent exists, so no one is debited)
draw    :   f(â)·share − (1−f(â))·d
draw > expire   ⟺   d / share  <  f(â) / (1 − f(â))

N (unanimous)      1       3       8      16      34
breakeven       2.86    8.62   34.71  111.15  439.15
```

At the working `d = 1.4 × E[share]` that holds at every `N`. **But it holds because
of a parameter value**, `d` is open (§10), and `simulation/v3/FINDINGS-v3.md` §E
sweeps it to 10.0 — past the `N = 1` breakeven. That is why the submitter's branch
is stated first and not as a footnote: it is the one that makes the Claim
parameter-free, and it is a consequence of H5's reservation and H6's estimator that
was never fed back into this proof.

**This is the coupling running the direction I did not check.** H6 → H5 I found:
§8.4's "every draw has an approval branch" was a tie under `A/N` and is strict
under `â`. H6 → this runs the other way — the estimator made the unanimous branch
*non-degenerate*, and non-degenerate means `d` entered a comparison the Claim said
`d` does not enter. This section congratulates itself two paragraphs down that "no
invariant rests on `DRAW_BOUNTY`'s size"; it had quietly begun resting on
`d / share` instead. One parameter dependence traded for a quieter one is not
progress, and the fix is not to bound `d` but to notice that a party outside the
moderator economy already carries the case.

**The assumption the submitter's branch does make**, stated rather than buried: that
a submitter wants their content listed. They paid a fee for it, and §8.4's H5
argument already rests on the same thing. A submitter indifferent to the outcome
would not have submitted.

Two things are worth reading off it.

**`share + d` is §5.2's term.** The withholding band is `p < g/(share + d)`. A
party deciding whether to withhold a reveal and a party deciding whether to let a
seed expire are being asked the same question — what a chance at the pot is worth
against a certain debit — and the design should answer it with one expression
rather than two mechanisms.

**The rule mobilizes the side that most wants the case dead.** Near a tied tally
the *plurality winner* prefers expiry, and the rule does not pretend otherwise. At
an exact tie §4.2 hands Reject the plurality and both sides sit at `a = 0.5`, so
Reject's draw is a coin flip worth `0.5·share − 0.5·d = −0.2 × share` at
`d = 1.4 × E[share]`, against zero for doing nothing. They are welcome to sit. The
plurality *loser* prefers the draw at every `a`, and it takes one poke. Whoever has
the most to lose from the case dying is exactly whoever pays the gas — which is the
inversion the earlier rule got wrong, because there the party with the most to lose
was the one who gained by waiting.

**The submitter is the party the Claim rests on, not a bonus.** They are guaranteed
to exist, they are certainly watching the case they paid for, and their comparison
contains no moderator parameter. The revealers are the *second* guarantee and they
cover every tally except the unanimous one. Two parties from opposite directions,
and the order matters: state the parameter-free one first, or the next revision
will trim the proof to the one that reads more cleverly.

`DRAW_BOUNTY` survives as funding for the expiry transition itself and as a
convenience for third-party bots. **No invariant rests on its size**, which is the
difference between this rule and the one it replaced.

---

## 8. Index effects

### 8.1 Finality is independent of payout

**At the transition that establishes a terminal** — not when moderators are paid —
the index is written in bounded `O(MAX_TOPICS)` work, and `share` is fixed.

**There are four such transitions, not one.** This section said "at `FINALIZED`",
and §4.8 then had the index entry for an `UNRESOLVED` case written during
settlement — which is the exact coupling the next paragraph names as v2's mistake,
reintroduced in the three rows the paragraph did not mention:

```
DRAW           -> FINALIZED    (APPROVED | REJECTED)   -- was covered
COMMIT  (r=0)  -> UNRESOLVED   (NO_TURNOUT)            -- was not
REVEAL  (r=0)  -> UNRESOLVED   (NO_REVEALS)            -- was not
DRAW           -> UNRESOLVED   (NO_RANDOMNESS)         -- was not
```

**And the uncovered rows are the common case, not the tail.** At FINDINGS §D's
launch registry of 250 the expected cohort is 10 against `MIN_COMMITS` 16, so
**92% of cases terminate on the first of those rows.** The rule covered the path a
healthy market takes and left the path the launch market takes.

§5.5 makes it worse than it was when the audit found it: settlement is now pulled
per moderator and may *never* complete, so an index write bundled into it is behind
an unbounded number of independent calls that no one is obliged to make. §8.2
argues at length that a reader must distinguish "judged, undrawn" from "never
submitted" — and until the entry exists, they cannot.

Moderator accounting (`claim(c, m)`, reputation, debits) happens afterwards, per
participant, whenever each chooses. **A reader must never wait for moderator
payouts to see a result.** v2
wrote the index at the end of settlement and so coupled the two. v3 goes further
than decoupling them: §5.5 removed the case-level settled state entirely, so there
is no later moment for a reader to be waiting on.

### 8.2 Interim status is a value, not an absence

**Decision.** `IndexRegistry` carries status as a distinct value:

```
NONE = 0 | PLURALITY_APPROVE | PLURALITY_REJECT | APPROVED | REJECTED | UNRESOLVED
```

The alternative — withhold the entry until `FINALIZED` — was rejected because it
throws away the one-hour answer that the whole architecture is built to produce,
and because a reader cannot distinguish "not yet decided" from "never submitted".

**`NONE = 0` is the whole of that argument and an earlier revision left it out.**
The enum began at `PLURALITY_APPROVE`, so an unwritten slot and a case whose
plurality leans Approve **read identically** — in the section whose entire stated
purpose is that those two are distinguishable. A safe-search client would have been
right to treat every never-submitted item as carrying a live interim status. The
zero slot is not a sixth status; it is what makes the other five mean anything.

### 8.2b Every index identifier is derived from content

**Decision.** An entry is addressed by

```
entryKey  = H(claimKey, topicKey)
topicKey  = H(canonical topic string)          -- never 0; see below
```

**A claim key cannot address an entry, and nothing else was specified.** §8.4 keys
*claims*; §8.1 writes up to `MAX_TOPICS` entries per claim, one per topic. So the
claim key names a set of entries and cannot name a member of it — and deletion
needs to name a member: removing an entry from a topic's list is a swap-and-pop
against a position map, and a position map needs a stable key. The port assessment
had to invent one to write `deleteEntry` at all, which is the sign that it was
missing rather than implicit.

**Content-derived, not a counter, and v1 paid a CRITICAL to learn it.** P0-1a found
that a logic-local identifier breaks across a migration: a replacement contract
starts its counter fresh and collides with entries the old one wrote. §8.4 already
applies the lesson to claims — the key is content and topics, and `policyVersion`
was deliberately excluded so a reservation survives a ruleset change. **The lesson
was applied to claims and not to entries**, and entries are the thing a migration
actually has to keep addressing.

The property, so it is not half-applied again: **every identifier this index
exposes is a function of content. None is a function of insertion order, of a
counter, or of any state a particular logic contract owns.** A replacement contract
re-derives the same identifier from the same content rather than issuing a new one.

**`topicKey` is never 0, and neither is any position the map stores.** A claim
carries up to `MAX_TOPICS` topics in a fixed-width slot, so unused slots read 0; if
0 were also a legal topic, "no topic here" and "the topic whose key is 0" would be
the same read. The same holds one level down: a position map returning 0 for
"absent" cannot distinguish absent from *first in the list*. Both are I29 — a read
whose value is identical in two states it must separate — and the second is
`M2.6-F1` verbatim, which this codebase has already fixed once.

Clients choose their own risk: a cautious safe-search filter includes `APPROVED`
only; an evidence-oriented client may show the plurality with its tally. The
plurality is a vote count, not a prediction: no draw has occurred when it is
published, which is why §4.2 withdrew publishing one there.

**`UNRESOLVED` retains the plurality where one was established.** A case that ends
`NO_RANDOMNESS` was judged by a full cohort and never drawn, and the entry says
exactly that — `UNRESOLVED` beside the `PLURALITY_*` value already published at
`TALLY`. A case that ends `NO_TURNOUT` or `NO_REVEALS` carries `UNRESOLVED` alone,
because there is nothing else true about it. **Nothing is listed in any of the
three**, which is the only property a safe-search client needs; the distinction is
for the reader who wants to know why, and for the submitter, whose claim key is
held on `REJECTED`'s terms in the first case and released in the other two (§8.4).

### 8.3 Assurance comes from the tally, not from the draw

```
SUPER_SAFE  =  verdict == Approve
           AND no challenge was opened
           AND the ticket draw was 3/3 Approve
           AND revealCount ≥ SUPER_QUORUM
           AND pooledReject == 0
           AND reveals == commits          -- nobody withheld
           AND no removal or re-review case is open
```

A 3/3 draw alone means little: `P(3/3 Approve) = â³`, which is 33.5% at `a = 0.70`
and `N = 34`. The tally must participate in the classification. **The lottery
selects truth; it does not manufacture certainty.**

**The 3/3 clause was dead until §4.5 changed the estimator.** Under `A/N`,
`pooledReject == 0` forces `a = 1`, which forces all three tickets Approve — so the
conjunct above it made this one redundant, and the paragraph justifying it reasoned
about a case the conjunction had already excluded. Under `â` a unanimous tally
gives `â = (N+1)/(N+2)`, so `P(3/3) = â³` is 93.0% at `N = 40` and 84.2% at
`N = 16`. The clause is live.

**Live is not the same as meaningful, and the sentence that used to stand here said
it was.** It claimed the clause "separates a unanimous cohort that the draw
confirmed from one it merely did not overrule". There is no such distinction. Under
a unanimous tally the three tickets are iid Bernoulli(`â`), so 3/3 versus 2/1 is a
coin flip carrying **no information about the content** beyond what `â` already
says — and `â` is a function of the tally, which the conjunction above already
tests. Since `pooledReject == 0` is required anyway, the clause only ever bites
unanimous tallies, where it removes a random 7% of otherwise-qualifying content at
`N = 40` and 16% at `N = 16`.

That is worse than the redundancy it replaced. **A redundant clause is harmless; an
arbitrary one excludes real content for no reason**, and a client filtering on
`SUPER_SAFE` gets a random subsample of the cases meeting the real criteria rather
than all of them. Rarity without selectivity is noise, and §8.3's own headline —
*assurance comes from the tally, not from the draw* — is the argument against its
own conjunct. **Whether to drop it is open (§10);** it stands here because removing
a published assurance condition changes what the index promises readers, which is a
decision and not a correction.

This replaces both v2's "unopposed subset" and the original "supersafe after 96
hours of silence" (P0-10), which inherited the same defect from the other
direction — time and ticket unanimity are both evidence about the draw, not about
the content.

### 8.4 Claim keys and retry

```
claimKey = H(actionType, contentHash, metadataHash, canonicalTopics)
```

| Terminal | Reservation | Retry |
|---|---|---|
| `APPROVED` | reserved while listed | — |
| `REJECTED` | **permanently reserved** | none; only an explicit re-review case |
| `UNRESOLVED(NO_TURNOUT)` | not reserved | freely — no draw occurred and nobody could have caused it |
| `UNRESOLVED(NO_REVEALS)` | **reserved for `RETRY_COOLDOWN`** | after the cooldown, **pot carried forward, no fresh fee**. Steerable by a party holding every commit (§4.8), so not free; but the submitter did not cause it, so not levied either |
| `UNRESOLVED(NO_RANDOMNESS)` | **the reservation `REJECTED` carries — by reference, not by copy** | none; only an explicit re-review case. The pot is refunded less maintenance, because there is no retry for it to carry forward to |

**Why `NO_RANDOMNESS` does not retry, and why I26 already said so.**

I26 reads: *once a claim has been tallied, no reachable terminal releases that
claim's key.* `NO_RANDOMNESS` **is** tallied — that is the entire content of §4.8's
distinction between it and the other two reasons, and it is why the debits settle
there at all (I30). A reservation that expires after `RETRY_COOLDOWN` releases the
key. **The row contradicted the invariant written to prevent it**, and the invariant
was right. The other two rows are untouched: `NO_TURNOUT` never opened a reveal
phase and `NO_REVEALS` closed with `pooled == 0`, so neither is tallied and neither
is covered by I26.

**A retry is worth more to the submitter than any draw, on either plurality.** The
finding was that a submitter facing rejection escapes it by expiry. The reason the
rule cannot be made conditional on the plurality is that the preference does not
depend on it:

```
                    the draw                          expiry, if it retried
plurality Reject    f(a) approved, else permanent     a fresh cohort, free
plurality Approve   f(a) approved, else permanent     a fresh cohort, free
```

Every draw carries a branch that ends the claim permanently; a retry carries none.
So a submitter leading the Reject plurality prefers expiry — and one leading the
*Approve* plurality prefers it too, because `f(0.55) = 0.575` is a 42.5% chance of
permanent rejection against a certain second attempt. **Any retry at all is a
windfall.** A plurality-conditional rule would close half the hole and advertise
the other half.

**The submitter is not a bystander to the expiry.** They paid the fee, they hold
the largest single interest in the case resolving, and poking the draw is one
permissionless call inside a 51-minute window that pays a bounty. There is no
reading of `NO_RANDOMNESS` in which the submitter could not have prevented it. That
is what makes the row's severity theirs to have avoided rather than imposed —
and, with §7.3's debits on the plurality-losing revealers, it puts a **second
independent party** on the poke, one who is guaranteed to exist and to be watching.

**By reference, not by copy.** The row's content is *equality with `REJECTED`*, not
permanence. See §8.6 for what that permanence now rests on, which is not the rate it
used to be argued from. Writing this row as a reference means it moves when
that row moves, instead of becoming a second site that has to be found and changed
— which is the failure the freeze bound made when it was clamped at two call sites
while a third existed (§9).

**What it costs.** A submitter whose case died at a 90/10 Approve tally is not
listed and must bring a re-review case. That is the sharpest edge of the rule, and
it is the same edge as §4.8's near-tie debit: severe, off-equilibrium, and severe
*because* off-equilibrium. Softening it re-opens the windfall, because the windfall
is not a function of how favourable the tally was.

**`policyVersion` is deliberately *not* in the key.** A key containing the version
cannot produce a reservation that survives a version bump, so the earlier
definition made every ruleset change a scheduled amnesty an attacker could simply
wait for — while the paragraph beside it forbade exactly that. **The reservation
must be keyed on something invariant under a ruleset change**, so the key is the
content and its claimed topics, nothing else.

The version under which a case was decided is still recorded, on the *case* (§4.1)
and on the index entry (§8.2), because a reader needs to know which rules produced
a verdict. It just cannot be part of the identity of the claim. Only a re-review
case — a new claim carrying evidence — reopens a rejection.

### 8.5 Re-review — reopening a claim, not creating one

Three rules in this document rest on a re-review case and none of them defined it:
§8.4 makes it the sole recourse from `REJECTED`, H5 made it the sole recourse from
`UNRESOLVED(NO_RANDOMNESS)`, and §8.3 conditions `SUPER_SAFE` on none being open.
The severity paragraph above — *a case that died at a 90/10 Approve tally is not
listed and must bring a re-review* — was unfalsifiable while nobody could say what
that costs.

**And the missing definition had a default that voided the rule it was propping
up.** `claimKey` includes `actionType`, so if a re-review is *an action type* it
has a **different key** and the permanent reservation does not bind it at all.
Permanence would be worth one byte — the same scheduled-amnesty defect §8.4 closed
by taking `policyVersion` out of the key, walking back in through the field that
stayed in it.

```
actionType ∈ { LIST, REMOVE }        -- what is being ASKED about the content
```

**A re-review is not an action type. It reopens the `LIST` claim in place**, under
the same key, and inherits everything the claim already holds:

```
same claimKey            no new key, so the reservation is what admits it
same u                   §4.5's randomness, re-derived from stored entropy
pooled tally carries      pooledApprove / pooledReject are not reset
prior voters are DONE     already settled; not re-judged, not re-paid
fee                      as a submission — the new cohort's work is real
```

**Why the tally carries forward, and what it buys.** §4.5 already proved the
shape: with `u` fixed, **an unchanged tally yields an identical verdict**, and
adding votes moves the verdict only toward the side added. A re-review is therefore
a challenge round arriving late, and it inherits all three of §4.5's consequences:

- **There is no re-roll, ever, for the life of a claim.** A re-review that attracts
  no votes returns the identical verdict. Repetition buys nothing by itself, which
  is the property §4.5 spent the whole architecture on and which a fresh-cohort
  retry would have handed back.
- **Repetition is self-defeating.** A re-review that fails adds votes to the side
  that already won, so the next one is harder. If the content is genuinely unsafe,
  every attempt makes the tally more lopsided; if it is genuinely safe, new voters
  flip it. **The mechanism converges rather than being replayed.**
- **It reaches an unrepresentative cohort and not an unlucky draw**, and an
  earlier revision of this list claimed the opposite. Votes arriving at the
  population's rate `p` drive `â` toward `p` and no further — `â = (A+1)/(N+2)`
  with `A ≈ pN` converges on `p`, not on the truth. The case was lost because
  `median(u) > â₀`. So a reopening can flip it **iff `â₀ < median(u) < p`**: the
  first cohort under-sampled real support and more votes recover it. If
  `median(u) > p`, no number of reopenings ever flips the case, because `â` has
  nowhere left to climb.

  Measured (`simulation/v3/FINDINGS-v3.md` §H): at `prior = 0.665`, **82% of false
  rejections are outside the recourse entirely**. The list previously said the bar
  "scales with how wrong the first cohort would have to have been" and that the
  recourse is "cheapest exactly where the original was least certain". Both were
  wrong, and in the direction that flatters the rule: the recourse is narrowest
  exactly where false rejection is commonest, because both are driven by the same
  `prior`.

**The prior tally is evidence, not participation.** Voters from an earlier opening
have settled — they were paid or debited against the verdict that stood then, and a
later reopening does not revisit that. Their votes still count in the tally the
draw reads, because the draw's question is *what did the cohort conclude*, and
their conclusion is part of the record. Re-judging them would make settlement
non-final and break I8's permutation-independence across openings.

**`NO_RANDOMNESS` is the one case where a re-review draws for the first time.** No
entropy was ever realized there, so there is nothing to reuse and the reopening
gets the claim's *first* randomness. That is consistent with I5 rather than an
exception to it — exactly one randomness per claim, arriving late. And it does not
reopen the windfall H5 closed: the reopening inherits the tally that already leans
against the submitter, so their odds are `f(â)` on the same evidence, less a fee
and a delay. **Strictly worse than having poked**, which is what H5's argument
needs.

**Who may open one, and how often.** Anyone, on the same reasoning §3.5 gives for
a challenge: the deterrence is structural — no re-roll, monotone, self-defeating —
so an eligibility test would filter honest dissenters and not attackers. What is
open is the cooldown between reopenings of one claim, because cohort attention is
the scarce resource and FINDINGS §D shows a thin registry. §10 carries it.

**While a re-review is open the index does not soften.** A `REJECTED` claim under
re-review reads `REJECTED`, plus the fact that one is open — §8.3 already
conditions `SUPER_SAFE` on that and needs it to be visible. Nothing is listed on
the strength of a pending question.

### 8.6 What permanence rests on, now that the rate is measured

**The argument §8.4 inherited is dead.** design-v3 §8 justified permanent
reservation with a 0.725% false-rejection rate: rare enough that permanently
excluding that content is defensible. Three things have happened to that number.
§4.5's estimator moved it to 1.97% (2.47% exact) from arithmetic alone. FINDINGS §F
located the assumptions it needs — `prior ≈ 0.96`, `rho ≈ 0`, `q = 0`, all three at
once. And FINDINGS §H now measures what permanence actually costs, which is not the
false-rejection rate but the part of it **the recourse cannot reach** (§8.5):

```
prior     P(safe content rejected)    reachable by re-review    IRRECOVERABLE
0.665                        0.279                     18.1%            22.8%
0.750                        0.181                     24.8%            13.6%
0.850                        0.083                     38.2%             5.1%
0.950                        0.020                     66.4%             0.7%
0.990                        0.004                     94.7%             0.0%
```

**Four orders of magnitude, and `prior` is unmeasured.** That is the whole of H8.

**The obvious repair does not work, and measuring it is what settles this.** Most
false rejections at a low `prior` are cases whose *plurality was Approve* and whose
draw went the other way — the cohort said list it and the lottery overrode them.
Conditioning permanence on the plurality is therefore the natural fix: a `REJECTED`
case whose cohort approved it gets a fresh cohort and a fresh `u`. It is not
steerable (commits are blind, §4.8) and it costs a full fee. But:

```
q      prior     P(attacker wins one draw)    P(wins | that retry exists)
0.30   0.665                         54.3%                         76.9%
0.30   0.950                         27.9%                         28.6%
0.00   0.665                         27.7%                         28.4%
```

At `prior = 0.665` a hostile 30% gets `PLURALITY_APPROVE` on unsafe content 59% of
the time, so the rule hands them optional stopping — 76.9% on one extra attempt,
and reopening is unbounded. That is the surface §4.5 spent the architecture closing,
reintroduced at the claim-key layer.

**Both columns are governed by the same quantity, and that is the finding.** At
`prior = 0.95` permanence costs 0.7% and the conditional retry buys an attacker 0.7
points — **either rule is fine.** At 0.665 permanence costs 22.8% and the retry buys
them 22.6 — **neither rule is fine.** `prior` does not decide which failure
dominates. It decides whether either failure exists.

**So permanence stays, and the reason is not that the rate is acceptable.** It is
that no claim-key rule fixes this. At a low `prior` the mechanism is faithfully
reporting a population that misjudges a third of the content it sees; whether the
resulting exclusion is permanent or retryable changes who suffers, not whether the
index is wrong. Retrying converges on the same `prior` (§8.5). The alternative is
worse on the attacker side by the same margin it is better on the publisher side,
and both margins vanish together as `prior` rises.

**This closes H8 as a decision and leaves it open as a measurement.** The rule is
not the problem, and changing it would be motion rather than progress. What the
standing constraint blocks — deployment with material funds, and presenting the
index as reliable safe-search certification — is precisely the regime where the
rule's cost is real, and it stays blocked. **`measurement/prior/` is not a
nice-to-have that would improve a parameter; it is the thing that decides whether
this architecture is deployable at all.**

**Correction is a separate claim. Re-review is not.** A *removal* case asks a
different question about the same content — is a listed entry still fit to be
listed — so it runs the same engine, produces `REMOVED` or `RETAINED`, and earns
its own key through `actionType`. A *re-review* asks the **same** question again,
and everything below follows from that.

---

## 9. Invariants

| # | Invariant |
|---|---|
| **I1** | No moderator's `bond` can go negative. Structural in **two** independent ways, which is what it takes: every value the specification can remove from `bond` is a term in `liabilities()` (§2.4) and every operation that adds a claim tests `bond ≥ BOND_MIN + liabilities(m)` after the addition — *and* no debit may exceed the claim it is drawn against (I32). The first is a statement about arithmetic and holds only within one honest logic contract; the second is a statement about authorization and is the one that survives a migration |
| **I2** | Submitting a case reserves, assigns, locks or obligates nothing for any moderator |
| **I3** | A moderator casts at most one vote per **claim**, across all rounds |
| **I4** | Every counted vote was committed before any counted vote in its round was revealed |
| **I5** | **Exactly one randomness exists per claim, for the life of the claim**, and it is realized at the last transition before `FINALIZED`. Not one per *opening*: §8.5's re-review reopens a claim after `blockhash` has expired and re-derives the same three tickets from a stored word, so an unchanged tally returns an identical verdict however many times it is asked. `UNRESOLVED(NO_RANDOMNESS)` is the one claim whose single randomness arrives at a *re-review* rather than at its first draw, which is late but is still once. No randomness is realized or published while any vote can still be cast |
| **I6** | No payment, debit or reputation credit occurs before a **terminal** state. Not "before `FINALIZED`" — `UNRESOLVED` never reaches `FINALIZED`, and I25 requires the non-reveal debit there |
| **I7** | Both seeds of every round derive from schedules fixed at submission, and are independent of every transaction's timing — including the timing of `challenge()` (§3.5b) |
| **I8** | Penalties are invariant under settlement permutation |
| **I9** | The cost of one incoherent vote is independent of `openVoteCount` |
| **I10** | No phase closes before its `phaseDeadline` |
| **I11** | **No verdict is more confident than the tally it was drawn from.** `P(Approve) = f(â)` with `â = (A+1)/(N+2)` (§4.5), so at `N` reveals neither outcome exceeds `f((N+1)/(N+2))` — 0.89% short of certainty at `N = 16`, 0.17% at `N = 40`. The old form, *"under-quorum can produce `UNRESOLVED` but never `APPROVED`"*, is the `N = 0` case of this and was vacuous for every other: "quorum" has meant the **commit** gate since §4.8 moved it there, so a case could clear it and reach `APPROVED` on one revealed vote with certainty |
| **I12** | No tally admits a risk-free outcome: **both** outcomes have non-zero probability at every reachable tally, **at the moment every party's last decision is made**. Not *"every side with ≥ 1 revealed vote"* — that quantifier excludes the side with none, so it was vacuously true at exactly the unanimous tally where a party controlling every reveal bought certainty. `â ∈ (0,1)` for every finite `N` (§4.5) is what makes the corrected form true. Every revealed vote in either round is counted in the tally the verdict is evaluated against, and no randomness is public before the last vote is cast — a published `u` makes the outcome a step function of the tally and this invariant false for round 1 |
| **I13** | `withdraw` implies `liabilities(m) == 0` — *every* outstanding claim discharged, not only open votes |
| **I14** | No moderator's loss is another moderator's gain. This covers value **removed from `bond`**, value **withheld from a payment**, and any change to a divisor that raises someone else's share — the three are the same transfer written three ways |
| **I15** | The index status is written at **the transition that establishes a terminal** — all four of them (§8.1) — and no settlement changes it. Not "at `FINALIZED`", which named one of the four and left the other three writing the index during settlement; and not "as settlement batches proceed", which named a mechanism §5.5 removed. A re-review (§8.5) changes the status only by establishing a new terminal, which is the same rule and not an exception to it |
| **I16** | Every state predicate in §2.2 and §4.2 is mutually exclusive |
| **I17** | At most one challenge round exists **per opening** of a claim. A re-review is a second opening (§8.5) and carries its own single challenge round; what it may never do is produce a second *randomness*, which is I5 and is the property this one was standing in for. Stated per claim, it would have forbidden the recourse §8.4's permanence depends on |
| **I18** | The guards of §4.3 are pairwise disjoint: in every reachable state **at most one** row is enabled. Not "exactly one" — no row is enabled in `COMMIT`, `REVEAL` or `DRAW` before the relevant deadline or block, including the interval between reveal close and `outcomeSeedBlock` |
| **I19** | Every field of §4.1 is written or provably preserved by every transition. No field is implicitly carried across a round boundary |
| **I20** | Every terminal state discharges every liability it created — `openVoteCount` returns to its pre-commit value and every escrow is released — in **one permissionless call per liability, funded by the party that liability belongs to** (§5.5). Not "within a bounded number of calls": the committer count has no ceiling, so any rule whose cost is aggregate and whose funding is a fixed fraction of a fixed fee is unbounded on one side, and the word `bounded` was carrying an assumption the eligibility rule does not supply |
| **I21** | Every value the specification moves — removed from `bond`, withheld from a payment, or left over from integer division — has a named destination in this document, and that destination is never another moderator |
| **I22** | The verdict is monotone in `a` for fixed `u`: adding votes to one side can move the verdict only toward that side, never away from it |
| **I23** | `m.liabilities` is the single point of truth for claims on `bond`, and equals the sum of that moderator's open claim records (§2.1) — an identity a view can assert, not an accounting convention. Adding any debit to this specification means creating a claim for it; no test may use a narrower expression |
| **I24** | No party can change a case's terminal *class* in a direction favourable to them by anything they do **or decline to do** after the tally becomes observable. The only quorum gate is on commits, which are blind; the residual `N ≥ 1` requirement is arithmetic, and forcing it means withdrawing all of one's own votes; and the one class reachable by pure inaction, `NO_RANDOMNESS`, is priced so that **the submitter strictly prefers the draw at every tally** (§7.3, §8.4) and the plurality-losing revealers do so at every non-unanimous one. **This invariant has twice been left resting on a parameter** — first `DRAW_BOUNTY`'s size, then, after the estimator made the unanimous branch non-degenerate, `d / share`. Both times the rule was right and the *proof* had a branch nobody re-derived |
| **I25** | The non-reveal debit fires wherever **a reveal phase opened**, including terminals in which no verdict was drawn — and *not* in `NO_TURNOUT`, where it never did. It was stated as "every terminal state", which over-corrected a revision that had waived it across all of `UNRESOLVED`: the requirement is the phase, not the terminal, and quantifying over terminals debited every committer in the one row the same section calls unsteerable |
| **I26** | Once a claim has been tallied, no reachable terminal releases that claim's key. Monotone in "voting has happened" — the draw is last, so keying it to the draw would exclude every pre-draw terminal. **§8.4's `NO_RANDOMNESS` row contradicted this** by reserving for `RETRY_COOLDOWN` and then releasing: that terminal is tallied by definition. The invariant was right and the row was wrong, which is the second time in this section a correctly-stated property was contradicted by a table written without consulting it |
| **I27** | Every debit is computed with the parameter values pinned into its case at submission. No claim's cost is a function of a parameter changed after the claim was created |
| **I28** | Withholding a reveal is never favourable **to a party that wants a side to win**: it forfeits `REVEAL_BOND(c)` and strictly lowers that side's probability. It says nothing about a party playing for a *terminal class* rather than a verdict — a censor holding every commit can still reach `NO_REVEALS`, which is why §4.8 reserves the claim there rather than relying on this |
| **I29** | **No read — a guard, a sentinel, a status, a lookup — returns a value that is the same in two states the read must separate.** Disjointness (I18) is necessary and not sufficient: a guard can be uniquely enabled and still be enabled in a state its justification does not describe. Stated for *guards* first, from `blockhash` returning zero for an expired block and for a future one (§7.3) — and the next three instances were not guards: the same ambiguity unguarded in §3.1's eligibility predicate, a status enum with no `NONE` so an unwritten entry read as a live plurality (§8.2), and a topic key of 0 indistinguishable from an unused slot (§8.2b). **The noun was "guard"** |
| **I30** | **Every obligation names the condition under which it fires, and a terminal fires exactly those whose condition it meets** (§4.8's table). Magnitudes are unconstrained — an obligation may compute its size from anything the terminal holds; only the condition decides *whether*. An earlier form sorted obligations into three groups by what they read, and the partition did not fit its members: the reserve activation reads the tally for its size and the verdict for whether it happens at all, so it was filed under the tally by §9 and under the verdict by §4.3 and §4.8, and twenty units of reserve were paid out twice. **A condition is a property of the obligation; a group is a property of the partition** — and a new rule can be mis-filed into a group, where it can only fail to state a condition, which is visible |
| **I31** | **No comparison in this specification spans two units of time.** A deadline is denominated in blocks iff a block-denominated chain constant can expire inside it; wall-clock quantities are records or lifecycle delays that no block constant runs inside. The single wall-clock→block conversion happens once, at case creation, from a pinned parameter (§1 `BLOCK_TIME`, §4.3), and no rule reads it afterwards. **A conversion inside a comparison is a defect even when its constant is correct**, because correctness of the constant is a property of the chain on the day and not of the specification |
| **I32** | **Only the case that created a claim on a bond may discharge it, and only the logic that created that case may act on it.** `liabilities` is a sum of records, never a figure a caller states. A property about *authorization*, not about arithmetic: conservation can balance while attribution is wrong, which is how v1's P0-2 drained escrow inside a single contract. Discharge capability is separable from creation capability and cannot be revoked from a logic holding an open claim, or retiring a contract would strand every moderator who voted under it |
| **I33** | **Every quantity a rule or an argument reads is re-derivable, at the site that uses it, from something this document defines — and no number appears whose source is not named.** A parameter's source is §1; a case field's is §4.1 and a moderator field's §2.1; a measurement's is a named `FINDINGS` section *and* the run that produced it; a derived constant's is its formula **and the estimator it was computed under**. A number with no cited source is a defect whether or not it is currently correct, because nothing tells the next revision which numbers it has just invalidated. Unlike I18–I21, I29 and I30 this is checkable mechanically, which is why it is worth having |

I2 is inherited verbatim from v2. **I12 is not, any more** — its v2 phrasing is the
one quoted above as wrong, and it was carried across three architectures without
anyone noticing that its quantifier stops one short of the case it names. The
no-certainty rule is still the property this design is least free to relax; what
changed is that the invariant now states it.

That is worth separating from the other corrections in this section. I18–I21, I29
and I30 were *missing* — properties the document had not written down. I11 and I12
were **present, prominent, and false**, and being prominent is what kept them from
being read. An invariant nobody re-derives is a comment.

**The table is in numeric order, which it was not.** I18–I21 sat at the bottom
after I26, and I22–I30 ran I22, I23, I27, I24, I25, I30, I28, I29, I26 — each new
invariant appended beside the one it was reasoning about rather than at its number.
That is how I11 and I12 stayed unread through three architectures (H6): an
invariant you cannot find by number is one nobody re-derives.

**I18–I21 are generalizations, not additions.** Each was written because a specific
defect of this document was an instance of it: a duplicated `REVEAL` guard (I18), a
per-round counter never reset (I19), a terminal state with no discharge path that
locked stake permanently (I20), and a debit with no stated destination (I21).
Stating the class rather than the instance is the difference between a fix and a
property — the same lesson as the freeze bound, which was clamped at two call sites
while a third existed.

**I29's own history is the argument for stating a relation and not a category.**
It was written about *guards*, from one `blockhash` read, and its next three
instances were an unguarded predicate, a status enum and a sentinel topic — none of
them a guard. Broadening it to *reads* did not require a new idea; it required
deleting a noun. Every generalization in this section has had the same shape, and
the only one that resists it is I33, which quantifies over sources rather than over
any kind of thing.

**I33 is the one that would have caught the last three.** I29's second clause reads
*"no parameter's value is written outside §1"* — and it inherited the noun
**parameter**. Not one of the quantities that then went wrong is a parameter:
`reveals1` was a **field** with no declaration, §4.5's `h` table is a **measurement**
bound to a run that has since been re-run, and `f(1/32) = 0.287%` is a **derived
constant** bound to an estimator that has been replaced. I29 was written from a
defect that happened to be a parameter, and the next three instances arrived
wearing three different nouns. I33 quantifies over *sources* instead, which is the
only category that covers all four.

**I29 and I30 are the same move made twice more.** I29 came from a guard that read
`blockhash` and I30 from a terminal that skipped a debit, and neither is phrased in
terms of guards or debits: one quantifies over observations, the other over
obligations. That is deliberate. Every earlier invariant here inherited the *noun*
of the defect that produced it — a gate, a side, a bond, a row — and the next defect
arrived wearing a different noun and slipped past all of them. An invariant that
names a category of thing is a fix with a wider blast radius; an invariant that
names a *relation* between what a rule reads and where it is allowed to fire is a
property.

---

## 10. Open parameters and inherited work

**Open, blocking simulation rather than implementation:**

| Item | Note |
|---|---|
| `d`, `BOND_MIN` | `λ = d + G` is derived (§2.4); `d` itself is not. It sets the confidence threshold at which honest voting is rational |
| `REVEAL_BOND`, `G` | **Reopened.** `= d + G`, floored by §5.2's dominance argument once gas is in it. `G` moves with gas price, so this is a sweep parameter after all, and it drags `LAMBDA` with it |
| §8.3's 3/3 conjunct | Live since the estimator changed, and **arbitrary rather than meaningful**: under a unanimous tally the tickets are iid, so 3/3 versus 2/1 is a coin flip that excludes a random 7% of qualifying content at `N = 40` and 16% at `N = 16`. §8.3 argues against it in its own headline. Dropping it makes `SUPER_SAFE` a function of the tally alone, which is what that section says assurance should be — but it changes what a published assurance label promises, so it is a decision rather than a correction. **Open, and cheap to close either way** |
| The plug-in residual in `f(â)` | §4.5. `f(â)` sits above the exact posterior predictive `E[f(θ)] = (A+1)(A+2)(3N−2A+6)/((N+2)(N+3)(N+4))` at every tally but the tie — 4.1 points at `N = 1`, 0.15 at `N = 40`. Kept deliberately: three ticket comparisons are the senior reviewer's rule and the shape §4.5's argument is written in, and the exact form would be a third change to the core verdict arithmetic in one revision. **Every figure derived from `f` in either document inherits the over-claim** and is labelled with the estimator per I33. Re-openable on evidence, and the closed form is recorded in §4.5 so nobody derives it twice |
| Re-review cooldown | §8.5. Reopening a claim is structurally deterred — no re-roll, monotone in the tally, self-defeating under repetition — so the cooldown is not what stops an attacker; it is what stops a *burst* from consuming cohort attention, which FINDINGS §D shows is the scarce resource at launch registry sizes. It prices the same thing `CHALLENGE_BOND` prices and should probably be set beside it. **Open, and the one number §8.4's permanence argument now depends on** |
| `RETRY_COOLDOWN` | §8.4, and **now for `NO_REVEALS` alone.** It has lost both of its earlier jobs rather than been tuned for them: poke-refusal went to §7.3's debit, and the submitter's escape went to I26's reservation. What it still prices is the party who holds every commit on a case and withholds them all — a delay long enough that reaching `NO_REVEALS` deliberately is not worth the `REVEAL_BOND` it costs. **One knob, one attacker, for the first time in this document** |
| Permanence of `REJECTED` | **Closed as a rule decision (§8.6); open as a measurement.** Permanence stays, and not because the rate is acceptable: FINDINGS §H measures what it costs as the *irrecoverable* share of false rejections — 22.8% of safe content at `prior = 0.665`, 0.7% at 0.95. The natural repair, conditioning permanence on the plurality, hands a hostile 30% optional stopping worth 22.6 points at the same low `prior` and 0.7 at the high one. **Both sides are governed by `prior` and both vanish together**, so no claim-key rule is what decides this. What remains open is the measurement, and the standing constraint already blocks the regime where the cost is real |
| `FEE_BASE`, `FEE_PER_TOPIC` | Must clear gas for `TARGET_COHORT` voters — the binding constraint in every simulation so far |
| `SUPER_QUORUM` | §8.3 |
| `h` | Not a contract parameter at all — design-v3 O10, and **largely defused rather than open**. §4.5's single-randomness rule flattens the whole of `h` to 1.6 points of false approval (FINDINGS §B), against the 20 a fresh round-1 draw produced. The old framing here — *"halves the false-approval rate or nearly doubles it"* — described the fresh-draw regime and was left standing after the rule that ended it. What remains open is not `h` but the finding underneath: the challenge round is a small net **negative** on false approval at every `h` measured, and is kept because it is the only correction path §8.4 and §8.5 have |
| `CHALLENGE_BOND` | Sizing only, and **one job now that §4.6 made it unconditional**. It used to have to price a frivolous challenge *and* stay affordable for a single-identity dissenter — two requirements pulling opposite ways on one knob, and the conditional forfeit made the effective price differ between the two parties in the wrong direction. Unconditional, both parties face the same number, so it is a single question: what are twelve hours of the submitter's latency and one round of cohort attention worth? §2.4 covers it in `liabilities()`, so no relation to `BOND_MIN` is required and it needs none to the reserve either — §5.3 removed that coupling |
| `BLOCK_TIME`, and the bound the hybrid creates | §1. Denominating the schedule in blocks removed a *safety* dependence on block time (§7.2) and left a *scheduling* one: `BLOCK_TIME` sets how long a window is in wall-clock terms for the human moderators §10's honest-accuracy row is about. Wrong by 50% and windows are 50% off; nothing terminates that would not have. **But it carries one hard bound, which the previous revision could not even express:** the eligibility seed must survive its own commit window, `commitBlocks ≤ SEED_LAG + BLOCKHASH_HORIZON = 258` (§3.1), i.e. `BLOCK_TIME ≥ 1200 / 258` = **4.651 s** at a 20-minute window, with **18 blocks** of margin at the working 5 s. `RulesetGovernor` must validate it; a change below the bound does not fail loudly, it re-points the tail of every commit window at a zero seed. **This row previously read 4.72 s and 14 blocks**, from arithmetic that put `SEED_LAG` on the wrong side of the inequality — quoted from the port assessment rather than derived here, which is the I33 failure this document had just finished writing down |
| Eligibility seed vs commit window | **Closed as a correctness question, open as a sizing one.** §3.1 now carries the height guards I29 required, so a seed that has expired *or has not happened yet* reverts a commit instead of silently re-pointing eligibility at `roundSeed = 0`. What remains is sizing: 18 blocks of tail margin is thin, and the 3-block head gap costs 1.25% of every commit window and cannot be removed — a moderator cannot evaluate a seed that does not exist. Both shrink if `BLOCK_TIME` falls or `COMMIT_WINDOW` rises, which is why `RulesetGovernor` validates the bound rather than the spec assuming it |
| `T` and registry size | §3.3 calibrates `T` so the expected cohort is `TARGET_COHORT`, which needs the active-moderator count — the quantity §3.6 says cannot be maintained on chain. **Measured** (`simulation/v3/FINDINGS-v3.md` §D): with `T` calibrated for 1,000, a registry of 250 gives an expected cohort of 10 against `MIN_COMMITS` 16 and **92% of cases end `UNRESOLVED(NO_TURNOUT)`**. That is the launch condition. Above the calibration size composition is stable but per-voter pay falls linearly while gas does not. Too small is a liveness failure, too large an economic one; neither is a safety failure |
| **Honest accuracy** | **The binding constraint, and it is not in this document.** `simulation/v3/FINDINGS-v3.md` shows that with *zero* attackers a 66.5% honest prior approves 30% of unsafe content, because an honest error is indistinguishable from a hostile vote and enters the verdict through the same term. Every safety figure written as a function of `x` is really a function of `q + (1−q)(1−prior)`. At `prior = 0.95` the same figure is 1%. Measuring `prior` on real content dominates every other open parameter here |
| `d`, and the two upper bounds nobody had written next to each other | §5.1, §7.3. `d` has an upper bound from **viability** — honest voting is rational only while `d/share < prior/(1−prior)`, which is 1.99 at `prior = 0.665` and 19 at `prior = 0.95` — and a second from **poke dominance** at a unanimous tally, `d/share < f(â)/(1−f(â))`, which is 2.86 at `N = 1` and rises steeply with `N`. The two come from unrelated arguments in different sections and are within 45% of each other at the borderline prior. **Which one binds depends on the unmeasured quantity:** they cross at `prior = f(2/3) = 0.741`, below which viability is tighter and above which poke dominance is. Neither is load-bearing for I24 — §7.3's Claim is carried by the submitter, who has no `d` — but a sweep of `d` should see both, and FINDINGS §E currently sweeps to 10.0 without either |
| Logic lifecycle, and what condemnation forgives | §2.4, I32. The capability half is settled and **measured free**: `MAY_CREATE` / `MAY_DISCHARGE` as a bitmap plus an `openClaims` counter came in **486 bytes cheaper** than the `LogicState` / `authEpoch` / `logicLiabilities` machinery it replaces. Condemnation replaced the force-discharge and is 413 bytes smaller again. What stays open is not the mechanism but its **price**: condemnation pardons every pending debit under the condemned logic, because the registry holds a claim's amount and not its outcome. That is defensible — the alternative debits moderators who were about to be paid — and it sets a payoff for wedging a logic deliberately. Open: whether the timelock is `RulesetGovernor`'s existing one, and whether a pardon should cost the condemned logic's *submitters* anything |
| Cohort size and the dilution of `share` | **The settlement-cost half of this is closed** — §5.5 pulls settlement per moderator, so there is no aggregate a fixed bounty must cover and I32's per-claim record is paid for by the claimant it belongs to. What survives is payment adequacy. `d(c)` is pinned at submission (I27) while `share = P/W` falls with realized turnout, so a party who inflates the cohort worsens **everyone's** `d/share` ex post — and commits are blind, so nobody who committed can respond. FINDINGS §D measures the organic version (a registry of 10,000 against a `T` calibrated for 1,000 gives an expected cohort of 400 and a fortieth of the per-voter pay); the adversarial version costs the attacker `LAMBDA` in locked capital per identity and puts their own identities on the same bad ratio. **Open, and it is a `FEE_BASE` question, not an I20 one** |
| Claim-key squatting | `submit` reserves a claim key (§4.3) with no check on who may claim it, so any content hash can be held for the price of a fee, repeatedly. The mirror of design-v3 O1: the key is simultaneously too tight against substitutes and too loose about who may take it |

**Inherited code (§Scope):**

- `StakeRegistry` — survives; loses the sortition tree and gains `bond` and
  `openVoteCount`.
- `IndexRegistry` — survives; gains the plurality statuses of §8.2.
- `RulesetGovernor` — **"survives unchanged" is false, and measurably so.** M2.6
  stubbed `_validateParams` at 1,371 B of 4,565, and that undercounts: of v3's
  parameter set exactly two — `revealWindow` and `seedLag` — appear in v1's `Params`
  at all, while `PendingParams` stores a v1-shaped struct and `applyRuleset` carries
  a v1 signature. What survives is the *pattern*: propose/execute/cancel, the
  timelock, two-step governance, and `bindModeration`'s reciprocity check
  (M2.6-F3). The content is a rewrite, and it now has more to validate — §10's
  `BLOCK_TIME` bound (I31) and I32's discharge-capability rule. §8.4's rule that a
  version bump does not reopen rejections carries over unchanged.
- `SortitionTree` — **deleted.** Passive eligibility walks no tree.
- `FreezeMath` — **deleted.** There are no freezes.
- `Moderation`, `Settlement` — rewritten. Panels, duty pools and duty settlement
  have no counterpart here. **Obligation handles do**, and this line used to say
  otherwise: what v1 hung from an assigned duty, §2.4 hangs from a voluntary
  commit, and the record is the same record because its job was never the panel —
  it was knowing which case may release which claim (I32).
- `StakeRegistry` — and the surviving list above understates this. M2.6's port
  assessment measured 18 of its 30 external functions deleted and 10 new, taking it
  from 12,761 B to 6,774 B. **It is a rewrite around a surviving skeleton, not an
  edit**, and the whole eligibility-epoch subsystem (P0-3, P0-3c, P0-3d) exists
  solely to stop a *sortition tree* mutating mid-draw — with no tree it is not
  simplifiable but meaningless, and leaving it in leaves live code whose
  justification has evaporated.

**The standing constraint is unchanged.** No deployment with material funds, and
the index is not presented as reliable safe-search certification, until the P0 set
closes and an independent re-audit passes against a named commit. The four-contract
audit does not carry over to this architecture.
