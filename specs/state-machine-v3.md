# Moderation Contract v3 — Formal State-Machine Specification

**Milestone:** M3.0
**Status:** Specification, revision **v3.0**. Not implemented.
**Design:** `specs/design-v3.md` — mechanism, arithmetic, and the costs this
document takes as decided. Where the two disagree, the design document is wrong and
should be corrected; this file is normative.
**Supersedes:** `specs/state-machine-v2.md` entirely. That document specifies
challenge eligibility seeds, risk units, `MAX_ROUNDS` 2 and pooled tallies under a
linear lottery, none of which survive. It is kept as the record of the architecture
the external review was run against.
**Scope:** the on-chain moderation contract. `StakeRegistry`, `IndexRegistry` and
`RulesetGovernor` survive from the first architecture with the edits noted in §10;
`SortitionTree` and `FreezeMath` do not survive at all.

Parameters marked *(working)* are simulation inputs, not final values.

> **Decisions taken here, not in the design document.** Six rules follow from the
> design but are not stated by it. Each is consequential enough to be visible, and
> each carries its reasoning inline.
>
> - §3.5 — **a challenge is a bond, not a vote.** This removes the forced
>   disclosure that v2 §4.7 accepted as unavoidable.
> - §4.6 — a challenge round that misses `MIN_CHALLENGE_REVEALS` forfeits the
>   challenger's bond and lets the provisional stand.
> - §4.8 — one terminal `UNRESOLVED` with a reason, rather than separate
>   `NO_QUORUM` and `VOID` states.
> - §5.1 — **penalties are balance debits, never time.** No moderator is ever
>   suspended; there is no `SUSPENDED` state anywhere in this document.
> - §5.4 — a debit that would exceed the posted bond is impossible by
>   construction, not clamped after the fact.
> - §8.2 — the index carries provisional status as a distinct value rather than
>   withholding the entry until final.

---

## 0. Conventions

- **xBZZ** amounts are integers in base units. No floating point anywhere.
- **Time** is block timestamps (seconds).
- **Randomness** is `blockhash(snapshotBlock)`, domain-separated per case, round
  and purpose (§7). Never re-armed after expiry (§7.3).
- `H(...)` is `keccak256(abi.encode(...))` unless stated otherwise.
- **Rounds** are numbered from 0. Round 0 is the initial vote; round 1 is the
  single challenge round. There is no round 2.
- **Provisional** means: drawn, published, and binding on nothing.

---

## 1. Parameters

| Name | Working value | Meaning |
|---|---|---|
| `MIN_STAKE` | 10 xBZZ | Floor to hold an identity. Flat; more buys no voting power. |
| `BOND_MIN` | *(open — §10)* | Solvency floor. A moderator with less may not commit. |
| `PENALTY_DEBIT` `d` | `1.4 × E[P/N]` | Debited from bond for a vote incoherent with the final verdict (design-v3 §6). |
| `LAMBDA` `λ` | **`= d`** | Bond required per open vote. Derived, not chosen — §2.4. |
| `REVEAL_BOND` | *(open — §10)* | Refundable per-commit; forfeit on non-reveal (§5.2). |
| `CHALLENGE_BOND` | *(open — §10)* | Posted to open round 1. Forfeit per §4.6. |
| `MATURATION` | *(open)* | Delay before newly staked value may vote. Set from the attack-preparation horizon, **not** from any penalty term. |
| `EXIT_COOLDOWN` | 7 d | Delay between exit request and withdrawal. |
| `TARGET_COHORT` | 40 | Expected eligible moderators per round. |
| `MIN_REVEALS` | 16 | Pooled reveals required before any verdict may be drawn. |
| `MIN_CHALLENGE_REVEALS` | `max(12, reveals₀ / 2)` | Fresh reveals round 1 must add (design-v3 §2.1). |
| `SUPER_QUORUM` | *(open)* | Reveals required for the strict assurance class (§8.3). |
| `COMMIT_WINDOW` | 20 min | Per round. |
| `REVEAL_WINDOW` | 20 min | Per round. |
| `FINALIZATION_GRACE` | 10 min | Between outcome block and hard deadline. |
| `CHALLENGE_WINDOW` | 12 h | From provisional publication. |
| `SEED_LAG` | 2 blocks | Between arming and realizing a seed. |
| `LATE_WIDEN_AT` | minute 12 of commit | Eligibility widening trigger (§3.3). |
| `LATE_WIDEN_FACTOR` | 1.5× | Threshold multiplier at widening. |
| `CLAIM_BOUNTY` | 1 % of fee | Paid to whoever triggers finalization. |
| `MAX_TOPICS` | 5 | Topics per submission. |
| `FEE_BASE`, `FEE_PER_TOPIC` | *(open — §10)* | Must pay `TARGET_COHORT` voters above gas. |

