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
> - §3.5 — **a challenge is a bond, not a vote**, and carries no eligibility
>   test. This removes the forced disclosure v2 §4.7 accepted as unavoidable, and
>   returns the challenge to the round-0 dissenters, who are the population `h`
>   depends on.
> - §3.5b — **round 1 opens on the schedule, not on the challenge.** Filing early
>   does not start the round early, so no seed depends on the challenger's chosen
>   block.
> - §4.5 — **one randomness per claim**, evaluated against both tallies. The
>   verdict is monotone in the tally, so a challenge that adds no votes changes
>   nothing and there is no second roll to buy.
> - §4.6 — `MIN_CHALLENGE_REVEALS` is removed; `CHALLENGE_BOND` settles on
>   whether the verdict moved, not on turnout.
> - §4.8 — one terminal `UNRESOLVED` with a reason, rather than separate
>   `NO_QUORUM` and `VOID` states. §4.8 later split the reason codes, because
>   they carry different debits and different retry rules.
> - §4.8 / §5.2 — **the quorum gate is on commits, not reveals**, and
>   `REVEAL_BOND = d` makes revealing weakly dominant. Together these remove the
>   marginal revealer's choice between two terminal classes.
> - §4.9 — **round 1 has no quorum gate.** §4.5's monotonicity makes an empty
>   challenge round self-healing, and a gate there would let a rejected submitter
>   escape their rejection by challenging and staying quiet.
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
| `REVEAL_BOND` | **`= d`** | Covered at commit, debited on non-reveal (§5.2). **Not a free parameter** — §2.4 caps it at `d`, §5.2's dominance argument floors it at `d`. The two meet at one point. |
| `CHALLENGE_BOND` | *(open — §10)* | Posted to register a challenge. Returned if the final verdict differs from the provisional, forfeit otherwise (§4.6). |
| `MATURATION` | *(open)* | Delay before newly staked value may vote. Set from the attack-preparation horizon, **not** from any penalty term. |
| `EXIT_COOLDOWN` | 7 d | Delay between exit request and withdrawal. |
| `TARGET_COHORT` | 40 | Expected eligible moderators per round. |
| `MIN_COMMITS` | 16 | Commits required at commit close, or the case ends `UNRESOLVED(NO_TURNOUT)` (§4.8). **This is the quorum gate** — decided before anyone can see a tally. |
| `MIN_REVEALS` | 16 | Pooled reveals required before any verdict may be drawn. A shortfall here is a *withholding* event, not a turnout event (§4.8). |
| ~~`MIN_CHALLENGE_REVEALS`~~ | — | **Removed, §4.6.** §4.5's single-randomness rule makes an unchanged tally yield an identical verdict, so the floor has no job. |
| `SUPER_QUORUM` | *(open)* | Reveals required for the strict assurance class (§8.3). |
| `RETRY_COOLDOWN` | *(open — §10)* | Delay before a claim that ended `UNRESOLVED(WITHHELD)` may be resubmitted (§8.4). |
| `COMMIT_WINDOW` | 20 min | Per round. |
| `REVEAL_WINDOW` | 20 min | Per round. |
| `FINALIZATION_GRACE` | 10 min | Between outcome block and hard deadline. |
| `CHALLENGE_WINDOW` | 12 h | From provisional publication. |
| `SEED_LAG` | 2 blocks | Between arming and realizing a seed. |
| `LATE_WIDEN_AT` | minute 12 of commit | Eligibility widening trigger (§3.3). |
| `LATE_WIDEN_FACTOR` | 1.5× | Threshold multiplier at widening. |
| `DRAW_BOUNTY` | 0.5 % of fee | Paid to whoever triggers **either** draw (§4.3). Separate from `CLAIM_BOUNTY` because the draw, not finalization, is the transition with a hard expiry (§7.3, F16). |
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
    uint32  openChallenges;  // registered challenges not yet resolved (§2.4)
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
liabilities(m) = LAMBDA · m.openVoteCount            (§5.1 — d or REVEAL_BOND)
               + CHALLENGE_BOND · m.openChallenges   (§4.6)

