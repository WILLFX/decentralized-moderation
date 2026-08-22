# Moderation Contract v2 — Formal State-Machine Specification

**Milestone:** M2.5
**Status:** Specification. Not implemented. Supersedes `specs/state-machine.md`,
which specifies the first architecture and the contracts in `contracts/`.
**Design:** `specs/design-v2.md` — mechanism and arithmetic, including the payout
derivation this document takes as given.
**Scope:** the on-chain moderation contract (README §5, component 1). Everything
else is a client of this specification.

This document defines the contract as typed state, two interacting state machines
(per-**moderator** and per-**case**), the transitions between their states, the
settlement arithmetic, and the invariants that must hold at every block. Parameters
marked *(working)* are simulation inputs, not final values.

> **Decisions taken here, not in the design document.** Four rules follow from the
> design but are not stated by it, and each is consequential enough to be visible:
> §3.4 one vote per moderator per case; §4.6 the verdict is redrawn from the pool at
> every round close and only the last draw binds; §4.4 a round without quorum
> extends rather than proceeding; §4.8 a case nobody votes in voids and refunds.
> Each carries its reasoning inline.

---

## 0. Conventions

- **xBZZ** amounts are integers in base units. No floating point anywhere.
- **Time** is block timestamps (seconds). All "days"/"hours" are working durations.
- **Epochs** are coarse time buckets used only by the reputation update (§6),
  working value one day.
- **Randomness** is `blockhash(snapshotBlock)`, domain-separated per case, round
  and purpose (§7). A past block's `prevrandao` is unreadable on the EVM; this is
  the same substitution recorded in `contracts/DEVIATIONS.md` D-1.
- `H(...)` is `keccak256(abi.encode(...))` unless stated otherwise.
- **Rounds** are numbered from 0. Round 0 is the first vote; rounds ≥ 1 are
  challenge rounds.

---

## 1. Parameters

| Name | Working value | Meaning |
|---|---|---|
| `MIN_STAKE` | 10 xBZZ | The stake. Flat — every moderator holds exactly this. |
| `MATURATION` | ≥ `FREEZE_BASE` | Delay before newly staked value may vote (§2.2). |
| `EXIT_COOLDOWN` | 7 days | Delay between exit request and withdrawal. |
| `TARGET_COHORT` | 32 | Expected eligible moderators per round. |
| `MIN_REVEALS` | 5 | Pooled reveals required before a verdict may be drawn. |
| `MIN_NEW_REVEALS` | 3 | Fresh reveals a challenge round must add before it redraws (§4.7). |
| `COMMIT_WINDOW` | 24 h | Commit phase duration. |
| `REVEAL_WINDOW` | 24 h | Reveal phase duration. |
| `CHALLENGE_WINDOW` | 3 d (first: 4 d) | Window in which a verdict may be challenged. |
| `MAX_ROUNDS` | 4 | Round cap. Bounds dilution (design-v2 §4.6). |
| `MAX_EXTENSIONS` | 4 | Quorum-failure extensions before VOID. |
| `AGE_FACTOR_STEP` | 1.5× per extension | Eligibility threshold growth (§3.3). |
| `SEED_LAG` | 2 blocks | Blocks between arming and realizing a seed. |
| `FREEZE_BASE` | 7 d | Base penalty term. |
| `FREEZE_CAP` | 4× | Maximum track-record multiplier. |
| `MAX_TOTAL_FREEZE` | 365 d | Ceiling on accumulated suspension. |
| `TRACK_DECAY` | 0.95 / epoch | Reputation decay. |
| `TRACK_SAT` | 60 | Reputation saturation. |
| `CLAIM_BOUNTY` | 1 % of fee | Paid to whoever triggers settlement. |
| `FEE_BASE`, `FEE_PER_TOPIC` | *(open — §9)* | Must pay `TARGET_COHORT` voters above gas. |
| `MAX_TOPICS` | 5 | Topics per submission. |

---

## 2. Moderator state

### 2.1 Storage

```
struct Moderator {
    uint128 stake;          // 0 or MIN_STAKE. Flat: no other value is representable.
    uint40  maturesAt;      // stake may not vote before this
    uint40  suspendedUntil; // serial freeze accumulator (§5)
    uint40  exitRequestedAt;
    uint32  trackEpoch;     // epoch of the last reputation write
    uint128 track;          // reputation, WAD-scaled (§6)
}
```