**The submission payment has four components** (design-v3 §2.1):

```
fee = initialPot + challengeReserve + finalizationBounty + maintenance
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
    uint40  maturesAt;
    uint40  exitRequestedAt;
    uint32  trackEpoch;
    uint128 track;           // reputation, WAD-scaled (§6)
}
```

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
| `ACTIVE` | `EXITING` | `requestExit()` | `exitRequestedAt = now` |
| `EXITING` | `NONE` | `withdraw()` | see below |

```
withdraw allowed iff  now ≥ exitRequestedAt + EXIT_COOLDOWN
                 and  openVoteCount == 0
```

**The liability count is exact where a duration guess is not** (P0-5). A cooldown
alone let a voter commit, request exit, and withdraw before the case that would
debit them ever settled. `openVoteCount == 0` cannot be raced.

Withdrawal returns `stake + bond`, less nothing. `track` is retained (§6) — that is
what makes identity replacement expensive rather than the stake.

### 2.4 The solvency predicate, and why `λ = d`

```
mayCommit(m)  iff  m is ACTIVE
                and  m.bond ≥ BOND_MIN + LAMBDA · m.openVoteCount
```

**This is a price, not a reservation.** No case reserves anything from any
moderator; committing debits nothing; a moderator with more bond may vote in more
cases with no ceiling; and bond grows from rewards, so capacity is *earned* rather
than bought (design-v3 §6).

`LAMBDA` is derived, not chosen. Require the property:

> **No moderator can ever owe more than they have posted.**

Every open vote may lose simultaneously, so the bond must cover
`d · openVoteCount` on top of the floor. Hence `LAMBDA = d`. Any smaller value
admits insolvency; any larger value rations capacity for no safety gain.

---

## 3. Eligibility

### 3.1 The predicate

```
eligible(m, c, r)  iff  H(ELIGIBILITY_DOMAIN, chainId, contract,
                          caseId, roundSeed(c, r), m) < threshold(c, r, now)
```

Evaluated **off-chain** by each moderator and verified on-chain only when they
commit. The contract never enumerates the eligible set — see §3.6.

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

### 3.5 A challenge is a bond, not a vote

**Decision.** Opening round 1 requires posting `CHALLENGE_BOND` and being eligible
for round 1. It does **not** cast a vote and does not disclose a direction.

v2 §4.7 made the challenge itself a public vote against the standing verdict, and
accepted the resulting disclosure as unavoidable: concealing the challenger's
direction and restricting challenges to disagreement are mutually exclusive.

Under v3 the constraint dissolves, because a challenge no longer needs to *be* the
objection. Round 1 is a full commit–reveal round; the challenger commits inside it
like everyone else, hidden. What the bond buys is the round, not a position in it.

Two consequences worth stating:

- The challenger's direction is secret, so round-1 voters cannot herd behind it.
- A challenger who opens the round and then reveals *in agreement* with the
  provisional has wasted a bond and gained nothing. No rule is needed to prevent
  it.

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
    uint8   unresolvedReason;  // NO_QUORUM | NO_RANDOMNESS
    uint128 pot;               // initial pot; grows by the reserve on challenge
    uint128 challengeReserve;  // escrowed; refunded or activated
    uint40  phaseDeadline;
    uint40  eligSeedBlock;     // armed at round open
    uint40  outcomeSeedBlock;  // armed at round open, from the SCHEDULED deadline
    uint32  pooledApprove;     // POOLED across rounds, never reset
    uint32  pooledReject;
    uint32  revealsThisRound;
    uint32  reveals0;          // round-0 reveal count, for MIN_CHALLENGE_REVEALS
    Outcome provisional;       // written once, at DRAW_0; binds nothing
    Outcome verdict;           // written once, at the binding draw
    address challenger;
    uint40  finalizedAt;
    // content, metadata, topics, ruleset/guidelines versions: as v2
}
```

Votes **pool**: `pooledApprove` / `pooledReject` accumulate across both rounds and
are never reset. The binding draw is taken against the pooled tally.

### 4.2 Phases

```
                                  ┌──────────── challenge (§3.5) ────────────┐
                                  │                                          │