mayCommit(m)     iff  ACTIVE and bond ≥ BOND_MIN + liabilities(m) + LAMBDA
mayChallenge(m)  iff  ACTIVE and bond ≥ BOND_MIN + liabilities(m) + CHALLENGE_BOND
withdraw(m)      iff  cooldown elapsed and liabilities(m) == 0
```

**Nothing is transferred by any of these.** `liabilities()` is a *covered amount*,
not an escrow: no value leaves `bond` at commit or at challenge registration, and a
moderator who posts more bond can do more of both with no ceiling. What the tests
guarantee is that the balance can absorb every outstanding claim at once.

**The single-function form is the point, not the arithmetic.** An earlier revision
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

**Why `λ = d` is the working value.** A single open vote can produce two debits and
they are mutually exclusive — a vote either reveals, risking `d` if incoherent, or
fails to reveal, forfeiting `REVEAL_BOND` and risking no `d`. So its coefficient is
the larger, not the sum:

```
LAMBDA ≥ maxDebitPerOpenVote = max(d, REVEAL_BOND)
```

`LAMBDA = d` therefore holds only under **`REVEAL_BOND ≤ d`**, recorded in §1 and
to be re-checked whenever either parameter moves. A smaller `LAMBDA` admits
insolvency; a larger one rations capacity for no safety gain.

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

- `CHALLENGE_BOND`, forfeit if the round fails its floor (§4.6).
- §4.5's monotonicity — a challenge that adds no votes returns the same verdict,
  so registering one buys nothing on its own.
- One challenge per claim (I17). The first valid registration wins; later ones
  revert rather than queue.

**Round-0 voters may register a challenge. They still may not vote in round 1.**
§3.4 is about the tally and is unchanged — a moderator counted twice would corrupt
the pooled tally the verdict is drawn from. Registering is not voting. A round-0
dissenter who challenges is staking `CHALLENGE_BOND` *and* their existing exposure
to `d` on the pooled tally moving their way, which is the tightest alignment
between information and incentive anywhere in this design.

Two consequences worth stating:

- The challenger's direction is secret, so round-1 voters cannot herd behind it.
- A challenger who registers and then reveals *in agreement* with the provisional
  has wasted a bond and gained nothing. No rule is needed to prevent it.

### 3.5b Round 1 opens on the schedule, not on the challenge

**Decision.** A challenge *registers* at any point inside the challenge window.
Round 1's commit phase opens at the window's **scheduled close**, the same instant
at which an unchallenged case would have finalized.

Without this, round 1's seeds are functions of the block the challenger chose:

```
        rejected:  eligSeedBlock₁    = blockAt(challengeTx) + SEED_LAG
                   outcomeSeedBlock₁ = blockAt(challengeTx + windows) + SEED_LAG

        adopted:   eligSeedBlock₁    = blockAt(scheduledWindowClose) + SEED_LAG
                   outcomeSeedBlock₁ = blockAt(scheduledWindowClose
                                               + COMMIT_WINDOW + REVEAL_WINDOW)
                                       + SEED_LAG
```

The challenger has twelve hours of discretion over *when* to file. Under the
rejected form that is twelve hours of discretion over **which cohort is drawn and
which entropy decides the case** — the same free option §4.4 refuses to grant the
last revealer, handed to a party who gets to look at the provisional verdict first.
Both seeds are now fixed at the provisional draw, which is itself fixed at
submission, so I7 holds for round 1 as it does for round 0.

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
    uint8   unresolvedReason;  // NO_TURNOUT | WITHHELD | NO_RANDOMNESS
    uint128 pot;               // initial pot; grows by the reserve on challenge
    uint128 challengeReserve;  // escrowed; refunded or activated
    uint40  phaseDeadline;
    uint40  eligSeedBlock;     // armed at round open
    uint40  outcomeSeedBlock;  // armed at round open, from the SCHEDULED deadline
    uint32  pooledApprove;     // POOLED across rounds, never reset
    uint32  pooledReject;
    uint32  commitsThisRound;
    uint32  revealsThisRound;
    uint32  reveals0;          // round-0 reveal count, recorded for §8.3
    uint128 u0; uint128 u1;    // the claim's three uniforms (§4.5), realized
    uint128 u2;                //   at the round-0 draw and reused at DRAW_F
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
                           or outcome seed expired      │                      │
                                                        └──────┬───────────────┘
                                                               ▼
                                                            SETTLED
```

