# Design v2 — Unassigned Moderation

**Status:** Design, revision **v2.1**. Nothing here is implemented.
**v2.1 changes:** voluntary risk units (§2.1, §5), a single final draw (§2.5),
`MAX_ROUNDS` 2 (§4.6). All three answer the external review — see
`specs/v2-audit-triage.md` and `specs/v2-audit-checklist.md`. The Solidity in `contracts/`
implements the first architecture (`specs/state-machine.md`); README §8 lists what
carries forward and what this replaces.

**Normative spec:** `specs/state-machine-v2.md` — the state machine, transitions
and invariants derived from this document.

**Scope:** the mechanism and its arithmetic. This document exists to get the
payout derivation right *before* any Solidity, because the previous milestone's
most expensive defects were formulas that looked correct, paid out wrong, and took
several review rounds to find. A normative state-machine specification follows
this document, not the other way round.

**Provenance:** the core moves — no obligation, self-selecting eligibility, serial
freezes, flat stake, cumulative tallies — came from the project's senior reviewer
in design discussion. The age-decaying eligibility threshold, the neutrality
theorem below, and the order-independent reputation update are this document's.
Section 10 attributes each item.

---

## 1. The problem this solves

Any system that **assigns** moderators to cases makes the assignment a resource,
and a resource can be exhausted. In the first architecture a case draws a panel and
the drawn moderators owe service; at the minimum stake and a five-seat panel, a
hundred moderators support twenty concurrent cases, and the hundred-and-first
submission queues. Opening cases is therefore a denial-of-service priced at the
fee.

Every mitigation inside that model — shorter locks, capacity pricing, higher fees —
raises the attacker's cost without removing the resource. Both external audits
reached the finding independently, one from static analysis of the duty lifecycle
and one from incentive design.

The fix is not a cheaper assignment. It is no assignment.

---

## 2. Mechanism

### 2.1 Identity and stake

One moderator, one stake of exactly `MIN_STAKE`, one vote. Stake above the minimum
confers nothing. Influence is bought by running more identities at linear cost —
the same capital cost as stake-weighting, without the bookkeeping, and with the
property that the moderator count is a real number the protocol can read.

**Voting spends a risk unit; submitting spends nothing (v2.1).** An identity holds
`K = stake / UNIT_STAKE` risk units, minimum one. Committing to a case reserves one
unit. Settlement returns it if the vote was coherent, freezes *that unit* if it was
not, and applies a short fixed freeze if the moderator committed and never revealed.

Read what this does and does not restore. **A submission still reserves nothing from
anybody** — the capacity attack that motivated this whole architecture stays dead,
because a thousand junk cases consume no unit belonging to anyone who did not choose
to vote. What comes back is a price on the *act of voting*, which an earlier draft
made free by removing per-case collateral along with the obligation. Only the
obligation caused the capacity attack; the collateral was removed with it by
accident, and that is the single most consequential finding of the external review.

Units buy **throughput, never weight**. `K` caps how many cases you can be voting in
at once; it has no effect on any single case, where one identity still casts exactly
one vote. Capital therefore buys concurrent work and cannot buy a louder voice —
which preserves the flat-vote property while pricing concurrency.

### 2.2 Eligibility

Moderator `m` may vote in round `r` of case `c` iff

```
H(m, c, r, seed(c))  <  T(c)
```

Checked off-chain by the moderator for free, verified on-chain when a vote
arrives. No enumeration, no panel assembly, no transaction.

```
T(c) = MAX_UINT / totalModerators × targetCohort × ageFactor(c)
```

`targetCohort` is the working value 32. `ageFactor` starts at 1 and grows each time
a round closes without reaching quorum, so a case nobody judges becomes eligible to
progressively more of the network. This replaces widening entirely: no re-draw, no
extra tranche, no call.

**Growth is per failed round, not per elapsed second (M2.5-F6).** An earlier draft
described it as a function of wall-clock age, which reads better and is wrong for
the machine: a threshold that moves continuously means a moderator's eligibility can
change between checking it off-chain and landing on-chain. Rounds pin their
threshold at open (`state-machine-v2` §3.3), and quorum failure is the
operational measure of "nobody judged this" — a case that is merely slow but has
its votes does not need a wider net.

