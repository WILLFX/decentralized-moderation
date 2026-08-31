# v3 Simulation — Findings

Engine: `protocol_v3.py`. Run: `python3 run_v3.py`. Design under test:
`specs/design-v3.md` and `specs/state-machine-v3.md`.

**Nothing from `simulation/v2/` carries over.** Its §A and §D are produced by risk
units, which are withdrawn, and the verdict rule itself changed from a linear
lottery to a majority of three.

The engine follows the state machine, not the design document: three tickets fixed
once per claim (§4.5), the draw taken against `â = (A+1)/(N+2)` rather than `A/N`
(§4.5), the quorum gate on commits and no reveal-stage gate (§4.8), balance debits
(§5.1), and no quorum gate in round 1 (§4.9). `f(â)` is reproduced to three
decimals at 200k draws.

**Every table below was re-run after the challenge decision was corrected.** An
earlier engine had the parties decide whether to challenge by looking at a *drawn
provisional verdict* — the thing §4.2 abolished — and gave the honest side
`content_is_safe`, ground truth they do not have. Both are fixed: the decision now
reads the published **plurality**, and the honest side's is measured against where
their own votes fell. Round 1 also widens (§3.3), which it did not before. §B and
§C moved materially; the rest moved by RNG reshuffling.

---

## Headline: the binding constraint is honest accuracy, not attacker share

Every safety number in `design-v3` is written as a function of `x`, the hostile
share of reveals. That framing is wrong, and the simulation says so plainly.

**An honest moderator who misjudges the content votes with the attacker, and the
tally cannot tell them apart.** Honest error and hostile share enter the verdict
through the same term. So the quantity that matters is

```
effective wrong-side share  =  q + (1 − q)(1 − prior)
```

P(unsafe content approved), by honest accuracy and attacker share:

```
honest prior       q=0     q=0.10    q=0.30
     0.665        0.286     0.388     0.600
     0.750        0.163     0.275     0.520
     0.850        0.070     0.176     0.432
     0.950        0.013     0.090     0.336
     0.990        0.004     0.056     0.299
```

**Read the `q=0` column.** With no attacker at all, a 66.5% honest prior approves
30% of unsafe content. There is no stake, no bond, no lottery and no challenge
round that fixes that — it is a classifier-quality problem wearing a mechanism's
clothes.

The 66.5% figure is inherited from v2's borderline-case prior. On ordinary content
the honest number is plausibly 0.95+, where `q=0` gives 1.3%. **Which number is
true is the single most valuable measurement a testnet can make**, and it dominates
every parameter in `state-machine-v3` §10.

This also sharpens design-v3 O4 (correlated error). Correlation does not merely
weaken the independence assumption in `f`; it *moves `prior` itself*, and the table
above is very steep in `prior`.

---

## A. The amplifier has a crossover, and variance moves it

`f(â) = 3â² − 2â³` suppresses minorities. That is a benefit while the honest side
is the majority of reveals and a cost the moment it is not.

```
     q    effective   P(approved)   linear (f=a)   amplified by
  0.05        0.368         0.327          0.368          0.89x
  0.10        0.401         0.388          0.401          0.97x
  0.15        0.435         0.469          0.435          1.08x
  0.20        0.468         0.503          0.468          1.07x
  0.25        0.501         0.554          0.501          1.10x
  0.30        0.534         0.608          0.534          1.14x
  0.40        0.601         0.694          0.601          1.16x
  0.50        0.667         0.777          0.667          1.16x
```

The analytic crossover — where `q + (1−q)(1−prior) = 0.5` — is at **q = 0.248**.
The observed crossover is at **q ≈ 0.12**, half of it.

**The gap is turnout variance.** `f` is below the diagonal for `â < 0.5` and above
it for `â > 0.5`. With ~34 reveals the realized `â` has real spread, so a mean `â`
comfortably under 0.5 still lands above 0.5 often enough for the convex half to
dominate the average. The amplifier starts working against the honest side well
before the honest side is actually in the minority.