**Both terminals discharge.** `UNRESOLVED` reaches `SETTLED` too — it releases
escrows and liabilities without writing a verdict (§4.8). It is not a leaf.

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
| `COMMIT` **(r=0)** | `REVEAL` | `now ≥ phaseDeadline` and `commitsThisRound ≥ MIN_COMMITS` | `phaseDeadline = now + REVEAL_WINDOW` |
| `COMMIT` **(r=0)** | `UNRESOLVED` | `now ≥ phaseDeadline` and `commitsThisRound < MIN_COMMITS` | `unresolvedReason = NO_TURNOUT`. Nobody could have steered this — see §4.8 |
| `COMMIT` **(r=1)** | `REVEAL` | `now ≥ phaseDeadline` | `phaseDeadline = now + REVEAL_WINDOW`. **No quorum gate in round 1** — §4.9 |
| `REVEAL` **(r=0)** | `DRAW` | `now ≥ phaseDeadline` and `pooled ≥ MIN_REVEALS` | pool this round's reveals |
| `REVEAL` **(r=0)** | `UNRESOLVED` | `now ≥ phaseDeadline` and `pooled < MIN_REVEALS` | `unresolvedReason = WITHHELD` — commits cleared `MIN_COMMITS` and reveals did not (§4.8) |
| `DRAW` **(r=0)** | `PROVISIONAL` | outcome seed available | **realize and store `u[0..2]`** (§4.5); evaluate `provisional`; pay `DRAW_BOUNTY`; publish (§8.2); `reveals0 = revealsThisRound`; `phaseDeadline = now + CHALLENGE_WINDOW` |
| `PROVISIONAL` | `PROVISIONAL` | `challenge()` (§3.5): `mayChallenge(caller)` (§2.4), `now < phaseDeadline`, `challenger == 0` | **registers only.** `challenger = msg.sender`; `openChallenges++`. Nothing is transferred — the bond is *covered*, not escrowed (§2.4). No phase change, no seed armed, no deadline moved. A second call reverts (I17) |
| `PROVISIONAL` | `COMMIT` | `now ≥ phaseDeadline` and `challenger != 0` | `round = 1`; activate `challengeReserve` into `pot`; **`revealsThisRound = 0`**; arm both round-1 seeds **from this scheduled close** (§3.5b, §7.1); `phaseDeadline = now + COMMIT_WINDOW` |
| `PROVISIONAL` | `FINALIZED` | `now ≥ phaseDeadline` and `challenger == 0` | `verdict = provisional`; `finalizedAt = now` |
| `REVEAL` **(r=1)** | `DRAW_F` | `now ≥ phaseDeadline` | pool round-1 reveals. **No threshold** (§4.6), and none needed (§4.9) |
| `DRAW_F` | `FINALIZED` | — | evaluate the stored `u` against the **pooled** tally (§4.5); `finalizedAt = now`. **No seed is read here** — the claim's randomness was realized at the round-0 draw. `CHALLENGE_BOND` settles at `SETTLED` with every other liability (§4.6) |
| `DRAW` **(r=0)** | `UNRESOLVED` | outcome seed expired (§7.3) | `unresolvedReason = NO_RANDOMNESS`; pay `DRAW_BOUNTY` to the caller. **Reachable at the round-0 draw only** — `DRAW_F` reads no seed |
| `FINALIZED` | `SETTLED` | `claim()` batches complete | §5, §8 |
| **`UNRESOLVED`** | **`SETTLED`** | **`claim()` batches complete** | **§4.8 — discharge. Return every `REVEAL_BOND`, decrement every `openVoteCount`, refund per §4.8. No verdict is written and no incoherence debit is applied** |

Every transition is permissionless. `DRAW_BOUNTY` pays for the draw poke — the only
transition with a hard expiry — and `CLAIM_BOUNTY` for finalization.

**Guards must be pairwise disjoint** (§9 I18). Every row above is qualified by its
round where the round matters; a state reachable by two rows with different effects
is a defect, not an implementer's choice.

**Every field in §4.1 must be written or provably preserved by every transition**
(§9 I19). `revealsThisRound` is the field this rule exists for: without the reset
above, the round-1 threshold reads round 0's count and §4.6 is unreachable for
every `reveals₀ ≥ 12`.

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

### 4.5 The draw — one randomness per claim, evaluated twice

**Decision.** Three uniforms are fixed **once per claim**. Both the provisional and
the final evaluation use the *same* three values against different tallies.