`seed(c)` is `blockhash` of a block a few past submission, realized lazily by the
first vote and re-armed if it ages out of the 256-block window. Lazy realization is
what keeps selection at zero dedicated transactions; the future block is what stops
a submitter grinding the case id for a friendly cohort.

### 2.3 Voting

A fixed commit–reveal window per round. Every eligible moderator may vote for the
whole window; votes are counted regardless of arrival order.

The fixed window is not a convenience. If only the first *n* votes counted, an
attacker holding a minority of the cohort could decide cases by being fast, and
latency is the one advantage a funded attacker always has.

Not voting carries no penalty. There is no obligation, therefore no no-show.

### 2.4 Challenge

Within the challenge window, any moderator eligible for round `r+1` may open a
challenge, which **is** a public vote against the standing verdict. No bond, no
fee: the challenger's own stake carries the risk, and if the verdict survives they
are frozen like any other incoherent voter.

The challenger's direction is necessarily public — a challenge in agreement with
the verdict would be payout-farming, so only disagreement may open one, and the act
therefore discloses the vote. This is accepted rather than fixed. Hiding it is
impossible without also allowing agreeing challenges.

### 2.5 Tallying — pooled, not superseding

When a round closes, **every revealed vote from every round of the case is pooled
into one tally** and the verdict is drawn from the pool. Rounds do not replace one
another.

This is the load-bearing structural decision and §4.5 derives why.

Cohorts are the **same size** each round. Escalating cohorts would let the last
round dominate the pool, which reintroduces the property pooling exists to remove.

**One draw, at the end (v2.1).** Between rounds the contract publishes the running
*plurality* — a fact about the votes, not a verdict. The probabilistic draw happens
exactly once, after the last evidence round.

An earlier draft drew a fresh verdict at every round close, which quietly reopened
retry from a direction pooling does not cover. Pooling preserves the *votes*; it
does not stop anyone asking for another *sample* of them. With a draw per round the
stopping rule is asymmetric — lose the draw and challenge, win it and stop — so
`R` rounds approach `1 − (1−q)^R` for an attacker willing to keep going. Drawing
once removes the choice: a challenge buys more evidence, which is what a challenge
was always meant to be.

---

## 3. Notation

| Symbol | Meaning |
|---|---|
| `F` | submission fee |
| `β` | claim-bounty fraction |
| `P = F(1−β)` | the pot distributed to moderators |
| `R` | number of rounds held |
| `A`, `B` | pooled approve / reject votes across all rounds |
| `N = A+B` | total pooled votes |
| `v` | the drawn verdict |
| `W` | votes coherent with `v` (`A` if approve, `B` if reject) |
| `q` | fraction of the moderator population an attacker controls |

The verdict is drawn `P(v = Approve) = A/N`. Equivalently: **the verdict is one
pooled vote, selected uniformly at random.**

---

## 4. The payout derivation

### 4.1 The rule

The pot is split equally among voters coherent with the final verdict:

```
payout per coherent voter  =  P / W
incoherent voters          =  frozen (§5), paid nothing
```

Every coherent voter receives the same amount whether they voted in round 1 or
round 5.

### 4.2 Neutrality theorem

**Principle 4 requires that no moderator's expected payout depends on which way the
verdict goes.** Under the rule above this holds exactly.

A moderator who votes Approve is paid only if Approve wins, which happens with
probability `A/N`, and then receives `P/A`:

```
E[pay | vote = Approve]  =  (A/N) · (P/A)  =  P/N
E[pay | vote = Reject]   =  (B/N) · (P/B)  =  P/N
```

Both sides equal `P/N`. **A voter's expected payout is `P/N` regardless of
direction** — it depends only on the pot and the turnout, neither of which the
voter's choice controls.

This is not a coincidence of the split rule; it is the linear lottery cancelling the
linear divisor. It is also the property the first architecture spent four review
rounds recovering after a superficially reasonable divisor broke it, which is why it
is stated as a theorem here and must be re-checked against any future change to
either the lottery or the split.