`stake` is 0 or `MIN_STAKE`. There is no partial stake, no per-case allocation, and
no duty accounting. **A moderator's stake backs every case they vote in,
simultaneously and without limit.**

### 2.2 States

| State | Predicate |
|---|---|
| `NONE` | `stake == 0` |
| `PENDING` | `stake > 0 && now < maturesAt` |
| `ACTIVE` | `stake > 0 && now ≥ maturesAt && now ≥ suspendedUntil && exitRequestedAt == 0` |
| `SUSPENDED` | `stake > 0 && now < suspendedUntil` |
| `EXITING` | `exitRequestedAt != 0 && now < exitRequestedAt + EXIT_COOLDOWN` |

Only `ACTIVE` moderators may **commit** (§3.4). `SUSPENDED` and `EXITING`
moderators **may still reveal** votes committed while `ACTIVE`, and cases they have
joined settle normally — the penalty removes future participation, never past
judgment.

**`MATURATION` is set independently of `FREEZE_BASE`** (M2.5-F13). An earlier draft
tied them — `MATURATION ≥ FREEZE_BASE` — so that abandoning a suspended identity
could never be faster than serving the suspension. That coupling is unsafe in the
direction the analysis now points: if the freeze term comes down (and both the
simulation and the review argue it must), maturation would follow it down and a
fresh Sybil identity would become usable in hours.

They answer different questions. Maturation is how long an attacker must plan
ahead before an identity is useful, so it is set from the attack-preparation
horizon — days or epochs. Suspension is what repeated bad participation costs.
Concurrent exposure is priced separately again, by per-vote risk accounting. Set
each from its own threat.

Maturation alone is not churn-resistance: a funded attacker pre-ages identities in
bulk. What makes replacement expensive is that track record does not transfer
(§6).

### 2.3 Transitions

| From | To | Trigger | Effect |
|---|---|---|---|
| `NONE` | `PENDING` | `stake(MIN_STAKE)` | transfer in; `maturesAt = now + MATURATION` |
| `PENDING` | `ACTIVE` | `now ≥ maturesAt` | none (predicate) |
| `ACTIVE` | `SUSPENDED` | settlement of a case in which the moderator was incoherent | §5 |
| `SUSPENDED` | `ACTIVE` | `now ≥ suspendedUntil` | none (predicate) |
| `ACTIVE` | `EXITING` | `requestExit()` | `exitRequestedAt = now` |
| `EXITING` | `NONE` | `withdraw()` after cooldown | transfer out; clear record except `track` |

`track` survives exit and re-entry **for the same address**. It is not transferable
and cannot be purchased; abandoning an address abandons it.

---

## 3. Eligibility

### 3.1 The predicate

Moderator `m` is eligible for round `r` of case `c` iff

```
H(ELIGIBILITY_DOMAIN, chainId, address(this), c, r, seed(c, r), m)  <  T(c)
```

evaluated by the moderator off-chain and verified on-chain at commit. Nothing is
enumerated and no transaction assembles a cohort.

### 3.2 Domain separation

`ELIGIBILITY_DOMAIN` is distinct from the outcome-draw domain (§7). Chain id and
contract address are included so a redeployment or a fork cannot reproduce another
instance's cohorts.

### 3.3 The threshold

Each round pins a snapshot at the moment it opens, and the threshold is computed
from that snapshot for the round's whole life:

```
snapshot(c, r) = { activeEpoch, activeCount, priorVoters, seed }
remaining      = activeCount − priorVoters
T(c, r)        = (MAX_UINT256 / remaining) × TARGET_COHORT × ageFactor(c)
ageFactor(c)   = AGE_FACTOR_STEP ^ extensions(c)
```

**The divisor is `remaining`, not the whole active set (M2.5-F8).** §3.4 lets a
moderator vote once per case, so only the not-yet-voted may join round `r` — but an
earlier draft divided by every active moderator, which shrinks each successive
cohort instead of holding it steady. At 100 active with a target of 32 the rounds
come out 32.0, 21.8, 14.8, 10.1: the fourth round is 31% of the first, and
`design-v2` §2.5's claim that cohorts stay the same size fails exactly when the
network is small. At 1000 active the same error costs 9% and is invisible, which is
how it survived a simulation run at that size.