Practically: **larger cohorts are worth paying for under this rule in a way they
were not under a linear lottery.** Under `f(a) = a` cohort size only reduced
variance around an unchanged mean; here variance itself shifts the mean outcome.
That is a new argument for `TARGET_COHORT`, and it is not in the spec.

## B. §4.5's claim about `h` holds

`state-machine-v3` §4.5 claims the single-randomness rule largely removes the
design's exposure to honest challenge reliability. It does.

```
   h      P(approved | unsafe)     P(approved | safe)
 0.00                    0.598                  0.413
 0.25                    0.613                  0.388
 0.50                    0.608                  0.383
 0.75                    0.614                  0.397
 1.00                    0.606                  0.397
 none                    0.592                  0.408   <- no challenge round
```

A **1.6-point** range across the whole of `h`, against the 20-point range a fresh
round-1 draw produced. O10 is defused, and more decisively than the previous
revision of this file showed: correcting the challenge decision to read the
plurality rather than a drawn provisional more than halved the residual
`h`-dependence, because a deterministic trigger removes the noise a coin flip was
adding to *who* challenges.

**But note the last row.** At these parameters the challenge round is a small net
*negative* on false approval — 0.592 with no round at all, against 0.598–0.614 with
one. The penalty narrowed too (it was up to 3.9 points, now 2.2), but it did not
change sign. The attacker always challenges a loss; the honest side challenges with
probability `h`; and under §4.5 a challenge can only move the verdict toward
whoever supplies votes. When the attacker is the reliable challenger, that
asymmetry is theirs.

The round is not worthless — it is the only correction path the architecture has,
and §8.4 and §8.5 depend on it. But **it does not pay for itself on this metric**, and the
claim in design-v3 §1 that the round exists to correct §4's false-approval number
is not supported at `q = 0.30, prior = 0.665`. It should be re-measured once
`prior` is known.

## C. F12 is real and second-order

`state-machine-v3` §3.3 argues widening cannot shift composition because it is
uniform across identities. That is true of the *eligible set*; the tally is made of
who acts. Measured on the hostile share of reveals directly:

```
 honest always-on   no widen   with widen    shift   UNRESOLVED saved
             10%       0.347        0.395   +0.049              28.1%
             30%       0.347        0.389   +0.043              33.3%
             60%       0.347        0.369   +0.023              40.4%
            100%       0.347        0.351   +0.005              46.3%
```

The shift exists, moves in the predicted direction, and is **three times larger
than the previous revision measured** — 4.9 points at worst against 28–46 points of
liveness. The earlier figure was understated because the engine widened only round
0; round 1 widens on the same schedule (§3.3 scopes it to neither round) and the
effect compounds across both. Note also that the last row is now **positive**: even
a fully always-on honest side loses a little composition to widening, where before
it appeared to gain.

The trade is still strongly favourable and §3.3's conclusion survives. But the
margin is 6:1, not 17:1, and this is the finding most likely to move again if the
model of *who is awake at minute 12* is refined. Recorded as priced, with the
price now known to be higher than it looked.

## D. F9 bites hardest at the *small* end

`T` cannot be recalibrated on chain (§3.6), so it is fixed at whatever registry
size it was calibrated for. Calibrated for 1,000:

```
 registry   E[cohort]   P(approved)   P(unresolved)
      250          10         0.049           0.922
      500          20         0.575           0.092
    1,000          40         0.605           0.000
    2,000          80         0.586           0.000
   10,000         400         0.597           0.000
```

**Below the calibration size the system stops working**, not gracefully: at 250
moderators the expected cohort is 10 against `MIN_COMMITS` 16, and 92.2% of cases end
`UNRESOLVED(NO_TURNOUT)`. That is the launch condition, and it is the one the spec
does not survive.

Above it, composition is stable and the verdict distribution barely moves — but the
pot splits `TARGET_COHORT` ways, so at 10,000 moderators per-voter pay is a fortieth
of its calibrated value while gas is unchanged. `d = 1.4 × E[P/N]` falls with pay;
gas does not.

