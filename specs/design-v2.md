# Design v2 — Unassigned Moderation

**Status:** Design. Nothing here is implemented. The Solidity in `contracts/`
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

A stake is not partitioned across cases. It backs every case its holder votes in,
simultaneously and without limit. **There is no per-case collateral, no duty pool,
and no reservation of any kind.**

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

`targetCohort` is the working value 32. `ageFactor` starts at 1 and grows slowly
with the age of an unresolved case, so a case nobody judges becomes eligible to
progressively more of the network. This replaces widening entirely: no re-draw, no
extra tranche, no call.

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

These differ by at most `1/N` base units — neutrality holds exactly over the
rationals and to within one base unit under integer division. The remainder
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

**Mitigation: a depth cap.** Rounds are capped at `MAX_ROUNDS` (working value 4),
after which the pooled verdict is final. This bounds both the dilution and the
attacker's opportunity to force it. A cap is cruder than a dynamic rule and it is
what the first architecture used; the alternative — an escalating cost to open each
successive challenge — reintroduces the bond mechanics that self-selection exists to
avoid.

**This is an open parameter, not a settled one.** The interaction between the fee,
the dilution curve, gas cost and honest turnout is exactly what simulation must
resolve (§9).

---

## 5. Freeze composition

Incoherent voters are frozen. Duration is the first architecture's rule, unchanged:

```
duration = FREEZE_BASE × min(FREEZE_CAP, trackFactor(winning side))
```

**Freezes stack serially:**

```
until := min( now + MAX_TOTAL_FREEZE,  max(now, until) + duration )
```

Three penalties produce the sum of three terms, not the longest. This is not a
refinement — it is required. Since one stake backs unlimited concurrent cases, a
penalty that could only be served once would be diluted to nothing by an attacker
voting in many cases simultaneously. **Time is the punishment currency precisely
because it does not dilute under concurrency.**

**Flat stake makes this exact.** The first architecture pooled frozen *amounts*
under a single clock, so per-tranche expiry was inexpressible and the rule had to
be `max` rather than serial. Here there are no tranches: the whole stake is frozen
or it is not, and a single accumulator is exactly right. One `uint`, O(1), no
buckets. This is the clearest structural payoff of flat stake.

While frozen: ineligible for new cases; **votes already cast still count** and
cases already joined run to completion. The freeze removes future participation,
never past judgment.

Frozen stake is never transferred. Principle 2 is unchanged and unconditional.

### 5.1 One penalty start per case

Every voter penalised by the same case derives expiry from a **single pinned
timestamp** — the case's finalization — not from the block in which their
settlement batch happened to execute. The first architecture computed
`block.timestamp + duration` per batch, so two moderators penalised by the same
case received different expiries depending on processing order. Carried forward as a
correction (§8).

---

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
- **The index fields and the supersafe view** (`uncontested`, `fullQuorum`, the 96h
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

An open question here names who can answer it and what an answer looks like. It is
not a topic.

| # | Question | Owner | Answered when |
|---|---|---|---|
| 1 | **Reputation weight.** How strongly track record gates earnings and freezing power. Carries three jobs (§6); too weak and the freeze stops deterring, too strong and the network ossifies. | Simulation, decided by the project owner | There is a curve, validated against churn and farming scenarios |
| 2 | **Fee level.** Sets equilibrium turnout, since each voter dilutes the rest. Paying ~32 voters above gas is roughly 6× the first architecture's 1.5 xBZZ. | Simulation | Turnout stabilises near `targetCohort` at plausible gas prices |
| 3 | **`MAX_ROUNDS` and the dilution curve** (§4.6). Interacts with 2. | Simulation | Honest turnout in the final round is still above gas cost |
| 4 | **Removal supply.** Charging the requester is neutral and unspammable but leaves removals undersupplied. Does removal need a paid *role* rather than a price, and where does that pool come from without becoming farmable? | Project owner + senior reviewer | A mechanism, or an explicit decision to ship the limitation |
| 5 | **Cross-case retry** (§8). Per-content history in the permanent index — attempt counts, cooldowns, escalating fees for unchanged content. | Design | Specified and shown not to create a new farmable target |
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
