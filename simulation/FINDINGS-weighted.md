# Reliability-weighted aggregation — E18–E23

Produced by `run_weighted.py` against `weighted.py`. Registry 1,000, cohort 40,
`q = 0.30`, 4,000 trials. Weight is the Nitzan–Paroush optimum for combining
independent binary judgments, `w = log(r/(1−r))`, clipped below at zero and above
at `weight_cap`, then normalized to mean 1 over each case's revealers so that
`â = (WA+1)/(WN+2)` keeps §4.5's Laplace correction unchanged.

**The question.** `measurement/prior/README.md` records that every safety figure is
a function of `q + (1−q)(1−prior)`. But that `prior` is the mean of the pooled
population **under equal weights**, and equal weighting is a choice, not a fact.
Can the effective `prior` be raised without anyone becoming a better moderator?

**Result: yes, by a lot, and it pays most exactly where the design is worst — but
the entire gain rests on one assumption about the attacker that the protocol
cannot enforce and cannot check.**

---

## 1. The precondition holds, and the gain scales with spread (E18)

Mean reliability held at `prior` throughout, so the sweep changes the **spread**
and not the population's competence. ORACLE weights by the true `r_i` and is the
ceiling on any estimator. The attacker here is **no better a judge** than an honest
moderator — §3 is where that is removed.

**prior 0.665** — false approval:

| SD of `r` | unweighted | ORACLE | gold, n=50 | gain |
|---:|---:|---:|---:|---:|
| 0.000 | 0.593 | 0.593 | 0.591 | **+0.000** |
| 0.066 | 0.591 | 0.557 | 0.565 | +0.033 |
| 0.157 | 0.589 | 0.435 | 0.442 | **+0.155** |
| 0.211 | 0.594 | 0.359 | 0.369 | +0.234 |
| 0.273 | 0.576 | 0.253 | 0.261 | **+0.323** |

**prior 0.95** — false approval:

| SD of `r` | unweighted | ORACLE | gold, n=50 | gain |
|---:|---:|---:|---:|---:|
| 0.000 | 0.347 | 0.347 | 0.345 | +0.000 |
| 0.073 | 0.346 | 0.356 | 0.331 | −0.009 |
| 0.126 | 0.357 | 0.351 | 0.318 | +0.006 |

Two things worth separating.

**At zero spread the gain is exactly zero, not negative.** Weighting a homogeneous
population is neutral rather than harmful, because the estimator is unbiased and
the weights are normalized. The prediction going in was that it would *hurt* — that
was wrong, and the reason is the normalization, not the estimator.

**The gain is bounded by the mean, and this is the structurally interesting part.**
A Beta with mean 0.95 cannot spread far — variance is at most `m(1−m)`, so a good
population is necessarily a uniform one. **Weighting therefore pays most exactly
where the design is worst.** At `prior` 0.665 it is worth 15–32 points; at 0.95 it
is worth nothing, because there is nothing left to sort.

That is the opposite of how most mitigations in this project behave, and it is the
strongest argument the idea has.

## 2. The estimate is cheap (E19)

| `n_gold` | % of ORACLE at SD 0.157 | at SD 0.273 |
|---:|---:|---:|
| 5 | 61% | 67% |
| 25 | 89% | 93% |
| **50** | **95%** | **98%** |
| 250 | 102% | 104% |

Fifty known-answer cases per moderator captures ~95% of what perfect knowledge
would deliver. This is not the binding constraint.

## 3. The attack, and it decides the question (E20)

Gold cases are indistinguishable from real ones, so an attacker cannot dodge them.
**He does not need to.** He answers every case honestly except the one he is
attacking, so his measured reliability is what his *judgment* is worth, not what
his *behaviour* is worth. An honest moderator at `prior` 0.665 cannot score above
0.665; an attacker who can read the content scores whatever he can read at.

**prior 0.665**, unweighted baseline 0.589, hostile share of **heads** fixed at
0.349:

| attacker's gold accuracy | false approval | hostile share of **weight** | vs unweighted |
|---:|---:|---:|---:|
| 0.665 | 0.442 | 0.307 | **−0.147** |
| 0.750 | 0.537 | 0.405 | −0.053 |
| **0.797 (crossover)** | — | — | **0.000** |
| 0.850 | 0.651 | 0.511 | +0.061 |
| 0.950 | 0.756 | 0.617 | +0.167 |
| 1.000 | 0.792 | **0.649** | **+0.203** |

**prior 0.95**, unweighted 0.346, crossover at **0.967**:

| attacker's gold accuracy | false approval | hostile weight | vs unweighted |
|---:|---:|---:|---:|
| 0.665 | 0.087 | 0.125 | −0.260 |
| 0.850 | 0.216 | 0.255 | −0.130 |
| 1.000 | 0.369 | 0.379 | +0.023 |

**The crossover is "the attacker judges better than the honest cohort weighs."**
Both bars were measured directly at 8,000 trials rather than interpolated from the
table above: **0.797** at `prior` 0.665, **0.967** at `prior` 0.95. Note the bar is
*not* the honest mean plus a constant — it sits 13 points above the mean at 0.665
and 2 points above it at 0.95, because the weight is a log-odds and the honest
cohort's average weight is dragged down by its own left tail, which is long at
0.665 and short at 0.95. Below the bar weighting *dilutes* the
attacker — at 0.665 he holds 30.7% of the weight from 34.9% of the heads. Above it
the transfer runs the other way, and at perfect accuracy he holds **65% of the
weight from 35% of the heads**.