**`activeCount` is a snapshot, not a live read (M2.5-F9).** ACTIVE is a time
predicate — `now ≥ maturesAt`, `now ≥ suspendedUntil` — and no storage counter can
follow a predicate that changes when time passes and nobody transacts. So:
maturation and thaw are **explicit transactions** that move an identity into the
active set for epoch `e+1`, exits and suspensions remove it from future epochs, and
a round pins the epoch it drew against. The first architecture used explicit
`activate()`/`thaw()` for this reason.

Pinning also closes a race the live read created: without it, a moderator's
eligibility could change between checking off-chain and landing on-chain, because
someone else activated or exited in between.

Implementations must define: `remaining == 0`; `TARGET_COHORT ≥ remaining` (clamp
`T` to `MAX_UINT256`, everyone eligible); multiply-after-divide overflow; and the
fixed-point representation of `ageFactor`.

The expected cohort is `TARGET_COHORT` at `ageFactor = 1`, and the realized cohort
is `Binomial(remaining, TARGET_COHORT / remaining)`. **Cohort size is a
distribution, not a target.** Every formula downstream takes the realized count.

`ageFactor` grows only on quorum-failure extension (§4.4). This replaces widening:
no re-draw, no extra tranche, no call.

### 3.4 One vote per moderator per case

**A moderator may commit at most once per case, across all its rounds.** Eligibility
is evaluated per round, so a moderator may be eligible in rounds 0 and 2; having
voted in round 0 they may not vote again in round 2.

Without this rule a moderator eligible in several rounds contributes several votes
to a pooled tally, and "one identity, one vote" — the property flat stake exists to
provide — holds per round but not per case, which is the level the verdict is drawn
at. A challenger must therefore be a moderator who has not yet voted in the case.

A committed vote is final. It cannot be changed, withdrawn, or re-cast in a later
round.

---

## 4. Case state machine

### 4.1 Storage

```
struct Case {
    Phase   phase;
    uint8   round;            // current round, 0-based
    uint8   extensions;       // quorum-failure extensions used
    address feePayer;
    uint128 fee;
    uint40  phaseDeadline;
    uint40  seedArmedAt;      // block for the current seed
    uint32  pooledApprove;    // POOLED across all rounds
    uint32  pooledReject;
    uint32  committedThisRound;
    Outcome provisional;      // verdict of the most recent draw
    uint40  finalizedAt;      // pinned penalty start (§5.1)
    // content, metadata, topics, ruleset/guidelines versions: as v1
}
```

Votes are **pooled**: `pooledApprove` and `pooledReject` accumulate across every
round and are never reset. This is the design's load-bearing decision
(design-v2 §4.5).

### 4.2 Phases

```
COMMIT ──▶ REVEAL ──▶ DRAW ──▶ CHALLENGE ──▶ FINALIZED ──▶ SETTLED
   ▲                              │
   └──────── challenge ───────────┘
   └──────── extension ──┐
                         │ (quorum failure, §4.4)
        VOID ◀───────────┘ (after MAX_EXTENSIONS)
```

### 4.3 Transition table

