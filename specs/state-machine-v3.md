# Moderation Contract v3 — Formal State-Machine Specification

**Milestone:** M3.0
**Status:** Specification, revision **v3.4**. Not implemented.
Revision history is the commit log; the marker exists so a reader can tell which
`design-v3` revision this file was last reconciled against (v3.3).
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
rewritten            Moderation, Settlement                        ~2,690 lines
survives with edits  StakeRegistry, IndexRegistry, RulesetGovernor,
                     ProtocolLimits                                ~2,400 lines
```

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
- **Time** is block timestamps (seconds).
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
| `EXIT_COOLDOWN` | 7 d | Delay between exit request and withdrawal. |
| `TARGET_COHORT` | 40 | Expected eligible moderators per round. |
| `MIN_COMMITS` | 16 | Commits required at commit close, or the case ends `UNRESOLVED(NO_TURNOUT)` (§4.8). **This is the quorum gate** — decided before anyone can see a tally. |
| ~~`MIN_REVEALS`~~ | — | **Removed, §4.8.** It was a terminal-class gate on observable state, and it was the only thing that ever made withholding attractive. The draw needs `N ≥ 1`, which is arithmetic, not policy. |
| ~~`MIN_CHALLENGE_REVEALS`~~ | — | **Removed, §4.6.** §4.5's single-randomness rule makes an unchanged tally yield an identical verdict, so the floor has no job. |
| `SUPER_QUORUM` | *(open)* | Reveals required for the strict assurance class (§8.3). |
| `RETRY_COOLDOWN` | *(open — §10)* | Delay before a claim that ended `UNRESOLVED(NO_REVEALS)` may be resubmitted (§8.4). **`NO_RANDOMNESS` no longer uses it** — that row does not retry at all (I26). |
| `COMMIT_WINDOW` | 20 min | Per round. |
| `REVEAL_WINDOW` | 20 min | Per round. |
| ~~`FINALIZATION_GRACE`~~ | — | **Removed.** It named a deadline no transition established. The real one is `outcomeSeedBlock + BLOCKHASH_HORIZON` (§4.4), which `BLOCKHASH_HORIZON` already gives. |
| `CHALLENGE_WINDOW` | 12 h | From publication of the round-0 plurality (`TALLY`). |
| `SEED_LAG` | 2 blocks | Between arming and realizing a seed. |
| `BLOCKHASH_HORIZON` | 256 blocks | How long `blockhash` remains readable. **Chain-dependent in blocks and in wall time** — 256 blocks is ~51 min at 12 s and ~21 min at 5 s. §7.3's rarity argument scales with it, so it is named rather than assumed. |
| `LATE_WIDEN_AT` | minute 12 of commit | Eligibility widening trigger (§3.3). |
| `LATE_WIDEN_FACTOR` | 1.5× | Threshold multiplier at widening. |
| `DRAW_BOUNTY` | 0.5 % of fee | Paid to whoever pokes the draw, or its expiry (§4.3). Separate from `CLAIM_BOUNTY` because the draw, not finalization, is the transition with a hard expiry (§7.3, F16). **It is a convenience, not the reason the poke happens** — §7.3 makes poking dominant for the plurality-losing side at any bounty, including zero. |
| `CLAIM_BOUNTY` | 1 % of fee | Paid to whoever triggers finalization. |
| `MAX_TOPICS` | 5 | Topics per submission. |
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
    uint128 liabilities;     // ACCRUED, not recomputed — §2.4. Incremented by the
                             //   case's own coefficients at commit/challenge and
                             //   decremented by the same amounts at settlement
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
commit    on case c:  m.liabilities += LAMBDA(c)         ; openVoteCount++
challenge on case c:  m.liabilities += CHALLENGE_BOND(c) ; openChallenges++
settle    on case c:  m.liabilities -= the amount that case added

mayCommit(m)     iff  ACTIVE and bond ≥ BOND_MIN + m.liabilities + LAMBDA(c)
mayChallenge(m)  iff  ACTIVE and bond ≥ BOND_MIN + m.liabilities + CHALLENGE_BOND(c)
withdraw(m)      iff  cooldown elapsed and m.liabilities == 0
```

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
    bool    unanimousDraw;     // were all three tickets the same side? §8.3
                               //   reads this; nothing reads `u` back, because
                               //   §4.5 realizes and uses it in one transaction
    Outcome plurality;         // which side led at round-0 close; a FACT, and
                               //   no randomness has been realized when it is set.
                               //   Total on any tally, ties included — §4.2
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
COMMIT ──▶ REVEAL ──▶ TALLY ──┤                                          ▼
                       │      └── window closes, no challenge ──▶ … ──▶ DRAW ──▶ FINALIZED
                       │                     COMMIT₁ ──▶ REVEAL₁ ──▶ ┘             │
                       │                                                           │
                       └── no commits / no reveals ──▶ UNRESOLVED ─────┬───────────┘
                           or outcome seed expired                     ▼
                                                                    SETTLED