```
u[i] = uint128( H(OUTCOME_DOMAIN, chainId, contract, caseId, i,
                  blockhash(outcomeSeedBlock)) )          i = 0,1,2
       -- realized once, at the round-0 draw, and STORED on the case (§4.1)

N = pooledApprove + pooledReject
ticket[i] = ( u[i] · N  <  pooledApprove · 2^128 )        -- i.e. u[i]/2^128 < a
verdict   = (ticket[0] + ticket[1] + ticket[2] ≥ 2) ? Approve : Reject
```

`u[i]/2^128` is uniform on [0,1), so `P(ticket = Approve) = a` and
`P(verdict = Approve) = 3a² − 2a³ = f(a)` exactly as before. Verified by simulation
at 400k draws: 0.2146 / 0.4998 / 0.7833 / 0.9925 against `f` = 0.2160 / 0.5000 /
0.7840 / 0.9927.

**Note the comparison form.** `u · N < approve · 2^128`, *not* `u mod N < approve`.
Both are uniform, but only the first is **monotone in `a`**: with `u` fixed, adding
Reject votes lowers `a`, which can flip tickets from Approve to Reject and never
the reverse. The modulo form reshuffles on every change of `N`, so a single added
vote acts as a fresh re-roll. Simulated over 20,000 fixed-`u` draws sweeping `a`
across [0,1]: zero monotonicity violations.

**Why this is the whole answer to challenge-round optional stopping.**

A challenger who adds no votes changes nothing — the tally is identical, so the
tickets are identical, so `verdict == provisional`. A challenger who adds votes
moves `a`, and can only move the verdict *toward the side they added*. **There is
no second roll to buy.** The only way to change the answer is to change the
evidence, which is what the round is for.

What that costs an attacker who lost round 0 at `a₀ = 0.3125` (10 Approve, 22
Reject), measured over 20,000 draws:

```
Approve votes needed to flip the verdict
    median  21        10th pct  3        90th pct  98
    47.1% of the time they need more than 22 — parity in the pooled tally or worse
    6.9%  of the time two votes suffice

under a fresh round-1 draw they need ZERO extra votes for a 23.2% chance
```

So the rule converts *buy another lottery ticket* into *buy a majority of the
pool*. Priced deterrence is replaced by a structural one, which matters because the
prize — the listing — is external and cannot be priced.

**It also removes most of the design's exposure to `h`.** design-v3 O10 named
honest challenge reliability as the single quantity deciding whether the challenge
round helps or hurts. Simulated at 30% hostile, `TARGET_COHORT` 40, honest turnout
0.8:

```
                     h=0      h=0.25    h=0.5     h=1.0
fresh round-1 draw   0.483    0.434     0.383     0.285
same u (adopted)     0.316    0.309     0.300     0.284
```

A fresh draw makes the challenge round a 20-point gift to an attacker when the
honest side is unreliable. The same-`u` rule flattens that to 3 points — the design
stops depending on a quantity that lives outside the contract.

**Consequences elsewhere:**

- **One outcome seed per claim, not per round** (§7.1). Round 1 needs an
  *eligibility* seed only. `NO_RANDOMNESS` is therefore reachable at the round-0
  draw and nowhere else, and the 256-block `blockhash` horizon never has to span
  the 12-hour challenge window.
- **`u` must be stored** at the round-0 draw (§4.1). It is not recoverable from
  `blockhash` twelve hours later.
- **Round-1 pivotality is visible.** `u` is public after the provisional, so a
  round-1 voter can compute the exact `a` that flips the verdict and whether their
  own vote is pivotal. This is recorded, not fixed: it sharpens F7's marginal-
  revealer problem in round 1 while removing the threshold cliff that was F7's
  other half. F7 remains open (§10).

**With replacement is still required**, and now trivially: `u[0..2]` are
independent, so a side holding one revealed vote keeps `f(1/32) = 0.287%`. Without
independence a 31–1 tally would decide with certainty, contradicting I12.

The implementation must guard `N > 0` explicitly even though `N ≥ MIN_REVEALS`
holds: a revert inside the draw leaves a case permanently unfinalizable.

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

**`CHALLENGE_BOND` is now settled on the outcome, not on turnout:**

```
final verdict != provisional  ->  no debit
final verdict == provisional  ->  bond -= CHALLENGE_BOND, to the maintenance reserve
either way                    ->  openChallenges--          (§2.4)
```

