# v3 Simulation — Findings

Engine: `protocol_v3.py`. Run: `python3 run_v3.py`. Design under test:
`specs/design-v3.md` and `specs/state-machine-v3.md` at `e2f374a`.

**Nothing from `simulation/v2/` carries over.** Its §A and §D are produced by risk
units, which are withdrawn, and the verdict rule itself changed from a linear
lottery to a majority of three.

The engine follows the state machine, not the design document: three tickets fixed
once per claim (§4.5), the quorum gate on commits (§4.8), balance debits (§5.1),
and no quorum gate in round 1 (§4.9). `f(a)` is reproduced to three decimals at
200k draws.

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
     0.665        0.301     0.392     0.616
     0.750        0.166     0.283     0.542
     0.850        0.061     0.178     0.449
     0.950        0.010     0.093     0.349
     0.990        0.001     0.060     0.306
```

**Read the `q=0` column.** With no attacker at all, a 66.5% honest prior approves
30% of unsafe content. There is no stake, no bond, no lottery and no challenge
round that fixes that — it is a classifier-quality problem wearing a mechanism's
clothes.

The 66.5% figure is inherited from v2's borderline-case prior. If real moderators
are AI classifiers on ordinary content, the honest number is plausibly 0.95+, where
`q=0` gives 1%. **Which number is true is the single most valuable measurement a
testnet can make**, and it dominates every parameter in `state-machine-v3` §10.

This also sharpens design-v3 O4 (correlated AI error). Correlation does not merely
weaken the independence assumption in `f`; it *moves `prior` itself*, and the table
above is very steep in `prior`.

---

## A. The amplifier has a crossover, and variance moves it

`f(a) = 3a² − 2a³` suppresses minorities. That is a benefit while the honest side
is the majority of reveals and a cost the moment it is not.

```
     q    effective   P(approved)   linear (f=a)   amplified by
  0.05        0.368         0.344          0.368          0.94x
  0.10        0.401         0.385          0.401          0.96x
  0.15        0.435         0.449          0.435          1.03x
  0.20        0.468         0.501          0.468          1.07x
  0.25        0.501         0.569          0.501          1.13x
  0.30        0.534         0.618          0.534          1.16x
  0.40        0.601         0.722          0.601          1.20x
  0.50        0.667         0.795          0.667          1.19x
```

The analytic crossover — where `q + (1−q)(1−prior) = 0.5` — is at **q = 0.248**.
The observed crossover is at **q ≈ 0.13**, less than half of it.

**The gap is turnout variance.** `f` is below the diagonal for `a < 0.5` and above
it for `a > 0.5`. With ~34 reveals the realized `a` has real spread, so a mean `a`
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
 0.00                    0.645                  0.389
 0.25                    0.633                  0.392
 0.50                    0.618                  0.380
 0.75                    0.607                  0.394
 1.00                    0.608                  0.408
 none                    0.594                  0.403   <- no challenge round
```

A **3.7-point** range across the whole of `h`, against the 20-point range a fresh
round-1 draw produced. O10 is defused.

**But note the last row.** At these parameters the challenge round is a small net
*negative* on false approval — 0.594 with no round at all, against 0.608–0.645 with
one. The attacker always challenges a loss; the honest side challenges with
probability `h`; and under §4.5 a challenge can only move the verdict toward
whoever supplies votes. When the attacker is the reliable challenger, that
asymmetry is theirs.

The round is not worthless — it is the only correction path the architecture has,
and §8.4 depends on it. But **it does not pay for itself on this metric**, and the
claim in design-v3 §1 that the round exists to correct §4's false-approval number
is not supported at `q = 0.30, prior = 0.665`. It should be re-measured once
`prior` is known.

## C. F12 is real and second-order

`state-machine-v3` §3.3 argues widening cannot shift composition because it is
uniform across identities. That is true of the *eligible set*; the tally is made of
who acts. Measured on the hostile share of reveals directly:

```
 honest always-on   no widen   with widen    shift   UNRESOLVED saved
             10%       0.354        0.371   +0.017              29.5%
             30%       0.354        0.370   +0.016              35.6%
             60%       0.354        0.362   +0.008              43.8%
            100%       0.354        0.351   −0.003              48.6%
```

The shift exists and moves in the predicted direction, but it is **1.7 points at
worst against 30–49 points of liveness**. The trade is strongly favourable and
§3.3's conclusion survives even though its argument was incomplete. Recorded as
priced rather than as a defect.

## D. F9 bites hardest at the *small* end

`T` cannot be recalibrated on chain (§3.6), so it is fixed at whatever registry
size it was calibrated for. Calibrated for 1,000:

```
 registry   E[cohort]   P(approved)   P(unresolved)
      250          10         0.052           0.919
      500          20         0.573           0.069
    1,000          40         0.627           0.000
    2,000          80         0.610           0.000
   10,000         400         0.611           0.000
```

**Below the calibration size the system stops working**, not gracefully: at 250
moderators the expected cohort is 10 against `MIN_COMMITS` 16, and 92% of cases end
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
    prior 0.665   0.274/0.274   0.294/0.309   0.333/0.335   0.345/0.339
    prior 0.950   0.012/0.012   0.032/0.039   0.047/0.042   0.056/0.052
    prior 0.990   0.002/0.001   0.005/0.004   0.009/0.008   0.011/0.008

30% hostile           rho=0        rho=0.25      rho=0.5       rho=1.0
    prior 0.950   0.329/0.329   0.340/0.333   0.337/0.313   0.312/0.325
    prior 0.990   0.292/0.295   0.292/0.283   0.292/0.285   0.277/0.291
```

**Correlation costs the most in the clean case and almost nothing in the attacked
one.** At `prior = 0.95` with no attacker, false rejection goes 1.2% → 5.2% as
`rho` runs 0 → 1: more than fourfold. At 30% hostile the same sweep moves it by a
point or two, and occasionally *helps*, because the attacker already dominates the
tally and extra variance sometimes rescues a case.

That inverts how P1-4 has been framed. Correlated AI error has been filed as an
attack-adjacent concern; it is mostly a **quality** problem, and it bites hardest
in the regime the index will actually spend its life in — ordinary content, no
adversary, where the only thing standing between a publisher and permanent
exclusion is whether thirty-two classifiers err together.

**Where design-v3 §8's 0.725% lives.** That figure is `1 − f(0.95)`, and the table
locates it exactly: it requires `prior ≈ 0.96+`, `rho ≈ 0`, **and** `q = 0`, all
three at once. Two are unmeasured and the third is assumed away everywhere else in
the document. It is the sole justification for making `REJECTED` permanent and
irreversible.

**And neither variable rescues the other.** At 30% hostile, even `prior = 0.99`
approves 29% of unsafe content. Classifier quality does not buy safety against an
attacker, and stake security does not buy accuracy without one. The design needs
both to be true and has measured neither.

---

## What this engine does not model

- **Bond dynamics across cases.** Debits and rewards accumulate; capacity is meant
  to be earned. One-case-at-a-time cannot see that, and it is where `BOND_MIN` and
  `CHALLENGE_BOND` have to be set.
- ~~**Correlated error.**~~ Now modelled — §F. Still *unmeasured*:
  `measurement/prior/` is the harness, and it needs model access this repository
  does not have.
- **Withholding to force `WITHHELD`.** §5.2's dominance argument says nobody
  optimizing inside the protocol withholds; an attacker with an external prize
  might. Not measured.
- **Gas.** `FEE_BASE` is open and the fee/gas margin was the binding constraint in
  every v2 run.
- **Identity churn, pre-aged Sybils, bribery, claim-key squatting.**