```

**Both terminals discharge.** `UNRESOLVED` reaches `SETTLED` too — it releases
escrows and liabilities without writing a verdict (§4.8). It is not a leaf.

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
| — | `COMMIT` | `submit(...)` | charge fee; split into pot / reserve / bounty / maintenance; reserve dedup keys (§8.4); pin ruleset and guidelines versions; `round = 0`; arm both seeds (§7); `phaseDeadline = now + COMMIT_WINDOW`. **No moderator is selected, reserved, or notified on chain.** |
| `COMMIT` **(r=0)** | `REVEAL` | `now ≥ phaseDeadline` and `commitsThisRound ≥ MIN_COMMITS` | `phaseDeadline = now + REVEAL_WINDOW` |
| `COMMIT` **(r=0)** | `UNRESOLVED` | `now ≥ phaseDeadline` and `commitsThisRound < MIN_COMMITS` | **`terminal = UNRESOLVED`**; `unresolvedReason = NO_TURNOUT`. Nobody could have steered this — see §4.8 |
| `COMMIT` **(r=1)** | `REVEAL` | `now ≥ phaseDeadline` | `phaseDeadline = now + REVEAL_WINDOW`. **No quorum gate in round 1** — §4.9 |
| `REVEAL` **(r=0)** | `TALLY` | `now ≥ phaseDeadline` and `pooled ≥ 1` | pool this round's reveals; publish the **plurality** (§8.2) — a fact, not a verdict; `reveals0 = revealsThisRound`; `phaseDeadline = now + CHALLENGE_WINDOW` |
| `REVEAL` **(r=0)** | `UNRESOLVED` | `now ≥ phaseDeadline` and `pooled == 0` | **`terminal = UNRESOLVED`**; `unresolvedReason = NO_REVEALS`. Not a policy gate — there is no tally to draw from — but **steerable**, see §4.8 |
| `TALLY` | `TALLY` | `challenge()` (§3.5): `mayChallenge(caller)` (§2.4), `now < phaseDeadline`, `challenger == 0` | **registers only.** `challenger = msg.sender`; `openChallenges++`. Nothing is transferred — the bond is *covered*, not escrowed (§2.4). No phase change, no seed armed, no deadline moved. A second call reverts (I17) |
| `TALLY` | `COMMIT` | `now ≥ phaseDeadline` and `challenger != 0` | `round = 1`; **`revealsThisRound = 0`; `commitsThisRound = 0`**; arm the round-1 **eligibility** seed from this scheduled close (§3.5b, §7.1); `phaseDeadline = now + COMMIT_WINDOW`. **`challengeReserve` is not touched** — it activates at settlement, in proportion to round-1 reveals (§5.3), so opening a round moves no value |
| `TALLY` | `DRAW` | `now ≥ phaseDeadline` and `challenger == 0` | enter the waiting state. **Nothing is enabled in `DRAW` until `block.number > outcomeSeedBlock`** (§7.2) — on this path that is ~40 minutes away, because the seed block includes the round-1 windows whether or not round 1 runs |
| `REVEAL` **(r=1)** | `DRAW` | `now ≥ phaseDeadline` | pool round-1 reveals. **No threshold** (§4.6), and none needed (§4.9) |
| `DRAW` | `FINALIZED` | `outcomeSeedBlock < block.number ≤ outcomeSeedBlock + BLOCKHASH_HORIZON` | realize `u[0..2]` and evaluate `verdict` against the **pooled** tally (§4.5) — **the only draw in the claim's life**; **`terminal = APPROVED | REJECTED`**; store `unanimousDraw`; pay `DRAW_BOUNTY`; `finalizedAt = now`. `CHALLENGE_BOND(c)` and the reserve activation both settle at `SETTLED`, with every other liability (§4.6, §5.3) |
| `DRAW` | `UNRESOLVED` | `block.number > outcomeSeedBlock + BLOCKHASH_HORIZON` | **`terminal = UNRESOLVED`**; `unresolvedReason = NO_RANDOMNESS`; pay `DRAW_BOUNTY` to the caller. **The pooled tally survives into settlement** — this is the one `UNRESOLVED` row that leaves one behind, and §4.8 settles every tally-derived obligation against it |
| `FINALIZED` | `SETTLED` | `claim()` batches complete | §5, §8 |
| **`UNRESOLVED`** | **`SETTLED`** | **`claim()` batches complete** | **§4.8 — discharge. Debit every non-revealer `REVEAL_BOND` (I25); decrement `openVoteCount`, `openChallenges` and `m.liabilities` by what each case added (§2.4); refund per §4.8. No verdict is written, so nothing is paid, no listing appears, no reputation is credited and `challengeReserve` does not activate — all four read the verdict. `CHALLENGE_BOND(c)` is debited wherever one was registered, on no condition. The *tally*-derived incoherence debit applies iff a tally exists, which is `NO_RANDOMNESS` and nothing else (§4.8, I30). Nothing is "returned" — `REVEAL_BOND` was covered, never escrowed (§5.2)** |

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
| `commit(c, h)` | phase is `COMMIT`; `now < phaseDeadline`; caller eligible (§3.1); **caller has not committed to `c` in any round** (§3.4, I3); `mayCommit` (§2.4) | store `h`; `commitsThisRound++`; `openVoteCount++`; `m.liabilities += LAMBDA(c)` |
| `reveal(c, v, salt)` | phase is `REVEAL`; `now < phaseDeadline`; `h == H(…, v, salt)` binding chainId, contract, `c`, round, `paramsVersion` and the caller | pool `v`; `revealsThisRound++` |
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

Each phase ends at `phaseDeadline`, a timestamp fixed when the phase opened.

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
that rate under a uniform prior — the add-one estimator — which is the quantity `f`
was always meant to receive. Three things follow.

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
safe content with no attacker rises by 0.4 to 2.1 points depending on `prior`; the
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
  *eligibility* seed only. `NO_RANDOMNESS` is therefore reachable at `DRAW` and
  nowhere else — one place, not "the round-0 draw", since there is only one draw
  (§7.1) — and the 256-block `blockhash` horizon never has to span the 12-hour
  challenge window.
- **`u` need not be stored.** An earlier revision realized it at round-0 close and
  had to keep it for twelve hours; with the draw last, realization and use are one
  transaction. Only §8.3's `unanimousDraw` flag survives into storage, because that
  is the one thing read back.
- **Nothing about `u` is knowable while anyone is still voting.** `u` is realized
  at `DRAW`, after every reveal in both rounds. An earlier revision realized it at
  round-0 close and published it, which reduced the whole mechanism to one public
  threshold `m = median(u)/2^128` with `verdict = (a > m)`: the exact flip cost was
  computable twelve hours before the challenge decision, so a challenger read the
  price instead of facing a lottery. Deferring the draw removes that channel rather
  than pricing it.

**With replacement is still required**, and now trivially: `u[0..2]` are
independent, so a side holding one revealed vote keeps `f(1/32) = 0.287%`. Without
independence a 31–1 tally would decide with certainty, contradicting I12.

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
bond. It runs at `SETTLED` alongside every other debit, so it inherits §5.1's
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
| `NO_RANDOMNESS` | the fixed outcome seed expired unread (§7.3) | **no** — and by nobody who could gain: the debits below make poking dominant for the plurality-losing revealers, and §8.4's reservation makes it dominant for the submitter on *either* plurality | **no retry.** The claim carries `REJECTED`'s reservation by reference (§8.4, I26); the pot is refunded less maintenance |

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
13A/7R                        0.7183             0.6928
10A/10R                       0.5000             0.4606
 6A/14R                       0.2160             0.1713
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

**A terminal settles every obligation whose input it has, and only those** (I30).
Sort this specification's obligations by what they read:

```
from NOTHING       CHALLENGE_BOND       debited on every terminal reachable
                                        from TALLY, on no condition   (§4.6)