| From | To | Trigger | Effect |
|---|---|---|---|
| — | `COMMIT` | `submit(...)` | Charge fee; reserve dedup keys; pin ruleset and guidelines versions; `round = 0`; arm seed at `block + SEED_LAG`; `phaseDeadline = now + COMMIT_WINDOW`. **No moderator is selected, reserved, or notified.** |
| `COMMIT` | `REVEAL` | `now ≥ phaseDeadline` and `committedThisRound > 0` | `phaseDeadline = now + REVEAL_WINDOW` |
| `COMMIT` | `COMMIT` | `now ≥ phaseDeadline` and `committedThisRound == 0` and `extensions < MAX_EXTENSIONS` | `extensions++`; re-arm seed; `phaseDeadline = now + COMMIT_WINDOW`. Threshold grows (§3.3). |
| `COMMIT` | `VOID` | `now ≥ phaseDeadline` and `committedThisRound == 0` and `extensions == MAX_EXTENSIONS` | §4.8 |
| `REVEAL` | `DRAW` | `now ≥ phaseDeadline` or all committers revealed | Pool this round's reveals into `pooledApprove`/`pooledReject`. If `pooled < MIN_REVEALS` → §4.4 instead. The outcome seed block was fixed from the **scheduled reveal deadline** when the round opened (M2.5-F10) — closing early does not move it. |
| `DRAW` | `CHALLENGE` | outcome seed available | Draw `provisional` from the pool (§4.5); **arm the seed for round `r+1`** (M2.5-F7 — it must exist before any challenge can be checked against it); `phaseDeadline = now + CHALLENGE_WINDOW` |
| `CHALLENGE` | `COMMIT` | a challenge is opened (§4.7) and `round + 1 < MAX_ROUNDS` | `round++`; pin the round snapshot (§3.3); pool the challenger's vote (§4.7); `phaseDeadline = now + COMMIT_WINDOW`. The seed was armed on entering `CHALLENGE`, not here |
| `CHALLENGE` | `FINALIZED` | `now ≥ phaseDeadline` with no challenge, **or** `round + 1 == MAX_ROUNDS` | `finalizedAt = now` — the single pinned penalty start (§5.1) |
| `FINALIZED` | `SETTLED` | `claim()` batches complete | §5, §8 |

Every transition is permissionless. `DRAW` and `FINALIZED` are reached by anyone
poking; the settlement bounty pays for the last poke.

### 4.4 Quorum failure extends; it does not proceed

If, at reveal close, `pooledApprove + pooledReject < MIN_REVEALS`, the case does not
draw a verdict. It returns to `COMMIT` with `extensions++`, a grown threshold, and a
fresh seed. Votes already pooled are kept.

A verdict drawn from one or two votes is one or two people's opinion resolved by a
coin flip, and it would enter a *safe-search index*. Extending costs time; proceeding
costs correctness. After `MAX_EXTENSIONS` the case voids (§4.8) rather than
adjudicating below quorum — the first architecture's under-quorum fallback is not
carried forward.

### 4.5 The draw

```
N = pooledApprove + pooledReject
provisional = (outcomeSeed mod N) < pooledApprove ? Approve : Reject
```

Equivalently: **the verdict is one pooled vote, selected uniformly at random.**
`P(Approve) = pooledApprove / N` exactly.

The lottery is linear in the vote counts, and design-v2 §4.3 proves that linearity
is forced: no other exponent admits both payout neutrality and a constant pot.

### 4.6 The verdict is redrawn every round; only the last draw binds

At each `DRAW` the verdict is drawn afresh from the *whole* pooled tally, replacing
the previous provisional. The verdict that stands when the case reaches `FINALIZED`
is the one that settles.

This is what makes a challenge meaningful. The alternative — draw once and let later
rounds adjust — leaves nothing for a challenger to overturn.

It does not reopen retry. An attacker must win the **final** draw, and that draw is
taken at their share of the pool. Winning an intermediate draw achieves nothing if
anyone challenges it, and any moderator holding the majority of the pool is
motivated to: their expected payout from challenging is positive precisely when the
pool favours them.

### 4.7 Challenge

During `CHALLENGE`, a moderator may open a challenge iff:

1. they are eligible for round `r+1` (§3.1);
2. they have not voted in this case (§3.4);
3. they are `ACTIVE`;
4. `round + 1 < MAX_ROUNDS`.

Opening a challenge **is** casting a vote against `provisional`, in public and
immediately pooled. No bond is posted and no fee is charged: the challenger's stake
carries the risk through the ordinary freeze, and if the verdict survives to
`FINALIZED` they are incoherent and suspended like any other losing voter.

The challenger's direction is necessarily disclosed. A challenge in agreement with
the standing verdict would be payout-farming, so only disagreement may open one, and
the act therefore reveals the vote. This is accepted, not fixed: concealing it and
restricting challenges to disagreement are mutually exclusive.

Subsequent voters in round `r+1` commit normally, hidden.

**The seed for round `r+1` is armed when the case enters `CHALLENGE`, not when a
challenge opens (M2.5-F7).** Condition 1 is checked against `seed(c, r+1)`, so an
earlier draft was circular: eligibility depended on a seed that only existed as a
*result* of the challenge it was gating. Arming on entry to the challenge window
breaks the cycle without publishing every future cohort at submission, which is
what a single case-lifetime seed would do.