So F9's cost is at both ends and they are different failures: **too small is a
liveness failure, too large is an economic one.** Neither is a safety failure,
which is worth stating — but the launch-size case has to be solved before mainnet,
and widening (§3.3) is the only lever the design currently has.

## E. Viability — the debit works where the freeze did not

```
 d / E[share]   confidence needed   honest votes?
          0.5              0.3333             yes
          1.0              0.5000             yes
          1.4              0.5833             yes
          2.0              0.6667              NO
          4.0              0.8000              NO
         10.0              0.9091              NO
```

At the working `d = 1.4 × E[P/N]`, voting is rational for anyone above 58.3%
confidence, against an honest prior of 66.5%. The margin is thin — `d = 2×` already
excludes the honest prior — but **it is a design choice rather than an emergent
product of two unrelated quantities.** Under v2's identity-wide freezing this column
read 70 and honest turnout was zero at every fee from 3 to 300.

---

## F. Correlation matters most where there is no attacker

`correlated.py` replaces the independent-error assumption with a per-item latent
difficulty — `p ~ Beta` with mean `prior` and intra-class correlation `rho`, so
`rho = 0` is independence and `rho = 1` is one opinion sampled `N` times.

```
P(unsafe approved) / P(safe rejected)

no attacker           rho=0        rho=0.25      rho=0.5       rho=1.0
    prior 0.665   0.286/0.288   0.298/0.320   0.337/0.336   0.345/0.340
    prior 0.850   0.087/0.087   0.117/0.125   0.144/0.140   0.154/0.163
    prior 0.950   0.018/0.024   0.038/0.048   0.049/0.044   0.057/0.055
    prior 0.990   0.006/0.005   0.008/0.010   0.011/0.011   0.013/0.011

30% hostile           rho=0        rho=0.25      rho=0.5       rho=1.0
    prior 0.950   0.340/0.338   0.348/0.344   0.344/0.318   0.322/0.334
    prior 0.990   0.307/0.303   0.300/0.293   0.301/0.296   0.288/0.302
```

**Correlation costs the most in the clean case and almost nothing in the attacked
one.** At `prior = 0.95` with no attacker, false rejection goes 2.4% → 5.5% as
`rho` runs 0 → 1. At 30% hostile the same sweep moves it by a point or two, and
occasionally *helps*, because the attacker already dominates the tally and extra
variance sometimes rescues a case.

That inverts how P1-4 has been framed. Correlated error has been filed as an
attack-adjacent concern; it is mostly a **quality** problem, and it bites hardest
in the regime the index will actually spend its life in — ordinary content, no
adversary, where the only thing standing between a publisher and permanent
exclusion is whether thirty-two moderators err together.

**Where design-v3 §8's 0.725% lives.** That figure is `1 − f(0.95)`, and the table
locates it exactly: it requires `prior ≈ 0.96+`, `rho ≈ 0`, **and** `q = 0`, all
three at once. Two of the three are unmeasured and the third is assumed away
everywhere else in the document. It is the sole justification for making `REJECTED`
permanent and irreversible.

**And the figure itself is stale by a factor of three.** `1 − f(0.95)` was computed
against the sample proportion. At the same tally — `a = 0.95` over `N = 34` reveals
— `â` is 0.917 and `1 − f(â)` is **1.97%**, before `rho` or `q` enter at all. §8's
number is not merely optimistic about its inputs; it is the wrong arithmetic for
the rule the spec now states.

**And neither variable rescues the other.** At 30% hostile, even `prior = 0.99`
approves 29% of unsafe content. Moderator quality does not buy safety against an
attacker, and stake security does not buy accuracy without one. The design needs
both to be true and has measured neither.

---

## G. The estimator — what `â` denies, and what denying it costs