from the TALLY     non-reveal debit     a commit that was never opened
                   incoherence debit    a vote against the leading side
                   reserve activation   reveals1 / reveals0           (§5.3)
                   the claim key        has this content been judged  (§8.4, I26)

from the VERDICT   payment (§5.3)       who was coherent with the drawn outcome
                   listing status       APPROVED / REJECTED           (§8.2)
                   reputation (§6)
```

`NO_TURNOUT` and `NO_REVEALS` have no tally — one never opened a reveal phase, the
other closed with `pooled == 0` — so only the first group applies, minus the key,
which I26 attaches to having been tallied. `NO_RANDOMNESS` has a **complete pooled
tally and is missing nothing but `u`**, so every tally-derived obligation settles
there exactly as it would have on the finalized path, the claim key included.

The verdict-derived column stays empty in all three. **The index still gets an
entry** — §8.2's `UNRESOLVED` is a status value, not an absence, and a reader must
be able to tell "judged, undrawn" from "never submitted"; what none of the three
writes is a *listing*. Revealers are paid nothing in any `UNRESOLVED`; what changed
is that in `NO_RANDOMNESS` they no longer *lose* nothing either.

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

**Value flow, stated exactly.** `challengeReserve` is escrowed throughout and
activates only at settlement, in proportion to round-1 reveals (§5.3). No terminal
here draws a verdict, so nothing is paid, so nothing activates:

```
every reason      ->  refund pot + challengeReserve in full

