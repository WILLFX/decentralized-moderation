# Exact enumeration — E29–E32

`FINDINGS-staged.md` answered the staged-committee question by sampling.
**Sampling is the wrong instrument for this claim.** 20,000 trials carries a
standard error of roughly 0.3pp, the behavioural model is hand-written, and
anyone who doubts the conclusion has no way to tell a real effect from a seed —
which is precisely the failure mode this project has already had three times
(a degenerate experiment, a contaminated pair, and two mutation harnesses that
scored compile failures as kills).

This file recomputes the load-bearing claim **exactly**: no RNG, no trials, a
finite state space summed in full. Produced by `run_exact.py`, engine `exact.py`.

**The headline is that the sign of the result is a theorem, not a measurement.**
The simulation only fixes its size.

---

## §A The result is provable, and here is the proof

Let `P_m` be the probability that a committee drawn with expected size `m` has
attacker share at least `θ`, where the attacker controls population share `q`.

**Claim.** For any `θ > q`, splitting one committee of expected size `2n` into
two independently drawn committees of expected size `n` strictly increases the
probability that the attacker finds a favourable committee.

**Proof.** The attacker's share of a committee concentrates on `q` as the
committee grows, so for a threshold strictly above `q` the upper tail
probability `P_m` is strictly decreasing in `m`; hence `P_2n < P_n`. Two
independent draws give `1 − (1 − P_n)² = 2P_n − P_n²`, and `P_n < 2P_n − P_n²`
for any `0 < P_n < 1`. Chaining:

    P_2n  <  P_n  <  2P_n − P_n²  =  1 − (1 − P_n)²                        ∎

The first step is concentration, the second is algebra. **No behavioural
parameter appears.** `prior`, availability, the ticket rule, the fee, conformity
— none of them enter. They change how much worse splitting is; they cannot
change that it is worse.

`θ > q` is not a restriction in any case that matters: a threshold *below* the
attacker's population share means the average committee is already favourable,
and no committee structure helps.

E30 verifies the inequality exactly in sixteen cells spanning `q ∈ {10…40%}`,
`θ ∈ {50%, 60%}`, `n ∈ {10, 20}`. It holds in all of them, by margins of one to
three orders of magnitude:

| q | θ | n | P(favourable, one of 2n) | P(favourable, either of two n) |
|---:|---:|---:|---:|---:|
| 10% | 50% | 10 | 0.000048 | 0.008158 |
| 10% | 50% | 20 | ~0 | 0.000097 |
| 20% | 50% | 10 | 0.003155 | 0.065774 |
| 20% | 50% | 20 | 0.000033 | 0.006301 |
| 30% | 50% | 10 | 0.042053 | 0.241462 |
| 30% | 50% | 20 | 0.005343 | 0.082338 |
| 30% | 60% | 20 | 0.000085 | 0.009343 |
| 40% | 50% | 20 | 0.112078 | 0.382000 |

## §B Two engines, no shared code, agreeing

E29 runs the exact engine against the Monte Carlo one at matched settings. They
share nothing: one enumerates a state space, the other samples a behavioural
model. Each cell is tested against **its own** standard error, because the
conditional rate is estimated from only the trials that proceeded and therefore
carries far more noise than the unconditional one — a blanket tolerance would
pass the easy cell and fail the hard one for the wrong reason.

| cell | exact | Monte Carlo | gap |
|---|---:|---:|---:|
| cohort 20, P(proceed) | 0.1242 | 0.1311 | 2.9σ |
| cohort 20, P(admit\|proceed) | 0.7473 | 0.7377 | 1.1σ |
| cohort 40, P(proceed) | 0.0411 | 0.0437 | 1.8σ |
| cohort 40, P(admit\|proceed) | 0.7486 | 0.7634 | 1.0σ |

The 2.9σ was checked against five further seeds rather than waved through:
`+2.92, −0.57, +0.23, +0.87, +0.08, +0.23`, mean `+0.63σ`. Scatter in both
directions around zero — seed 11 is an unlucky draw, not a systematic gap.

**Truncation** is the engine's only approximation. Re-running the whole
comparison at `EPS = 1e-15`, `1e-18` and `1e-21` moves no reportable figure at
all; the sole cell that moves (`q = 10%`, `n = 20`, where both numerator and
denominator are ~1e-10) moves by 1.6e-4 relative.