Nothing was transferred at registration, so "returned" means only that the
liability clears. Both branches run at `SETTLED` alongside every other debit, so
they inherit §5.1's commutativity and §4.8's discharge guarantee.

The challenger bet that the pool would move. It is a bet on evidence, which is what
they are being asked to supply, and it prices a frivolous challenge without making
anyone's participation conditional on anyone else's.

Round-1 reveals **always** pool and are **always** judged against the final verdict.
The activated `challengeReserve` stays in the pot and is distributed, because the
round-1 voters who turned up performed real work.

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
`NO_QUORUM` and `VOID` states as in v2. The code is not a label: it determines the
debits and the retry rule.

| Reason | Condition | Steerable? | Retry |
|---|---|---|---|
| `NO_TURNOUT` | `commitsThisRound < MIN_COMMITS` at commit close | **no** | free, full refund |
| `WITHHELD` | commits cleared the gate, `pooled < MIN_REVEALS` at reveal close | yes | claim reserved for `RETRY_COOLDOWN`; a fresh nonrecoverable fee |
| `NO_RANDOMNESS` | the fixed outcome seed expired unread (§7.3) | partly (§10, F16) | see §8.4 |

**The quorum gate is on commits, not reveals, and that is the whole fix for the
marginal-revealer problem.** Commits are made blind — the tally does not exist yet
— so no committer can steer the gate toward a result they cannot see. Reveals are
plaintext and the running tally is public, so a gate on reveals handed the
`MIN_REVEALS − 1`-th revealer a free choice between two different terminal
processes: reveal and take a draw at a computable `f(a)`, or withhold and get a
result-free, freely-retryable `UNRESOLVED`. The price of converting an unfavourable
draw into a fresh attempt was one `REVEAL_BOND`.

Splitting the failure by cause removes that. A genuine turnout failure is decided
before anyone knows anything, and is free to retry because nobody could have caused
it. A reveal-stage shortfall is by construction a *withholding* event — enough
people committed — so it costs the withholders (below) and it does not hand the
submitter's claim back for free.

In every case: no verdict, no index entry, and no *incoherence* debit for anyone —
there is no verdict to be incoherent with. Revealers are paid nothing and lose
nothing.

**Non-revealers are debited anyway.** `REVEAL_BOND` is charged whenever a commit
is not opened, in every terminal state including this one. Failing to complete a
voluntary commitment is not contingent on whether the case reached a verdict, and
an earlier revision that waived it here made withholding free in exactly the state
withholding produces.

**`UNRESOLVED` discharges through `SETTLED`, like every other terminal.** It is not
a leaf. An earlier revision made it one, which left `openVoteCount` permanently
incremented for everyone who had committed — and since `withdraw` requires
`openVoteCount == 0` (§2.3), their stake and bond were locked forever by the
design's own intended failure mode. **Every terminal state must discharge every
liability it created** (§9 I20).

**Value flow, stated exactly** (`challengeReserve` is *moved into* `pot` on
challenge, §4.3, so refunding both would pay it twice):

```
never challenged  ->  refund pot + challengeReserve
challenged        ->  refund pot                      (the reserve is inside it)
either way        ->  return every REVEAL_BOND
                      return CHALLENGE_BOND to the challenger — §4.6's forfeit
                      is for a round that ran and missed its floor, not for a
                      case that could not resolve
                      retain finalizationBounty and maintenance
```

The reason code is load-bearing rather than diagnostic: it decides the debits and
the retry rule. `NO_TURNOUT` is a market problem, `WITHHELD` is an attack surface,
`NO_RANDOMNESS` is a keeper problem, and they cannot share a treatment.

**`UNRESOLVED` must never be reachable from an under-quorum pool by approving it.**
A bounded failure is correct; an unsafe success is not.

### 4.9 Round 1 has no quorum gate, and needs none

**Decision.** `MIN_COMMITS` and `MIN_REVEALS` are tested at round 0 only. Round 1
always proceeds to its reveal phase and always proceeds to `DRAW_F`, whatever
turnout it attracts — including none.

**Why no gate is needed.** By §4.5 the verdict is `u` evaluated against the pooled
tally, and `u` is fixed for the claim. A round 1 that adds no votes leaves the
pooled tally identical to round 0's, so `verdict == provisional` *by arithmetic*.
An empty challenge round is self-healing; it does not need a rule.