**This is a cost-of-corruption question, and it is the same gap as the one the
staged-committee analysis found.** Today an attacker buys identities, bounded by
`BOND_MIN`. Under weighting he must buy identities **and** accuracy. That is
strictly harder, and it is the first mechanism in this project that prices an
attacker's *competence* rather than only his capital. Whether it is hard enough is
not a protocol question: it is whether reaching 0.80 on borderline content costs
more than the listing is worth.

There is a real argument on each side and the simulation settles neither:

- **For.** `prior` is 0.665 *because the content is genuinely ambiguous*
  (`measurement/prior/README.md`: `prior` is a property of readers **and** what
  they are shown). An attacker reading someone else's gold case faces the same
  ambiguity and plausibly scores 0.665 too.
- **Against.** He is motivated, farms only a handful of identities, and can spend
  per gold case what an honest moderator earning a slice of a submission fee
  cannot. Honest accuracy is set by what a rushed volunteer manages; his is set by
  a budget.

## 4. Bootstrapped gold is less circular than expected (E21)

`measurement/prior` says ground truth must come from outside. The cheap
alternative — seeding gold from the protocol's own confident settlements — is
circular, because at `prior` 0.665 those settlements are wrong most of the time.

| gold label accuracy | attacker at 0.665 | attacker at 1.00 |
|---:|---:|---:|
| 1.00 | 0.442 | 0.792 |
| 0.85 | 0.445 | 0.746 |
| 0.75 | 0.457 | 0.729 |
| 0.65 | 0.492 | 0.710 |

**The benign column degrades gently**: a 35-point drop in label quality costs 5
points of false approval. The estimator tolerates dirty labels far better than
expected, because label noise is symmetric and averages out over `n_gold`
observations while the reliability signal does not.

**The attacked column improves as labels get worse**, which is counter-intuitive
and worth stating so nobody mistakes it for a defence: the attacker's score is
measured through the same noisy channel, so noise levels everyone. It works by
destroying the signal being farmed, which is not a mechanism anyone would choose.

## 5. Best case, and where it lands (E22)

Wide spread, 250 clean gold cases, attacker no better a judge:

| `prior` | `q` | unweighted | weighted | ORACLE | gain |
|---:|---:|---:|---:|---:|---:|
| 0.665 | 0.10 | 0.386 | 0.174 | 0.173 | **+0.212** |
| 0.665 | 0.30 | 0.594 | 0.359 | 0.359 | **+0.234** |
| 0.850 | 0.10 | 0.189 | 0.107 | 0.106 | +0.082 |
| 0.850 | 0.30 | 0.427 | 0.318 | 0.320 | +0.110 |
| 0.950 | 0.10 | 0.107 | 0.093 | 0.097 | +0.014 |
| 0.950 | 0.30 | 0.353 | 0.347 | 0.359 | +0.006 |

At `prior` 0.665 and `q = 0.30`, false approval falls from 59% to 36%. That does
not make the design shippable — 36% is still not a search index — but it is the
largest single improvement anything in this project has produced, and `FINDINGS-v3`
§A's table says the honest alternative is finding better moderators.

## 6. A cap improves the trade and does not fix it (E23)

`weight_cap` bounds what one identity can be worth. Both §1's gain and §3's harm
flow through it, so the question is whether they respond at different rates.

| cap | benign gain | attacked harm | gain / harm |
|---:|---:|---:|---:|
| 0.75 | +0.034 | +0.023 | 1.48 |
| **1.00** | **+0.065** | **+0.038** | **1.71** |
| 1.50 | +0.115 | +0.077 | 1.49 |
| 2.00 | +0.135 | +0.112 | 1.21 |
| 3.00 | +0.147 | +0.203 | 0.72 |
| 5.00 | +0.150 | +0.250 | 0.60 |

**The gain saturates and the harm does not.** Past cap 2 the benign column has
essentially stopped improving while the attacked column keeps degrading linearly,
so any cap above ~2 is strictly worse than a cap at 2. The ratio peaks at **1.71
around cap 1.0**.

But there is **no cap at which the attacked column is not harmed**. The cap turns a
2.5-point loss per point of gain into a 0.6-point loss; it does not produce a
setting that is safe under both assumptions. It improves the bet. It is not a
defence.

---

## Verdict

**The mechanism works, and it is the only thing measured in this project that
moves `prior`'s consequences rather than working around them.** 23 points of false
approval at the parameters where the design is weakest, from 50 gold cases per
moderator, tolerant of dirty labels, and free at zero heterogeneity.

**Its entire value is conditional on one number the protocol cannot observe:
whether an attacker judges content better than 0.80.** Above that line the same
mechanism runs in reverse at comparable magnitude, and no weight cap removes that —
cap 1.0 only improves the odds to 1.71 gained per lost.

So this is not "adopt" or "reject". It is a **bet whose terms are now known**, and
the three things that would settle it are all measurements rather than designs:

1. **What is an attacker's accuracy on borderline content?** This is the same
   testnet instrument `measurement/prior/README.md` already specifies, asked of a
   motivated reader instead of a volunteer. It has never been asked.
2. **What is the SD of `r` across real moderators?** §1's entire gain is a function
   of it, and it is zero if moderators are uniform. `measure.py`'s per-rater path
   already computes this — it is `rho`'s companion and falls out of the same data.
3. **What is the listing worth?** The crossover is a budget line, so the attack is
   priced. This is the cost-of-corruption bound `specs/protocol.md` §10 does not
   state, and the staged-committee analysis found the same gap from the other side.

**Recommendation.** Do not put weighting in the spec yet — its value is unknown in
sign until (1) and (2) are measured, and specifying it now would pin a scheme whose
best parameter is a number nobody has. Do add both quantities to what the testnet
must record, since they are the same instrument and nearly the same data as the
`prior` measurement already planned, and (2) costs nothing extra to collect.