**How the challenger counts (M2.5-F11).** The challenge is a revealed vote, not a
commitment. It therefore:

- pools immediately into `pooledApprove`/`pooledReject`;
- does **not** increment `committedThisRound`, which counts hidden commitments and
  is what §4.3's no-participation extension keys on;
- does **not** by itself satisfy the round's participation requirement.

A challenge round needs **both** `pooledApprove + pooledReject ≥ MIN_REVEALS`
(already true, since a verdict was drawn) **and** `newRevealsThisRound ≥
MIN_NEW_REVEALS`. Without the second condition a single public challenge vote would
trigger a fresh verdict against an otherwise unchanged pool — one moderator
re-rolling a case on their own. `MIN_NEW_REVEALS` is a working value of 3.

### 4.8 VOID

A case that reaches `MAX_EXTENSIONS` with fewer than `MIN_REVEALS` pooled votes is
`VOID`. The `feePayer` reclaims `fee` less `CLAIM_BOUNTY`; dedup reservations are
released; no entry is written; no moderator is penalised.

Nobody was obligated to vote, so nobody failed. VOID is the protocol declining a
case, not punishing an absence.

---

## 5. Settlement

Triggered by `claim()`, batched, permissionless, bounty to whoever completes it.

```
P = fee − CLAIM_BOUNTY
W = (provisional == Approve) ? pooledApprove : pooledReject
share = P / W                       // floor division
remainder = P − W × share           // credited to feePayer, never to voters
```

Every voter coherent with `provisional` receives `share`, **whether they voted in
round 0 or round 3**. Every incoherent voter is suspended (§5.1).

Equal shares across rounds are deliberate: paying early voters more would price the
information disadvantage of voting first, and paying later voters more would reward
waiting. Neither is worth the liveness cost.

**Neutrality.** `E[pay | Approve] = (A/N)(P/A) = P/N` and
`E[pay | Reject] = (B/N)(P/B) = P/N`. A voter's expected payout is `P/N` regardless
of direction — see design-v2 §4.2. Under floor division the two differ by at most
one base unit; the remainder goes to the fee payer because its size depends on `W`
and therefore on the verdict, and **money whose existence depends on the verdict
must never reach the people choosing it.**

No stake is ever transferred between moderators. Rewards are external money — fees —
only.

### 5.1 Suspension

```
duration = FREEZE_BASE × min(FREEZE_CAP, trackFactor(winning side))
until    = min(finalizedAt + MAX_TOTAL_FREEZE,
               max(finalizedAt, m.suspendedUntil) + duration)
```

**Serial, not maximum.** Three penalties give the sum of three terms. Required, not
refined: one stake backs unlimited concurrent cases, so a penalty servable once
would be diluted to nothing by voting in many cases at once. Time is the punishment
currency because it does not dilute under concurrency.

Flat stake makes this exact with one accumulator. There are no partially-frozen
tranches to expire separately, which is what forced the first architecture's
`max` rule.

**One pinned start.** Every moderator penalised by this case derives expiry from
`finalizedAt`, never from the block their settlement batch executed in.

---

## 6. Reputation

```
on write, for a case finalized in epoch e_case, at epoch e_now:
    track  := track × TRACK_DECAY^(e_now − trackEpoch)
            + credit × TRACK_DECAY^(e_now − e_case)
    trackEpoch := e_now
```

`credit` is 1 per coherent participation, saturating at `TRACK_SAT`.

**Order-independence is required, not desirable.** Each credit is discounted from
*its own case's* epoch to the present, so concurrent cases commute:

```
track = track₀·d^(now−e₀) + a·d^(now−e_A) + b·d^(now−e_B)
```