**Why a gate is actively harmful here.** An earlier revision applied the
`MIN_COMMITS` gate to both rounds, and that recreated the defect F8 named — with a
cheaper trigger than the one F8 described. A submitter whose content was
provisionally `REJECTED` could register a challenge, let round 1 go quiet, and take
`UNRESOLVED(NO_TURNOUT)`: claim released, pot refunded, resubmit freely (§8.4). A
permanent rejection escaped for the price of `CHALLENGE_BOND`, using nothing but
*inaction* — no seed expiry, no coordination, no votes.

The general rule this is an instance of, stated so the next revision cannot
reintroduce it a third time:

> **I26 — once `provisional` is written for a claim, no reachable terminal may
> release that claim's key.** The reservation set is monotone in "a draw has
> occurred."

**`CHALLENGE_BOND` on an empty round 1.** §4.6 settles it on whether the verdict
moved. An empty round leaves the verdict unmoved, so the bond is forfeit — which is
correct: the challenger bet the pool would move, and it did not. The activated
`challengeReserve` still joins the pot and is distributed to the round-0 coherent
side. That is a windfall funded by the challenger's failed bet, and it is the right
place for it to land.

---

## 5. Settlement

### 5.1 Penalties are balance debits, never time

At `SETTLED`, for every revealed vote in either round:

```
coherent with verdict    -> bond += share            (§5.3)
incoherent with verdict  -> bond -= d                 -> maintenance reserve
committed, never revealed -> bond -= REVEAL_BOND      -> maintenance reserve (§5.2)
```

**Every value removed from `bond` has a named destination, and it is never another
moderator** (§9 I14, I21). `d`, `REVEAL_BOND` and `CHALLENGE_BOND` all go to the
maintenance reserve. Routing any of them to the opposing side would create
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

**`REVEAL_BOND = d` is derived, not chosen — and it is forced from both sides.**

A committer holding belief `p` that they are coherent with the eventual verdict
compares:

```
reveal    ->  p · share − (1 − p) · d
withhold  ->  − REVEAL_BOND

reveal is at least as good  iff  p · share − (1 − p) · d + REVEAL_BOND ≥ 0
```

At `REVEAL_BOND = d` the left side collapses to `p · (share + d)`, which is
non-negative for every `p`. **Revealing weakly dominates withholding at every
belief, every tally and every turnout** — no computation of `f(a)`, no view of the
running count, and no assumption about anyone else's behaviour. Verified across
`share`/`d` combinations: the minimum of `reveal − withhold` over `p ∈ [0,1]` is
exactly 0 at `REVEAL_BOND = d`, and strictly negative for any smaller value.

So `REVEAL_BOND ≥ d` is required for dominance, and §2.4 requires `REVEAL_BOND ≤ d`
or `LAMBDA` must rise above `d`. **The two constraints meet at one point.**
`REVEAL_BOND` is not a free parameter and should not appear in a simulation sweep.

**What this closes and what it does not.** It closes selective reveal for anyone
optimizing *inside* the protocol's payoffs — the ordinary case, and the one O5 and
§11's "strategic commitment" were about. It does not close it for an attacker whose
prize is a listing, which is external and cannot be priced against. Against those,
the defence is §4.8's `WITHHELD` treatment: the debit still lands, the claim is not
handed back, and dragging reveals below `MIN_REVEALS` costs `d` per identity
withheld.

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

By §2.4, `bond ≥ BOND_MIN + liabilities(m)` held after every operation that added
a claim, so the total debit from every outstanding claim resolving against the
moderator at once is covered by construction. **Write `liabilities(m)`, not
`LAMBDA · openVoteCount` and certainly not `d · openVoteCount`** — the narrower
forms are equal only under today's parameter choices and today's set of debits, and
recording the value rather than the property is how a bound gets broken by a change
made somewhere else. It already happened twice here: once when `REVEAL_BOND` was
omitted from `LAMBDA`, and once when `CHALLENGE_BOND` was omitted from the
liability function entirely.

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

| Seed | Scope | Derived from | Used for |
|---|---|---|---|
| `eligSeedBlock` | **per round** | that round's **scheduled** open + `SEED_LAG` | §3.1 eligibility |
| `outcomeSeedBlock` | **per claim** | round 0's **scheduled** reveal close + `SEED_LAG` | §4.5 — realized once into `u[0..2]` |