§4.5 draws against `â = (A+1)/(N+2)`, the posterior mean of the population's
Approve rate under a uniform prior, rather than the sample proportion `A/N`. `f`
consumes a population rate; handing it a sample proportion claims certainty from
`N` observations, and at a unanimous tally the claim is exact — `f(1) = 1`.

```
     N   â at unanimity     f(â)   cohort overruled
     1           0.6667   0.7407             25.93%
     3           0.8000   0.8960             10.40%
     8           0.9000   0.9720              2.80%
    16           0.9444   0.9911              0.89%
    40           0.9762   0.9983              0.17%
   100           0.9902   0.9997              0.03%
```

**One revealed vote is a unanimous tally**, and `MIN_COMMITS` does not prevent one:
the quorum gate is on commits, and a revealer count of 1 needs only that the other
fifteen committers withhold. Under `A/N` that single vote decided the case with
certainty, and both invariants that look like they cover it read true without
covering it — I11 quantified over "under-quorum", which has meant the commit gate
since §4.8 moved it there, and I12 over "every side with ≥ 1 revealed vote", which
at a unanimous tally is one side with probability 1.

**It is not a wall.** An attacker owning all sixteen reveals of a minimum-quorum
case still gets 99.1%. What it buys is that no incentive argument in the spec has a
degenerate branch: §7.3's `f(â)·(share + d) > 0` and §8.4's "every draw has an
approval branch" are strict at *every* tally under `â`, and both were ties at a
unanimous one under `A/N`.

**What it costs.** P(safe content rejected), no attacker:

```
 prior       â
 0.665   0.265
 0.850   0.074
 0.950   0.017
 0.990   0.005
```

Against `A/N` the same column read 0.232 / 0.051 / 0.006 / 0.000 before the
challenge decision was corrected; the estimator's own contribution is 0.3 to 2.1
points, measured on the previous engine. It lands on the number this design is
already weakest on, and
second-order against the 26–60% that honest error contributes to it (§F). The
distortion is bounded — at `N = 34` the two rules differ by at most 1.4 points, and
symmetrically about `â = 0.5` — and it is largest exactly where the evidence is
thinnest, which is the point rather than the cost.

**Every number in this file is computed under the plug-in `f(â)`, not the exact
posterior predictive.** `f` is non-linear, so `f(E[θ]) ≠ E[f(θ)]`, and the plug-in
over-claims by 4.1 points at `N = 1` falling to 0.15 at `N = 40`. The engine
implements what the spec specifies (`state-machine-v3` §4.5), and the spec keeps
the plug-in deliberately — but the estimator is part of these numbers' provenance
and is stated here rather than assumed.

**It also revived a clause that turns out to be arbitrary.** §8.3's `SUPER_SAFE` requires both
`pooledReject == 0` and a 3/3 Approve draw. Under `A/N` the first forces the
second, so the conjunct was redundant and the paragraph justifying it reasoned
about a case the conjunction had excluded. Under `â` a unanimous tally gives
`P(3/3) = â³` — 93.0% at `N = 40`. But live is not meaningful: under a unanimous
tally the tickets are iid, so 3/3 versus 2/1 is a coin flip carrying no information
the tally does not already give, and the clause excludes a random 7% of qualifying
content. `state-machine-v3` §10 carries the question of dropping it.

---

## What this engine does not model

- **Bond dynamics across cases.** Debits and rewards accumulate; capacity is meant
  to be earned. One-case-at-a-time cannot see that, and it is where `BOND_MIN` and
  `CHALLENGE_BOND` have to be set.
- ~~**Correlated error.**~~ Now modelled — §F. Still *unmeasured*:
  `measurement/prior/` is the harness, and it needs a corpus and readers this
  repository does not have.
- **Withholding to shrink the tally.** §5.2's dominance argument says nobody
  optimizing inside the protocol withholds, and §G shows what a thin tally can now
  express. A party with an external prize might still withhold. Not measured.
- **Gas.** `FEE_BASE` is open and the fee/gas margin was the binding constraint in
  every v2 run.
- **Identity churn, pre-aged Sybils, bribery, claim-key squatting.**