**What it does not prove.** The theorem fixes the final tally `A, B, N` and asks
about cash. It is silent on everything the tally itself depends on: whether a vote
makes a challenge more likely, how many rounds run, what the final turnout becomes,
the reputation credit earned, and — most importantly — the suspension, whose length
scales with the *winner's* track record and is therefore **not** direction-neutral.

So `E[cash | fixed final tally]` is direction-independent, and
`E[total utility | Approve] = E[total utility | Reject]` does not follow. The
dynamic claim has to be established against a full strategy model of the challenge
game, not inferred from the static split. Any statement of principle 4 that omits
this qualification is an overclaim; see `specs/v2-audit-triage.md` F2 and D4.

### 4.3 Corollary — the lottery must be linear

The audit raised a *power lottery*, `P(Approve) = A^α / (A^α + B^α)` with `α > 1`,
to make strong consensus more likely to prevail while keeping minority outcomes
possible. Under equal splitting this is not available:

```
E[pay | Approve] = A^α/(A^α+B^α) · f(A)
E[pay | Reject]  = B^α/(A^α+B^α) · f(B)
```

Equality for all `A, B` requires `A^α f(A) = B^α f(B)`, hence `f(A) = c / A^α`.
The total paid to winners is then `A · f(A) = c / A^(α−1)`, which for `α > 1`
**varies with the margin**. A power lottery is therefore implementable only if the
moderators' total pay is allowed to depend on how lopsided the vote was, with the
remainder refunded or burned.

`α = 1` is the unique exponent for which neutrality and a constant pot coexist.
The linear lottery is not a stylistic choice; it is forced by the two properties we
are unwilling to give up.

### 4.4 Integer arithmetic

The contract has no rationals. With `pay = P / W` under floor division:

```
E[pay | Approve] = (A/N)·⌊P/A⌋      E[pay | Reject] = (B/N)·⌊P/B⌋
```

These differ by at most **one base unit** — neutrality holds exactly over the
rationals and to within one base unit under integer division. (An earlier draft
said `1/N`, which is wrong: the difference is `|(P mod B) − (P mod A)| / N`, and
since `P mod A < A`, that approaches 1 rather than `1/N`. Worst case observed in a
sweep: 0.95 base units, at `P=56, A=1, B=19`.) The remainder
`P − W·⌊P/W⌋` is credited to the **submitter's refund**, never to moderators.

That destination matters for principle 4. The remainder's *size* depends on `W`,
which depends on the verdict — so it is money whose existence depends on the
outcome, and it must not reach the people choosing the outcome. Routing it to the
fee payer keeps the constraint intact.

### 4.5 Why the tally must pool

Let an attacker control fraction `q` of the moderator population. Because
eligibility is a hash over identity, their expected share of any cohort is `q`, and
their expected share of the pooled tally is `q`.

**If each round superseded the last**, the verdict would be drawn from that round
alone, so `P(attacker verdict) ≈ q` per round, independently. Over `N` challenges:

```
P(at least one attacker verdict)  =  1 − (1−q)^N
```

At `q = 0.3`: four rounds give 76%, ten give 97%. A probabilistic defence would
degrade into a formality purchasable by persistence — the same "cheap repeated
attempts" pattern the second external audit identified as the most serious economic
finding in the first architecture.

**With a pooled tally**, the attacker's share of the pool stays `≈ q` no matter how
many rounds are held, so `P(attacker verdict) ≈ q` for the case as a whole, not per
round. The dice cannot be re-rolled. Additional rounds *reduce* variance around `q`
rather than granting fresh draws.

Two consequences fall out and both are desirable. A lopsided first round cannot be
overturned by one more cohort, while a near-tie flips easily — challenge power
tracks how genuinely contestable the verdict was. And the process self-terminates:
once the pool is lopsided, no single cohort can move it.

### 4.6 The dilution problem — and why a depth cap is still required

Pooling has a cost that must be stated. Since the pot is fixed at submission and
split among all coherent voters across all rounds, **each additional round dilutes
every voter's share**. Expected pay per voter is `P/N`, and `N` grows with every
round.