## §C One correction to the sampled version

`staged.py` tested favourability against the committee that **attends**. An
attacker cannot observe attendance — eligibility is a public hash, attendance is
not. The exact engine tests against the **eligible** set, which is what is
actually visible when the decision is made.

This matters: it makes the attacker weaker and the numbers below are the
corrected ones. It also makes them *worse* for the staged design than the sampled
run reported.

## §D The comparison, exact

Equal review effort — one committee of `2n` against two staged committees of
`n`, so the same expected number of reviewers sees the case:

| n | architecture | P(proceed) | P(admit\|proceed) | **admit/submission** |
|---:|---|---:|---:|---:|
| 10 | one committee of 20 | 0.04205 | 0.78115 | **0.03285** |
| 10 | two staged of 10 | 0.24146 | 0.60071 | **0.14505** |
| | | | | **4.42×** |
| 20 | one committee of 40 | 0.00534 | 0.78707 | **0.00420** |
| 20 | two staged of 20 | 0.08234 | 0.59418 | **0.04892** |
| | | | | **11.63×** |

The sampled run put this at 4×. Exactly, at cohort 40 it is **11.63×** — the
Monte Carlo understated it, because the tail it needed to resolve is where
sampling is weakest.

Read the two middle columns together. Staging delivers exactly what it promises
on the conditional: 0.787 → 0.594. And it raises the chance that *some*
committee is favourable from 0.005 to 0.082 — a factor of 15. **One submission
buys two draws at a favourable committee instead of one,** because committee 2
is selected after committee 1 closes and the attacker pays one fee for both.

## §E Does splitting ever win?

E32 sweeps `q × prior` exactly, at `n = 10`. Ratio of campaign rates, staged
over single; above 1.00 means splitting is worse:

| q \ prior | 0.600 | 0.665 | 0.750 | 0.850 | 0.950 |
|---:|---:|---:|---:|---:|---:|
| 10% | 120.19 | 111.29 | 98.78 | 82.89 | 65.87 |
| 20% | 15.90 | 15.01 | 13.75 | 12.12 | 10.33 |
| 30% | 4.61 | 4.42 | 4.13 | 3.76 | 3.36 |
| 40% | 2.11 | 2.05 | 1.96 | 1.83 | 1.70 |
| 50% | 1.34 | 1.31 | 1.27 | 1.23 | 1.18 |

**Twenty-five cells, no crossing.** The best case for the staged pair anywhere in
the grid is `q = 50%, prior = 0.95`, and it still loses at 1.18×.

Note the direction: **the single committee's advantage is largest where the
attacker is weakest.** At `q = 10%` it is 120×. That is the regime a working
deployment lives in, so the gap is widest exactly where it matters most — because
concentration bites hardest when the threshold is furthest above `q`.

## §F What exactness does not cover

Every one of these is still a place the conclusion could be wrong, and none is
touched by removing sampling error.

1. Eligibility independent across identities (the protocol's per-identity hash).
2. **Honest reading errors independent across moderators.** Correlated error — a
   content class many reviewers misread together — is not modelled and raises
   every figure here.
3. Fixed attacker share of the registry; Sybil cost not modelled.
4. Attacker pay-insensitive: cost deters an attempt, never a vote.
5. Honest moderators vote their reading and do not model the attacker.
6. Attendance independent of committee composition.
7. **No conformity term** — neither committee sees the other's votes. That is the
   staged proposal's own claim, granted to it in full.

Note what (7) means: the staged design is being evaluated under its *best case*,
with its central mechanism assumed to work perfectly, and it still loses by an
order of magnitude. The loss is not a failure of hiding. It is the halving.

## §G Conclusion

**Do not split the committee.** One committee of `2n` strictly dominates two
staged committees of `n` at equal review effort, everywhere in the parameter
space, and the *sign* of that result is a theorem rather than a simulation
output. The simulation establishes the magnitude: between 1.2× and 120×,
depending on how far the favourability threshold sits above the attacker's
share.

The proposal's diagnosis — that a committee which can see a running tally will
follow it — is confirmed separately in `FINDINGS-staged.md` §F at 10–29 points,
and is worth acting on. It does not require splitting anything.