COMMIT ──▶ REVEAL ──▶ DRAW ──▶ PROVISIONAL ──▶ COMMIT₁ ──▶ REVEAL₁ ──▶ DRAW_F ─┤
                       │            │                                          │
                       │            └── window closes, no challenge ───────────┤
                       │                                                       ▼
                       └── reveals < MIN_REVEALS ──▶ UNRESOLVED          FINALIZED
                                                                               │
                                                                               ▼
                                                                            SETTLED
```

**Two draws exist and only one binds.** `DRAW` produces `provisional`. If a
challenge opens, `provisional` is discarded and `DRAW_F` produces `verdict` from
the pooled tally. If no challenge opens, `provisional` is *copied* into `verdict`
at `FINALIZED` — it is not redrawn.

**Nothing is paid and nobody is debited before `FINALIZED`.** The pot stays
escrowed through the challenge window. A provisional verdict credits no coherence,
applies no penalty, and moves no value.

### 4.3 Transition table

| From | To | Trigger | Effect |
|---|---|---|---|
| — | `COMMIT` | `submit(...)` | charge fee; split into pot / reserve / bounty / maintenance; reserve dedup keys (§8.4); pin ruleset and guidelines versions; `round = 0`; arm both seeds (§7); `phaseDeadline = now + COMMIT_WINDOW`. **No moderator is selected, reserved, or notified on chain.** |
| `COMMIT` | `REVEAL` | `now ≥ phaseDeadline` | `phaseDeadline = now + REVEAL_WINDOW` |
| `REVEAL` | `DRAW` | `now ≥ phaseDeadline` | pool this round's reveals. If `pooled < MIN_REVEALS` → `UNRESOLVED(NO_QUORUM)` |
| `DRAW` | `PROVISIONAL` | outcome seed available | draw `provisional` (§4.5); publish (§8.2); `reveals0 = revealsThisRound`; `phaseDeadline = now + CHALLENGE_WINDOW` |
| `PROVISIONAL` | `COMMIT` | `challenge()` (§3.5) and `now < phaseDeadline` | `round = 1`; `challenger = msg.sender`; escrow `CHALLENGE_BOND`; activate `challengeReserve` into `pot`; arm **both** round-1 seeds; `phaseDeadline = now + COMMIT_WINDOW` |
| `PROVISIONAL` | `FINALIZED` | `now ≥ phaseDeadline`, no challenge | `verdict = provisional`; `finalizedAt = now` |
| `REVEAL` (r=1) | `DRAW_F` | `now ≥ phaseDeadline` and `revealsThisRound ≥ MIN_CHALLENGE_REVEALS` | pool round-1 reveals |
| `REVEAL` (r=1) | `FINALIZED` | `now ≥ phaseDeadline` and `revealsThisRound < MIN_CHALLENGE_REVEALS` | §4.6 — `verdict = provisional`; challenger's bond forfeit; round-1 reveals still pool and are still judged against `verdict` |
| `DRAW_F` | `FINALIZED` | outcome seed available | draw `verdict` from the **pooled** tally; `finalizedAt = now` |
| any `DRAW` | `UNRESOLVED` | outcome seed expired (§7.3) | `unresolvedReason = NO_RANDOMNESS` |
| `FINALIZED` | `SETTLED` | `claim()` batches complete | §5, §8 |

Every transition is permissionless. `CLAIM_BOUNTY` pays for the last poke.

**No phase closes early.** Not when every committer has revealed, not when the
challenge window is quiet, not when a cohort appears complete. §4.4 and §7.2 give
the two independent reasons.

### 4.4 Deadlines are fixed and closure is never conditional

Each phase ends at `phaseDeadline`, a timestamp fixed when the phase opened.

**Early closure on "everyone revealed" hands the last actor the entropy.** The
reveal set is on-chain, so whoever holds the last reveal would choose between
closing now and letting the deadline close it — a free binary choice over outcome
seeds. At a hostile 30% of reveals that raises their odds from `f(0.3) = 21.6%` to
`1 − (1−0.216)² = 38.5%` (design-v3 §7). No stake, no identities, no extra votes.

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

### 4.5 The draw

```
N = pooledApprove + pooledReject
for i in 0..2:  ticket[i] = H(OUTCOME_DOMAIN, chainId, contract, caseId, round,
                              blockhash(outcomeSeedBlock), i) mod N < pooledApprove