This is the termination mechanism — participation stops when the share drops below
gas — but it is asymmetric in a way that favours an attacker:

> An honest moderator's turnout is profit-motivated and therefore falls as the pot
> dilutes. An attacker's turnout is motivated by the listing, whose value is
> external to the protocol and unaffected by dilution. Forcing rounds therefore
> suppresses honest participation while leaving attacker participation intact.

The attacker cannot win outright by attrition, because votes already pooled do not
expire — the honest votes from round 1 remain in the tally forever. But they can
degrade the *marginal* rounds toward their own composition.

**Mitigation: a depth cap of two (v2.1).** Rounds are capped at `MAX_ROUNDS = 2`,
after which the pooled verdict is final.

Two, not four. The simulation measured the attacker's advantage against the cap and
found caps of 1–3 flat near `q`, cap 4 at 1.4× and cap 6 at 2.9× — **four rounds are
measurably worse for the honest side than allowing no challenge at all.** The
external review reached the same number from the optional-stopping argument. When a
measurement and a derivation agree on a parameter, that is the parameter.

Note what the cap now bounds. With a single draw at the end (§2.5) it no longer
limits re-rolls, because there are none; it limits how far the *composition* of the
pool can be dragged by rounds that honest moderators have stopped attending.

**This is an open parameter, not a settled one.** The interaction between the fee,
the dilution curve, gas cost and honest turnout is exactly what simulation must
resolve (§9).

---

## 5. Freeze composition

A vote that ends up incoherent freezes **the unit that backed it** — not the
moderator, and not the other units.

```
unit.frozenUntil = case.finalizedAt + FREEZE_BASE × min(FREEZE_CAP, trackFactor)
```

Each unit carries its own expiry, dated by the case that froze it. That is the whole
mechanism, and three earlier problems dissolve into it.

### 5.1 Why per-unit freezing is order-independent for free

The previous draft accumulated a single `suspendedUntil` on the identity:

```
until := min(finalizedAt + MAX_TOTAL, max(finalizedAt, until) + duration)
```

which is **not commutative**. Two seven-day penalties finalized at t=10 and t=5 give
24 days settled A-then-B and 19 days settled B-then-A, and settlement is
permissionless, so whoever pays gas first decides the punishment. Worse, the cap
anchored to `finalizedAt` could *shorten* a longer existing suspension — an old case
settling late could pull a moderator's expiry from day 500 back to day 365.

Per-unit expiry has nothing to accumulate. Each unit's date is a function of its own
case and nothing else, so settlement order cannot reach it. This is not a patch on
the formula; it is the formula becoming unnecessary.

### 5.2 Penalties still stack, and still do not dilute

Losing three cases freezes three units. The moderator's capacity drops by three for
the duration, which is the sum of three penalties, not the maximum of them. Serial
stacking — the property that made time the right punishment currency under
concurrency — survives, and now it survives without a non-commutative accumulator.

### 5.3 The risk/reward ratio, derived

This is what makes honest moderation rational, and the earlier drafts got the
statement wrong in two different ways.

A unit is occupied by a case for `D_case` days. Freezing that unit for `F` days
therefore costs exactly the cases *it* would have run in that window:

```
downside = (F / D_case) × pay_per_case
upside   =                pay_per_case
ratio    =  F / D_case
```

**`K` cancels.** A moderator's throughput is itself bounded by how many units they
hold, so holding more units raises both the cases foregone and the cases available
in the same proportion. The ratio depends on neither `K` nor the fee.

At `F = 7 days` and `D_case = 5 days` the ratio is **1.4**, so voting is rational
whenever confidence exceeds **58.3%**. An honest moderator's prior on a 95%-clear
case with 30% of the network hostile is **66.5%**. Honest participation is
rational **with the freeze term unchanged.**

Compare the identity-suspension version, where losing one case took *every* unit
out: the ratio was `F × cases_per_day` = 70, requiring 98.6% confidence, and no fee
level moved it because raising the fee raised the foregone earnings identically.
That is why the simulation found zero honest turnout at every fee it tested.