**There is one outcome seed per claim, not per round** (§4.5). Round 1 has an
eligibility seed and no outcome seed: the final evaluation reuses the stored `u`.
Two things follow. The `blockhash` horizon never has to span the 12-hour challenge
window, and `NO_RANDOMNESS` is reachable at the round-0 draw and nowhere else.

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
outcomeSeedBlock = blockAt(scheduledRevealClose) + SEED_LAG
```

It must **not** depend on when the final reveal arrives, whether the case was
challenged, **when it was challenged**, who called the transition, whether everyone
revealed early, or when round 1 opened. This is what makes §4.4's "no early closure" rule enforceable
rather than advisory, and it closes both M2.5-F10 and the selective-realization
surface (P1-2).

### 7.3 No lazy re-arming

If `blockhash(outcomeSeedBlock)` is unavailable when the draw is attempted, the
case terminates `UNRESOLVED(NO_RANDOMNESS)`. **A fresh future block is never
selected.**

Re-arming lets a party inspect whether a seed is favourable, use it when it is, and
let it expire when it is not — a free option over outcomes. The one-hour round
lifecycle makes expiry rare: `blockhash` is available for 256 blocks (~51 minutes)
and the outcome block sits `FINALIZATION_GRACE` before the hard deadline.

**`DRAW_BOUNTY` pays for the poke that reads it** — not `CLAIM_BOUNTY`, which is
paid at finalization, a different transition with no expiry. An earlier revision
named the wrong payment here, leaving the one transition with a hard deadline
unfunded.

**This closes the option of a better seed; it does not close the option of no seed
at all.** With `d > E[share]`, every voter on the losing side of a visible tally
prefers `UNRESOLVED(NO_RANDOMNESS)` — which debits nobody (§4.8) — to a draw they
expect to lose, and killing the case requires only that all of them do nothing.
`DRAW_BOUNTY` must therefore exceed the gas of the poke by enough that *some*
coherent voter calls it, which is a parameter question recorded in §10.

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
claimKey = H(actionType, contentHash, metadataHash, canonicalTopics)
```

| Terminal | Reservation | Retry |
|---|---|---|
| `APPROVED` | reserved while listed | — |
| `REJECTED` | **permanently reserved** | none; only an explicit re-review case |
| `UNRESOLVED(NO_TURNOUT)` | not reserved | freely — no draw occurred and nobody could have caused it |
| `UNRESOLVED(WITHHELD)` | **reserved for `RETRY_COOLDOWN`** | after the cooldown, at a fresh nonrecoverable fee |
| `UNRESOLVED(NO_RANDOMNESS)` | not reserved | freely — reachable at the round-0 draw only (§4.3, §7.1), so no `provisional` exists and the "no draw occurred" premise is true |

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

**Correction is a separate claim.** A removal case runs the same engine — commit,
reveal, three tickets — producing `REMOVED` or `RETAINED`. It is not an appeal of
the original draw.

---

## 9. Invariants