result = (ticket[0] + ticket[1] + ticket[2] ≥ 2) ? Approve : Reject
```

Three independent draws **with replacement**, majority of three. `P(Approve) =
3a² − 2a³` where `a = pooledApprove / N`.

With replacement is required, not incidental: without it a side holding one revealed
vote could never occupy two tickets, and a 31–1 tally would decide with certainty
— which contradicts I12. With replacement that side retains 0.287%.

`N ≥ MIN_REVEALS ≥ 16` at every draw, so `N` is never 0. The implementation must
still guard it explicitly: a revert inside the draw leaves a case permanently
unfinalizable.

### 4.6 A challenge round that fails its threshold

**Decision.** If round 1 closes with `revealsThisRound < MIN_CHALLENGE_REVEALS`:

- `verdict = provisional` — the provisional stands, unredrawn;
- the challenger's `CHALLENGE_BOND` is **forfeit** to the maintenance reserve;
- round-1 reveals still pool and are still judged coherent or incoherent against
  `verdict`, so voters who turned up are paid or debited normally;
- the activated `challengeReserve` stays in the pot and is distributed.

The bond is forfeit rather than refunded because the challenger can observe round-0
turnout before deciding, so a round nobody attends is a bet they chose to place.
Refunding it would make challenging free, and a free challenge imposes a 12-hour
delay on any case at the price of gas.

The reserve is *not* returned to the submitter, because the round-1 voters who did
turn up performed real work and are paid from the same pot as everyone else.

### 4.7 What may be published between rounds

Between `DRAW` and `FINALIZED` the contract may expose the pooled tally, the reveal
count, the round, and `provisional`. It may **not** expose anything that lets a
round-1 voter learn a round-1 vote before round-1 reveals open — that is what
`REVEAL_WINDOW` and the commit hash exist for.

`provisional` is published deliberately, and O11 in design-v3 records the cost: a
`PROVISIONAL_REJECTED` is visible for twelve hours and has effect even when the
challenge overturns it.

### 4.8 `UNRESOLVED`

**Decision.** One terminal state with a reason code, rather than separate
`NO_QUORUM` and `VOID` states as in v2.

| Reason | Condition |
|---|---|
| `NO_QUORUM` | fewer than `MIN_REVEALS` pooled at a reveal close, after widening |
| `NO_RANDOMNESS` | the fixed outcome seed expired unread (§7.3) |

In both cases: no verdict, no index entry, no incoherence debit for anyone, reveal
bonds returned, `pot + challengeReserve` refunded to the submitter, `bounty` and
`maintenance` retained. Revealers are paid nothing — there is no verdict to be
coherent with — but they lose nothing either.

They differ only in what they say about the failure, and that difference is worth
storing: `NO_QUORUM` is a turnout problem and `NO_RANDOMNESS` is a keeper problem.
`NO_QUORUM` is freely retryable (design-v3 §8) precisely because no draw occurred.

**`UNRESOLVED` must never be reachable from an under-quorum pool by approving it.**
A bounded failure is correct; an unsafe success is not.

---

## 5. Settlement

### 5.1 Penalties are balance debits, never time

At `SETTLED`, for every revealed vote in either round:

```
coherent with verdict    -> bond += share            (§5.3)
incoherent with verdict  -> bond -= d
committed, never revealed -> bond -= REVEAL_BOND      (§5.2)
```

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

`REVEAL_BOND` is posted at commit and returned on a valid reveal. A committer who
never reveals forfeits it **to the maintenance reserve**.

It must not go to the opposing voters. Transferring a penalty to the other side
creates punishment farming — an incentive to provoke non-reveals rather than to
judge content — which design-v2 §5.5 forbids and which no version of this design
has ever permitted.

This is a *price* on the free option that commit–reveal creates, not a
reservation: it debits nothing at commit, caps nothing, and does not appear in
`openVoteCount`'s solvency test beyond the vote itself.

### 5.3 Payment

```
P = pot + activatedChallengeReserve
W = votes matching `verdict`, from either round
share = floor(P / W)
remainder = P − share · W   -> maintenance reserve, never to moderators
```

Four things are irrelevant to both payment and penalty: which round a moderator
voted in, whether their own ballot was sampled as a ticket, whether their side won
`provisional`, and whether the challenge reversed the result.

**Expected cash is not direction-neutral, deliberately** (design-v3 §5). A majority
voter expects `(P/N)·f(a)/a`, a minority voter `(P/N)·(1−f(a))/(1−a)`. `design-v2`
§4.2's neutrality theorem is no longer a requirement of this design; it remains
correct as the statement of what was given up.

### 5.4 A debit can never exceed the bond

By §2.4, `bond ≥ BOND_MIN + d · openVoteCount` held at every commit, so the total
debit from simultaneous losses is covered by construction.

**The implementation must not clamp.** A `bond -= d` that would underflow indicates
a broken invariant, not a case to handle gracefully, and clamping would hide it.
Revert, and treat it as I1 having failed.

A moderator whose bond falls below `BOND_MIN + λ · openVoteCount` after debits is
not penalised further and is not suspended. They simply cannot commit to anything
new until they post more bond or their open votes settle. This is the whole of what
"insolvency" means here.

### 5.5 Settlement may be batched, and order does not matter

`claim()` may settle a case in batches across transactions. Because debits commute
(§5.1) and `verdict` is fixed at `FINALIZED`, no partial settlement can produce a
different result from any other interleaving.

A finalized losing vote still counts against `openVoteCount` until its case is
fully settled, so it cannot be reused before its debit lands.

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

| Seed | Armed | Used for |
|---|---|---|
| `eligSeedBlock` | round open + `SEED_LAG` | §3.1 eligibility |
| `outcomeSeedBlock` | round open, computed from the **scheduled** phase deadline | §4.5 the draw |

Both are fixed when the round opens. Neither depends on when any transaction lands.

### 7.2 The outcome block is fixed from the schedule, never from the transaction

```
outcomeSeedBlock = blockAt(scheduledRevealClose) + SEED_LAG
```

It must **not** depend on when the final reveal arrives, whether the case was
challenged, who called the transition, whether everyone revealed early, or whether
round 1 opened. This is what makes §4.4's "no early closure" rule enforceable
rather than advisory, and it closes both M2.5-F10 and the selective-realization
surface (P1-2).

### 7.3 No lazy re-arming

If `blockhash(outcomeSeedBlock)` is unavailable when the draw is attempted, the
case terminates `UNRESOLVED(NO_RANDOMNESS)`. **A fresh future block is never
selected.**

Re-arming lets a party inspect whether a seed is favourable, use it when it is, and
let it expire when it is not — a free option over outcomes. The one-hour round
lifecycle makes expiry rare: `blockhash` is available for 256 blocks (~51 minutes)
and the outcome block sits 10–15 minutes before the deadline. `CLAIM_BOUNTY` pays
for the poke that reads it.

---

## 8. Index effects

### 8.1 Finality is independent of payout

At `FINALIZED` — **not** at `SETTLED` — the index is written in bounded
`O(MAX_TOPICS)` work, and `share` is fixed.

Moderator accounting (`claim()`, reputation, debits) happens afterwards and may be
batched. **A reader must never wait for moderator payouts to see a result.** v2
wrote the index at `SETTLED` and so coupled the two.

### 8.2 Provisional status is a value, not an absence

**Decision.** `IndexRegistry` carries status as a distinct value:

```
PROVISIONAL_APPROVED | PROVISIONAL_REJECTED | APPROVED | REJECTED | UNRESOLVED
```

The alternative — withhold the entry until `FINALIZED` — was rejected because it
throws away the one-hour answer that the whole architecture is built to produce,
and because a reader cannot distinguish "not yet decided" from "never submitted".

Clients choose their own risk: a cautious safe-search filter includes `APPROVED`
only; an evidence-oriented client may show provisional status with its tally.

### 8.3 Assurance comes from the tally, not from the draw

```
SUPER_SAFE  =  verdict == Approve
           AND no challenge was opened
           AND the ticket draw was 3/3 Approve
           AND revealCount ≥ SUPER_QUORUM
           AND pooledReject == 0
           AND no removal or re-review case is open