Two proposals are superseded by this derivation. This project's — cut `FREEZE_BASE`
to about an hour — was treating a symptom. The review's — divide the ratio by `K` —
has the right direction and the wrong statement, since it suggests large moderators
are safer than small ones when in fact the ratio is the same for everyone.

### 5.4 One pinned penalty start per case

Every unit frozen by a case derives its expiry from that case's `finalizedAt`, never
from the block in which a settlement batch happened to execute.

### 5.5 What a freeze is not

Frozen stake is never transferred and never destroyed. Principle 2 is unchanged and
unconditional: the moderator keeps every token, and loses only the use of that unit
for the term.

While a unit is frozen the moderator continues working with the rest. Votes already
cast stand, and cases already joined run to completion — the penalty removes future
capacity, never past judgment.

## 6. Reputation

Track record now carries three jobs, which promotes it from a reputational feature
to a security primitive:

1. it sets freezing power (§5);
2. it makes abandoning a frozen identity expensive, which is what stops identity
   churn from defeating the freeze;
3. it makes one well-regarded identity worth more than several anonymous ones,
   which is what makes flat stake safe against splitting.

Combined with a **stake maturation delay of at least `FREEZE_BASE`** — new stake
cannot vote until it matures — churn costs both the wait and the accumulated
standing. Neither mechanism suffices alone: maturation bounds the cost of churn from
below, reputation makes it grow with tenure.

### 6.1 The update must be order-independent

The first architecture's recurrence

```
T_next = d·T + credit
```

is **not commutative across concurrent cases**: settling case A before B yields
`T·d² + a·d + b`, and B before A yields `T·d² + b·d + a`. Settlement is
permissionless, so whoever pays gas first alters a moderator's future standing. The
second external audit found this and graded it a consensus-property wart. Under this
design, where reputation gates the freeze that deters everything, it is a security
defect.

**Fix: date each credit by its own case, not by the moment of settlement.**

```
T  :=  T · d^(e_now − e_last)  +  credit · d^(e_now − e_case)
e_last := e_now
```

where `e_case` is the epoch in which the case finalized and `e_now` the epoch of the
write. Each credit is discounted from its own case's epoch to the common present, so
the additions commute and the decay composes:

```
T = T₀·d^(now−e₀)  +  a·d^(now−e_A)  +  b·d^(now−e_B)
```

which is identical under either settlement order. Epochs are coarse (working value:
one day) to bound the exponentiation.

---

## 7. What survives from the first architecture

Carried forward substantially unchanged, and the reason each is worth keeping:

- **The permanent registries and the migration model.** Stake custody and the index
  outlive the replaceable game contract; the index survives logic replacement, and
  entries approved by a superseded logic remain removable through an id-addressed
  route. This is the part both audits called the architecture's main strength.
- **The probabilistic verdict**, and its `P(v) = votes(v)/total` form (§4.3 shows it
  is forced).
- **Commit–reveal with domain-separated commitments** bound to chain, contract,
  case, round and voter.
- **Settlement solvency ordering** — the pot is never over-committed, and rewards
  are external money only.
- **The index fields and the unopposed view** (`uncontested`, `fullQuorum`, the 96h
  seasoning), simplified because flat voting makes distinct votes distinct
  moderators by construction.
- **Deduplication held by the permanent index**, released only by the case that
  took it.
- **Governance**: immutable logic, bounded numeric parameters behind a timelock,
  withdrawals never pausable.

Deleted: the seat draw and sortition tree, the duty pool, `dutyUnits` /
`dutyReserved` / `dutyBonded` and their escrow, no-show penalties, per-case
obligation accounting, escalating panel targets, and bonded appeals.

---

## 8. Audit findings that survive the pivot

Most findings from both audits concerned the duty pool and obligation accounting,
which no longer exist. These do not depend on the architecture and carry forward:

| Finding | Status here |
|---|---|
| **Order-dependent reputation update** | Fixed by §6.1. Severity raised: reputation is now load-bearing. |
| **Per-batch freeze start timestamps** | Fixed by §5.1 — one pinned start per case. |
| **Cross-case retry of rejected content** | **Open.** Pooled tallies close retry *within* a case; a rejected case still releases its dedup reservation, so identical content can buy a fresh lottery at base fee. Persisting per-content review history in the permanent index is the likely answer and is not yet designed (§9). |
| **Unbounded `claim(caseId)` overload** | Not inherited — settlement is redesigned; the bounded form is the only form. |
| **Zero-topic sentinel, mutual bind, timelock floor, removal granularity** | Carried forward as-is; they concern the permanent registries, which survive. |
| **Proposer influence on randomness** | Unchanged and still accepted. The prize is the listing, which no pot cap bounds — see README §3.7. |

---

## 9. Open questions, with owners

> **First simulation results are in — `simulation/v2/FINDINGS-v2.md`.** Three of
> these questions now have measurements against them, and two of the answers
> contradict what this document assumed. `FREEZE_BASE` at 7 days makes honest
> moderation irrational at *any* fee (the ratio is fee-invariant); `MAX_ROUNDS` at
> 4 is measurably worse for the honest side than 1; and §4.6's dilution is not
> merely a cost to bound but a composition attack that lifts the attacker's
> verdict rate to 1.9× their population share at q=0.4. Question 7 below is new
> and is a decision, not a measurement.

An open question here names who can answer it and what an answer looks like. It is
not a topic.

| # | Question | Owner | Answered when |
|---|---|---|---|
| 1 | **Reputation weight.** How strongly track record gates earnings and freezing power. Carries three jobs (§6); too weak and the freeze stops deterring, too strong and the network ossifies. | Simulation, decided by the project owner | There is a curve, validated against churn and farming scenarios |
| 2 | **Fee level.** Sets equilibrium turnout, since each voter dilutes the rest. Paying ~32 voters above gas is roughly 6× the first architecture's 1.5 xBZZ. | Simulation | Turnout stabilises near `targetCohort` at plausible gas prices |
| 3 | **`MAX_ROUNDS` and the dilution curve** (§4.6). Interacts with 2. | Simulation | Honest turnout in the final round is still above gas cost |
| 4 | **Removal supply.** Charging the requester is neutral and unspammable but leaves removals undersupplied. Does removal need a paid *role* rather than a price, and where does that pool come from without becoming farmable? | Project owner + senior reviewer | A mechanism, or an explicit decision to ship the limitation |
| 5 | **Cross-case retry** (§8). Per-content history in the permanent index — attempt counts, cooldowns, escalating fees for unchanged content. | Design | Specified and shown not to create a new farmable target |
| 7 | **The neutrality trilemma.** Neutral payouts force `f(W) = c/W`, so the total paid is constant and dilution is unavoidable while challenges are free. Neutral payouts, free challenges, non-diluting pay — pick two. | Project owner + senior reviewer | A row of the table in FINDINGS-v2 §D is chosen, with the §C numbers in front of it |
| 8 | **`UNIT_STAKE`** (v2.1). Sets how many risk units a given stake buys, and therefore network throughput: `N` moderators at `K` units each support `N·K/turnout` concurrent cases. At `MIN_STAKE` 10 and `UNIT_STAKE` 1, a hundred minimum moderators support roughly 45 concurrent cases — more than the assigned design's 20, while pricing every vote. It does **not** affect the risk/reward ratio (§5.3), which is why it is a throughput dial rather than a safety one | Simulation | Throughput at plausible network sizes clears expected demand |
| 6 | **`ageFactor` growth rate** (§2.2). Too slow and quiet cases stall; too fast and the cohort loses its randomness advantage. | Simulation | A rate with a bound on worst-case time-to-quorum |

---

## 10. Attribution

- **No obligation; self-selecting eligibility by hash; serial freeze stacking; flat
  stake with one vote per identity; fixed voting window open to all eligible;
  challenge as a stake-backed public vote; pooled tallies across rounds** — the
  project's senior reviewer, in design discussion.
- **Age-decaying eligibility threshold replacing widening; the neutrality theorem
  and the linearity corollary (§4.2–4.3); order-independent reputation (§6.1); the
  dilution analysis and depth cap (§4.6); equal cohort sizes under pooling** — this
  document.
- **The capacity finding that prompted the redesign** — reached independently by
  both external audits and by the senior reviewer.