every reason      ->  debit every non-revealer REVEAL_BOND(c)  (I25)
                      nothing is RETURNED — the bond was covered, never
                      escrowed (§5.2), so there is nothing to give back
                      pay nobody, list nothing, credit no reputation; the
                      index entry is written as UNRESOLVED (§8.2)
                      decrement openVoteCount, openChallenges and
                      m.liabilities by what this case added   (§2.4, I20)
                      retain finalizationBounty and maintenance

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

At `SETTLED`, for every revealed vote in either round:

```
coherent with verdict     -> bond += share           (§5.3)
incoherent with verdict   -> bond -= d(c)            -> maintenance reserve
committed, never revealed -> bond -= REVEAL_BOND(c)  -> maintenance reserve (§5.2)
```

**Where there is no verdict, the coherence test reads the pooled plurality
instead** — `UNRESOLVED(NO_RANDOMNESS)` and nowhere else, because it is the only
terminal that holds a complete tally and never drew from it (§4.8, I30):

```
on the plurality's winning side  -> nothing; no payment exists to earn
on the losing side               -> bond -= d(c)     -> maintenance reserve
```

The substitution is confined to that one terminal by construction: everywhere else
either a verdict exists, in which case it is the input, or no tally exists, in
which case neither test has one. **`d(c)` is the same coefficient either way** —
this is not a second penalty with its own parameter, it is the same penalty reading
the best fact the terminal has.

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
activated = min( challengeReserve , floor(pot · reveals1 / reveals0) )
P         = pot + activated
W         = votes matching `verdict`, from either round
share     = floor(P / W)
remainder = P − share · W                 -> maintenance reserve, never to moderators
challengeReserve − activated              -> refunded to the submitter
```

`reveals0 ≥ 1` is guaranteed by the `REVEAL(r=0) → TALLY` guard, so the division is
total. Both counts are **tally facts, fixed at reveal close and independent of the
verdict** — the reserve must not become a second quantity a party can steer by
choosing an outcome (I30).

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

**The implementation must not clamp.** A `bond -= d(c)` that would underflow indicates
a broken invariant, not a case to handle gracefully, and clamping would hide it.
Revert, and treat it as I1 having failed.

A moderator whose bond falls below `BOND_MIN + m.liabilities` after debits is
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
| `outcomeSeedBlock` | **per claim** | the schedule in §7.2 — submission plus **all four** windows | §4.5 — realized once at `DRAW` |

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
outcomeSeedBlock = blockAt( submitTime
                          + COMMIT_WINDOW + REVEAL_WINDOW      // round 0
                          + CHALLENGE_WINDOW
                          + COMMIT_WINDOW + REVEAL_WINDOW )    // round 1, always
                   + SEED_LAG
```

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
the same in states the guard is meant to separate. Disjointness (I18) does not
catch this — the two `DRAW` guards *are* disjoint under the correct reading; the
defect was one guard being true in a state its own justification does not
describe.