| # | Invariant |
|---|---|
| **I1** | No moderator's `bond` can go negative. Structural: every value the specification can remove from `bond` is a term in `liabilities()` (§2.4), and every operation that adds a claim tests `bond ≥ BOND_MIN + liabilities(m)` after the addition |
| **I2** | Submitting a case reserves, assigns, locks or obligates nothing for any moderator |
| **I3** | A moderator casts at most one vote per **claim**, across all rounds |
| **I4** | Every counted vote was committed before any counted vote in its round was revealed |
| **I5** | **Exactly one randomness draw exists per claim.** `u[0..2]` is realized once and reused; `provisional` and `verdict` are two evaluations of it against different tallies. `provisional` binds nothing |
| **I6** | No payment, debit or reputation credit occurs before `FINALIZED` |
| **I7** | Both seeds of every round derive from schedules fixed at submission, and are independent of every transaction's timing — including the timing of `challenge()` (§3.5b) |
| **I8** | Penalties are invariant under settlement permutation |
| **I9** | The cost of one incoherent vote is independent of `openVoteCount` |
| **I10** | No phase closes before its `phaseDeadline` |
| **I11** | Under-quorum can produce `UNRESOLVED` but never `APPROVED` |
| **I12** | No tally admits a risk-free outcome: every side with ≥ 1 revealed vote has non-zero probability. **Every revealed vote in either round is counted in the tally the binding verdict is evaluated against** — no vote is judged against a tally it was excluded from |
| **I13** | `withdraw` implies `liabilities(m) == 0` — *every* outstanding claim discharged, not only open votes |
| **I14** | A forfeited bond or debit is never credited to another moderator |
| **I15** | The index status at `FINALIZED` does not change as settlement batches proceed |
| **I16** | Every state predicate in §2.2 and §4.2 is mutually exclusive |
| **I17** | At most one challenge round exists per claim |
| **I22** | The verdict is monotone in `a` for fixed `u`: adding votes to one side can move the verdict only toward that side, never away from it |
| **I23** | `liabilities()` is the single point of truth for claims on `bond`. Adding any debit to this specification means adding a term to it; no test may use a narrower expression |
| **I24** | No single revealer's decision changes the terminal *class* of a case. Every gate that selects between terminal classes is evaluated against values fixed before the tally is observable |
| **I25** | The non-reveal debit is applied in every terminal state, including those in which no verdict was drawn |
| **I26** | Once `provisional` is written for a claim, no reachable terminal releases that claim's key. The reservation set is monotone in "a draw has occurred" |
| **I18** | The guards of §4.3 are pairwise disjoint: in every reachable state exactly one row is enabled |
| **I19** | Every field of §4.1 is written or provably preserved by every transition. No field is implicitly carried across a round boundary |
| **I20** | Every terminal state discharges every liability it created: `openVoteCount` returns to its pre-commit value and every escrow is released, within a bounded number of permissionless calls |
| **I21** | Every value removed from `bond` has a named destination, and that destination is never another moderator |

I2 and I12 are inherited verbatim from v2 (I12 and the no-certainty rule) and are
the two this design is least free to relax.

**I18–I21 are generalizations, not additions.** Each was written because a specific
defect of this document was an instance of it: a duplicated `REVEAL` guard (I18), a
per-round counter never reset (I19), a terminal state with no discharge path that
locked stake permanently (I20), and a debit with no stated destination (I21).
Stating the class rather than the instance is the difference between a fix and a
property — the same lesson as the freeze bound, which was clamped at two call sites
while a third existed.

---

## 10. Open parameters and inherited work

**Open, blocking simulation rather than implementation:**

| Item | Note |
|---|---|
| `d`, `BOND_MIN`, `LAMBDA` | `λ = d` is derived; `d` itself is not. It sets the confidence threshold at which honest voting is rational |
| ~~`REVEAL_BOND`~~ | **Closed.** `= d`, forced from above by §2.4 and from below by §5.2's dominance argument. Not a sweep parameter |
| `RETRY_COOLDOWN` | New, §8.4. Must exceed the time an attacker gains from forcing `WITHHELD`, without stranding an honest submitter whose case simply had bad luck |
| `FEE_BASE`, `FEE_PER_TOPIC` | Must clear gas for `TARGET_COHORT` voters — the binding constraint in every simulation so far |
| `SUPER_QUORUM` | §8.3 |
| `h` | Not a contract parameter at all — design-v3 O10. It decides whether §4.6's round halves the false-approval rate or nearly doubles it |
| `CHALLENGE_BOND` | Sizing only. §2.4 covers it in `liabilities()`, so no relation to `BOND_MIN` is required and I1 is structural again. It is the only constraint on who may register a challenge (§3.5), so it must price a frivolous challenge while staying low enough that a single-identity dissenter can afford one |
| `T` and registry size | §3.3 calibrates `T` so the expected cohort is `TARGET_COHORT`, which is a function of the active-moderator count — the quantity §3.6 says cannot be maintained on chain. Either `T` is static and cohort size grows with the registry, or P0-9 returns. `TARGET_COHORT` and `MIN_REVEALS` are both calibrated against it |
| Settlement cost vs `CLAIM_BOUNTY` | Commits per case are unbounded while the bounty is a fixed fraction of the fee. A case that becomes unprofitable to settle pins every participant's `openVoteCount` — I20 is only as strong as the incentive to make the call |
| Claim-key squatting | `submit` reserves a claim key (§4.3) with no check on who may claim it, so any content hash can be held for the price of a fee, repeatedly. The mirror of design-v3 O1: the key is simultaneously too tight against substitutes and too loose about who may take it |

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