identical under either settlement order. The first architecture's `track = d·track +
credit` is non-commutative, so permissionless settlement order altered a moderator's
standing; here reputation gates the freeze that deters everything, so that would be
a security defect rather than a wart.

---

## 7. Randomness

Two independent, domain-separated seeds per round:

| Seed | Armed at | Purpose |
|---|---|---|
| `seed(c, r)` | round open + `SEED_LAG` | eligibility (§3.1) |
| `outcomeSeed(c, r)` | **scheduled** reveal deadline + `SEED_LAG` | the draw (§4.5) |

Both are `H(domain, chainId, address(this), c, r, blockhash(armedBlock))`.

Realized **lazily** — the first transaction that needs a seed stores it. This keeps
selection at zero dedicated transactions. If the armed block ages out of the
256-block window before anyone touches it, the next toucher re-arms to a fresh
block.

The outcome seed block is derived from the round's **scheduled** reveal deadline,
never from the transaction that happens to close the phase (M2.5-F10). A round can
close early when every committer has revealed, and an earlier draft armed the seed
relative to that closing block — which handed the last outstanding committer a
choice of entropy source: reveal now, reveal later, or force the deadline. It could
not know the future blockhash, but choosing *which* future block supplies it is
already too much influence, and more so for a committer who is also a proposer.

The tally is still fixed before the randomness that resolves it exists. What a
committer can influence is narrower but not nothing: withholding a reveal changes
the *distribution* the draw runs over, since the pool it samples is smaller. The
claim that the tally cannot be steered by withholding a reveal is therefore too
strong — the sample is unknowable, its distribution is not. Pricing the withheld
reveal is what the non-reveal penalty is for (`v2-audit-triage.md` §2).

Proposer influence is real and accepted for the MVP: a proposer can bias both the
eligible cohort and the draw. The prize is the listing, whose value no pot cap
bounds — see README §3.7.

---

## 8. Index effects

Unchanged from the first architecture except where flat voting simplifies it.

On `SETTLED` with `provisional == Approve`: write one entry per topic, carrying
content hash, metadata hash, approval time, `uncontested`, `fullQuorum`, and the
pinned ruleset/guidelines versions. On `Reject` for a removal case: delete the
target and release its reservation.

- `uncontested` — `pooledReject == 0`. A challenge *is* a reject vote, so a
  challenged entry is never uncontested. Simpler than the v1 rule, under which an
  appeal could be filed with no vote behind it.
- `fullQuorum` — `pooledApprove + pooledReject ≥ MIN_REVEALS`. Distinct votes are
  distinct moderators by construction (§3.4), so the v1 caveat about a multi-seat
  voter satisfying quorum alone does not arise.

The **unopposed** view stays `uncontested && fullQuorum && now − approvalTime ≥ 96h`.

Note what `fullQuorum` actually asserts: the pooled tally reached `MIN_REVEALS`,
whose working value is **5** — not that a full `TARGET_COHORT` turned out. Five
unanimous votes satisfy it. The view was previously called *supersafe* and
described as near-certainty, which this definition does not support (M2.5-F4).
Either the name stays factual or the threshold rises; it must not be both loose
and reassuring.

---

## 9. Invariants

Must hold at every block.

| # | Invariant |
|---|---|
| I1 | `balanceOf(this) == Σ stakes + Σ open-case fees + Σ unclaimed credits` |
| I2 | No transition moves stake from one moderator to another. Ever. |
| I3 | `m.stake ∈ {0, MIN_STAKE}` |
| I4 | A moderator has at most one committed vote per case (§3.4) |
| I5 | `pooledApprove + pooledReject` is non-decreasing over a case's life |
| I6 | A verdict is drawn only when `pooledApprove + pooledReject ≥ MIN_REVEALS` |
| I7 | `Σ share × W + remainder == P` for every settled case |
| I8 | Every moderator penalised by a case derives expiry from the same `finalizedAt` |
| I9 | `suspendedUntil ≤ finalizedAt + MAX_TOTAL_FREEZE` |
| I10 | Reputation is invariant under permutation of concurrent-case settlement order |
| I11 | No case reaches `SETTLED` in more rounds than `MAX_ROUNDS` |
| I12 | No storage write reserves, locks, or obligates any moderator at submission |

I12 is the architecture's defining property, stated as something a test can falsify.

---

## 10. Open parameters

Blocking values, owned per `specs/design-v2.md` §9: `FEE_BASE` and `FEE_PER_TOPIC`
(must pay `TARGET_COHORT` voters above gas, which sets equilibrium turnout);
`TRACK_DECAY`, `TRACK_SAT` and the freeze multiplier curve (reputation weight);
`MAX_ROUNDS` against the dilution curve; `AGE_FACTOR_STEP` against worst-case
time-to-quorum.

None are settled. Solidity may be written against the structure; the numbers come
from simulation.