Re-arming lets a party inspect whether a seed is favourable, use it when it is, and
let it expire when it is not — a free option over outcomes. The one-hour round
lifecycle makes expiry rare: `blockhash` is available for 256 blocks (~51 minutes)
and the case's hard deadline is `outcomeSeedBlock + BLOCKHASH_HORIZON` — the last
block at which the seed can still be read (§4.4).

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

> **Claim.** For every reachable non-empty tally, at least one revealer strictly
> prefers poking the draw to letting the seed expire — and that preference does not
> depend on the value of `d`, of `share`, or of `DRAW_BOUNTY`.
>
> *Proof.* Take any revealer on the losing side of the pooled plurality; one exists
> unless the tally is unanimous. Let `a` be their own side's share of it, so
> `0 < a ≤ 0.5`. §4.8 debits them `d` if the seed expires. The draw debits them `d`
> only in the branch where their side loses it, and pays `share` in the other:
>
> ```
> expire         :  −d
> draw           :  f(a)·share  −  (1 − f(a))·d
> draw − expire  :  f(a)·(share + d)   >  0        for every a > 0
> ```
>
> The `d` terms cancel — it is charged in one branch and risked in the other — and
> what remains is a chance of being paid that only the draw supplies. If the tally
> is unanimous, every revealer is on the winning side, faces no debit in either
> branch, and the draw pays `share > 0`. ∎

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

**And the submitter pokes too.** §8.4 holds the claim key on `REJECTED`'s terms
when the seed expires, so the submitter's comparison is `f(a)` against zero on
*either* plurality — every draw has an approval branch and expiry has none. They
are the second mobilized party, they are guaranteed to exist, and unlike a
moderator they are certainly watching the case they paid for. The claim above needs
only one party; it has two, arriving from opposite directions.

`DRAW_BOUNTY` survives as funding for the expiry transition itself and as a
convenience for third-party bots. **No invariant rests on its size**, which is the
difference between this rule and the one it replaced.

---

## 8. Index effects

### 8.1 Finality is independent of payout

At `FINALIZED` — **not** at `SETTLED` — the index is written in bounded
`O(MAX_TOPICS)` work, and `share` is fixed.

Moderator accounting (`claim()`, reputation, debits) happens afterwards and may be
batched. **A reader must never wait for moderator payouts to see a result.** v2
wrote the index at `SETTLED` and so coupled the two.

### 8.2 Interim status is a value, not an absence

**Decision.** `IndexRegistry` carries status as a distinct value:

```
PLURALITY_APPROVE | PLURALITY_REJECT | APPROVED | REJECTED | UNRESOLVED
```