```

A 3/3 draw alone means little: `P(3/3 Approve) = a³`, which is 34.3% at `a = 0.70`.
The tally must participate in the classification. **The lottery selects truth; it
does not manufacture certainty.**

This replaces both v2's "unopposed subset" and the original "supersafe after 96
hours of silence" (P0-10), which inherited the same defect from the other
direction — time and ticket unanimity are both evidence about the draw, not about
the content.

### 8.4 Claim keys and retry

```
claimKey = H(actionType, contentHash, metadataHash, canonicalTopics, policyVersion)
```

| Terminal | Reservation | Retry |
|---|---|---|
| `APPROVED` | reserved while listed | — |
| `REJECTED` | **permanently reserved** | none; only an explicit re-review case |
| `UNRESOLVED` | not reserved | freely — no draw occurred |

**A policy-version bump must not reopen rejections.** Scoping the reservation to
`policyVersion` alone makes every ruleset change a scheduled amnesty an attacker
can wait for. The reservation persists across versions; only a re-review case,
which is a new claim carrying evidence, reopens one.

**Correction is a separate claim.** A removal case runs the same engine — commit,
reveal, three tickets — producing `REMOVED` or `RETAINED`. It is not an appeal of
the original draw.

---

## 9. Invariants

| # | Invariant |
|---|---|
| **I1** | No moderator's `bond` can go negative. `λ = d` makes this structural (§2.4, §5.4) |
| **I2** | Submitting a case reserves, assigns, locks or obligates nothing for any moderator |
| **I3** | A moderator casts at most one vote per **claim**, across all rounds |
| **I4** | Every counted vote was committed before any counted vote in its round was revealed |
| **I5** | Exactly one **binding** verdict exists per claim. `provisional` is written once and binds nothing |
| **I6** | No payment, debit or reputation credit occurs before `FINALIZED` |
| **I7** | Both seeds of a round are fixed at round open and are independent of every transaction's timing |
| **I8** | Penalties are invariant under settlement permutation |
| **I9** | The cost of one incoherent vote is independent of `openVoteCount` |
| **I10** | No phase closes before its `phaseDeadline` |
| **I11** | Under-quorum can produce `UNRESOLVED` but never `APPROVED` |
| **I12** | No tally admits a risk-free outcome: every side with ≥ 1 revealed vote has non-zero probability |
| **I13** | `withdraw` implies `openVoteCount == 0` |
| **I14** | A forfeited bond or debit is never credited to another moderator |
| **I15** | The index status at `FINALIZED` does not change as settlement batches proceed |
| **I16** | Every state predicate in §2.2 and §4.2 is mutually exclusive |
| **I17** | At most one challenge round exists per claim |

I2 and I12 are inherited verbatim from v2 (I12 and the no-certainty rule) and are
the two this design is least free to relax.

---

## 10. Open parameters and inherited work

**Open, blocking simulation rather than implementation:**

| Item | Note |
|---|---|
| `d`, `BOND_MIN`, `LAMBDA` | `λ = d` is derived; `d` itself is not. It sets the confidence threshold at which honest voting is rational |
| `REVEAL_BOND`, `CHALLENGE_BOND` | Must exceed the value of the option each prices, and stay far below principal |
| `FEE_BASE`, `FEE_PER_TOPIC` | Must clear gas for `TARGET_COHORT` voters — the binding constraint in every simulation so far |
| `SUPER_QUORUM` | §8.3 |
| `h` | Not a contract parameter at all — design-v3 O10. It decides whether §4.6's round halves the false-approval rate or nearly doubles it |

**Inherited code (§Scope):**

- `StakeRegistry` — survives; loses the sortition tree and gains `bond` and
  `openVoteCount`.
- `IndexRegistry` — survives; gains the provisional statuses of §8.2.
- `RulesetGovernor` — survives unchanged, with §8.4's rule that a version bump does
  not reopen rejections.
- `SortitionTree` — **deleted.** Passive eligibility walks no tree.
- `FreezeMath` — **deleted.** There are no freezes.
- `Moderation`, `Settlement` — rewritten. Panels, duty pools, obligation handles
  and duty settlement have no counterpart here.

**The standing constraint is unchanged.** No deployment with material funds, and
the index is not presented as reliable safe-search certification, until the P0 set
closes and an independent re-audit passes against a named commit. The four-contract
audit does not carry over to this architecture.