The alternative — withhold the entry until `FINALIZED` — was rejected because it
throws away the one-hour answer that the whole architecture is built to produce,
and because a reader cannot distinguish "not yet decided" from "never submitted".

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
`N = 16`. The clause now does what it says: it separates a unanimous cohort that
the draw confirmed from one it merely did not overrule.

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
permanence. `REJECTED`'s permanence rests on design-v3 §8's 0.725% false-rejection
figure, which `simulation/v3/FINDINGS-v3.md` §F locates as requiring `prior ≈ 0.96`,
`rho ≈ 0` and `q = 0` simultaneously, and measures at 26–60% instead. That
re-examination is open (§10). Writing this row as a reference means it moves when
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
| **I5** | **Exactly one randomness draw exists per claim, and it is the last transition before `FINALIZED`.** No randomness is realized or published while any vote can still be cast |
| **I6** | No payment, debit or reputation credit occurs before a **terminal** state. Not "before `FINALIZED`" — `UNRESOLVED` never reaches `FINALIZED`, and I25 requires the non-reveal debit there |
| **I7** | Both seeds of every round derive from schedules fixed at submission, and are independent of every transaction's timing — including the timing of `challenge()` (§3.5b) |
| **I8** | Penalties are invariant under settlement permutation |
| **I9** | The cost of one incoherent vote is independent of `openVoteCount` |
| **I10** | No phase closes before its `phaseDeadline` |
| **I11** | **No verdict is more confident than the tally it was drawn from.** `P(Approve) = f(â)` with `â = (A+1)/(N+2)` (§4.5), so at `N` reveals neither outcome exceeds `f((N+1)/(N+2))` — 0.89% short of certainty at `N = 16`, 0.17% at `N = 40`. The old form, *"under-quorum can produce `UNRESOLVED` but never `APPROVED`"*, is the `N = 0` case of this and was vacuous for every other: "quorum" has meant the **commit** gate since §4.8 moved it there, so a case could clear it and reach `APPROVED` on one revealed vote with certainty |
| **I12** | No tally admits a risk-free outcome: **both** outcomes have non-zero probability at every reachable tally, **at the moment every party's last decision is made**. Not *"every side with ≥ 1 revealed vote"* — that quantifier excludes the side with none, so it was vacuously true at exactly the unanimous tally where a party controlling every reveal bought certainty. `â ∈ (0,1)` for every finite `N` (§4.5) is what makes the corrected form true. Every revealed vote in either round is counted in the tally the verdict is evaluated against, and no randomness is public before the last vote is cast — a published `u` makes the outcome a step function of the tally and this invariant false for round 1 |
| **I13** | `withdraw` implies `liabilities(m) == 0` — *every* outstanding claim discharged, not only open votes |
| **I14** | No moderator's loss is another moderator's gain. This covers value **removed from `bond`**, value **withheld from a payment**, and any change to a divisor that raises someone else's share — the three are the same transfer written three ways |
| **I15** | The index status at `FINALIZED` does not change as settlement batches proceed |
| **I16** | Every state predicate in §2.2 and §4.2 is mutually exclusive |
| **I17** | At most one challenge round exists per claim |
| **I18** | The guards of §4.3 are pairwise disjoint: in every reachable state **at most one** row is enabled. Not "exactly one" — no row is enabled in `COMMIT`, `REVEAL` or `DRAW` before the relevant deadline or block, including the interval between reveal close and `outcomeSeedBlock` |
| **I19** | Every field of §4.1 is written or provably preserved by every transition. No field is implicitly carried across a round boundary |
| **I20** | Every terminal state discharges every liability it created: `openVoteCount` returns to its pre-commit value and every escrow is released, within a bounded number of permissionless calls |
| **I21** | Every value the specification moves — removed from `bond`, withheld from a payment, or left over from integer division — has a named destination in this document, and that destination is never another moderator |
| **I22** | The verdict is monotone in `a` for fixed `u`: adding votes to one side can move the verdict only toward that side, never away from it |
| **I23** | `m.liabilities` is the single point of truth for claims on `bond`. Adding any debit to this specification means accruing it there; no test may use a narrower expression |
| **I24** | No party can change a case's terminal *class* in a direction favourable to them by anything they do **or decline to do** after the tally becomes observable. The only quorum gate is on commits, which are blind; the residual `N ≥ 1` requirement is arithmetic, and forcing it means withdrawing all of one's own votes; and the one class reachable by pure inaction, `NO_RANDOMNESS`, is priced so that at every tally some revealer strictly prefers the draw (§7.3) **and the submitter always does** (§8.4). **"Action" was the loophole**: an earlier revision satisfied this clause for things done and left things left undone to the size of `DRAW_BOUNTY`, which is a parameter, not an invariant |
| **I25** | The non-reveal debit is applied in every terminal state, including those in which no verdict was drawn |
| **I26** | Once a claim has been tallied, no reachable terminal releases that claim's key. Monotone in "voting has happened" — the draw is last, so keying it to the draw would exclude every pre-draw terminal. **§8.4's `NO_RANDOMNESS` row contradicted this** by reserving for `RETRY_COOLDOWN` and then releasing: that terminal is tallied by definition. The invariant was right and the row was wrong, which is the second time in this section a correctly-stated property was contradicted by a table written without consulting it |
| **I27** | Every debit is computed with the parameter values pinned into its case at submission. No claim's cost is a function of a parameter changed after the claim was created |
| **I28** | Withholding a reveal is never favourable **to a party that wants a side to win**: it forfeits `REVEAL_BOND(c)` and strictly lowers that side's probability. It says nothing about a party playing for a *terminal class* rather than a verdict — a censor holding every commit can still reach `NO_REVEALS`, which is why §4.8 reserves the claim there rather than relying on this |
| **I29** | No guard is expressed as an observation whose value is the same in states the guard must separate, and no parameter's value is written outside §1. Disjointness (I18) is necessary and not sufficient: a guard can be uniquely enabled and still be enabled in a state its justification does not describe |
| **I30** | A terminal state settles every obligation whose **inputs exist in that state**, and only those. `CHALLENGE_BOND` reads **nothing** and settles everywhere past `TALLY`; the non-reveal debit, the incoherence debit and the reserve activation read the **tally**; payment, the listing status and the reputation credit read the **verdict**. A terminal holding a tally and no verdict settles the first two groups and not the third. I25 is this rule's instance for the non-reveal debit; §4.8's `NO_RANDOMNESS` row is what forced the general statement. **An obligation's group is a design choice, not a discovery** — H7 moved `CHALLENGE_BOND` from the tally group to the empty one, because every tally-derived test available to it was one the challenger could evaluate before registering |

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
| `RETRY_COOLDOWN` | §8.4, and **now for `NO_REVEALS` alone.** It has lost both of its earlier jobs rather than been tuned for them: poke-refusal went to §7.3's debit, and the submitter's escape went to I26's reservation. What it still prices is the party who holds every commit on a case and withholds them all — a delay long enough that reaching `NO_REVEALS` deliberately is not worth the `REVEAL_BOND` it costs. **One knob, one attacker, for the first time in this document** |
| Permanence of `REJECTED` | §8.4. It rests on design-v3 §8's false-rejection figure, which was **0.725% and is now 1.97%** — §4.5's estimator nearly tripled it from arithmetic alone, before any assumption is questioned. `simulation/v3/FINDINGS-v3.md` §F then locates even that as requiring `prior ≈ 0.96`, `rho ≈ 0` and `q = 0` **simultaneously**, measuring 26–60% instead across the plausible range. Two of the three are unmeasured and the third is assumed away elsewhere in the document. `UNRESOLVED(NO_RANDOMNESS)` now carries this row *by reference*, so whatever re-examination concludes moves both together. **Blocked on the honest-accuracy measurement, not on a parameter sweep** |
| `FEE_BASE`, `FEE_PER_TOPIC` | Must clear gas for `TARGET_COHORT` voters — the binding constraint in every simulation so far |
| `SUPER_QUORUM` | §8.3 |
| `h` | Not a contract parameter at all — design-v3 O10. It decides whether §4.6's round halves the false-approval rate or nearly doubles it |
| `CHALLENGE_BOND` | Sizing only, and **one job now that §4.6 made it unconditional**. It used to have to price a frivolous challenge *and* stay affordable for a single-identity dissenter — two requirements pulling opposite ways on one knob, and the conditional forfeit made the effective price differ between the two parties in the wrong direction. Unconditional, both parties face the same number, so it is a single question: what are twelve hours of the submitter's latency and one round of cohort attention worth? §2.4 covers it in `liabilities()`, so no relation to `BOND_MIN` is required and it needs none to the reserve either — §5.3 removed that coupling |
| `T` and registry size | §3.3 calibrates `T` so the expected cohort is `TARGET_COHORT`, which needs the active-moderator count — the quantity §3.6 says cannot be maintained on chain. **Measured** (`simulation/v3/FINDINGS-v3.md` §D): with `T` calibrated for 1,000, a registry of 250 gives an expected cohort of 10 against `MIN_COMMITS` 16 and **92% of cases end `UNRESOLVED(NO_TURNOUT)`**. That is the launch condition. Above the calibration size composition is stable but per-voter pay falls linearly while gas does not. Too small is a liveness failure, too large an economic one; neither is a safety failure |
| **Honest accuracy** | **The binding constraint, and it is not in this document.** `simulation/v3/FINDINGS-v3.md` shows that with *zero* attackers a 66.5% honest prior approves 30% of unsafe content, because an honest error is indistinguishable from a hostile vote and enters the verdict through the same term. Every safety figure written as a function of `x` is really a function of `q + (1−q)(1−prior)`. At `prior = 0.95` the same figure is 1%. Measuring `prior` on real content dominates every other open parameter here |
| Settlement cost vs `CLAIM_BOUNTY` | Commits per case are unbounded while the bounty is a fixed fraction of the fee. A case that becomes unprofitable to settle pins every participant's `openVoteCount` — I20 is only as strong as the incentive to make the call |
| Claim-key squatting | `submit` reserves a claim key (§4.3) with no check on who may claim it, so any content hash can be held for the price of a fee, repeatedly. The mirror of design-v3 O1: the key is simultaneously too tight against substitutes and too loose about who may take it |

**Inherited code (§Scope):**

- `StakeRegistry` — survives; loses the sortition tree and gains `bond` and
  `openVoteCount`.
- `IndexRegistry` — survives; gains the plurality statuses of §8.2.
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
