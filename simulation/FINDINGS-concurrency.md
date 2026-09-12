# Freeze vs debit, and what "infinite concurrency" buys — E38–E39

**Finding: under an additive freeze, infinite concurrency is nominal. Throughput
saturates at `1/(F(1−p))` cases per day, and no fee level changes that.**

Engine `freeze.py`. The main result is a derivation, checked against a day-by-day
run rather than discovered by one.

---

## §A First, the repository's own evidence was bad

Spec §5.1 abolishes freezes and cites: identity-wide freezing *"produced zero
honest turnout at every fee from 3 to 300."*

That number came from the v2 engine, whose participation utility multiplied an
**already unconditional** expected payment by the probability of coherence. With
`E` the expected payment and a loss costing `r·E`:

| | condition to vote |
|---|---|
| what the engine computed | `p·E − (1−p)·r·E > 0` ⟹ `p > r/(1+r)` |
| what it should have been | `E − (1−p)·r·E > 0` ⟹ `p > 1 − 1/r` |

| r | engine | corrected | gap |
|---:|---:|---:|---:|
| 1.4 | 58.33% | 28.57% | 29.8pp |
| 3 | 75.00% | 66.67% | 8.3pp |
| 10 | 90.91% | 90.00% | 0.9pp |
| 30 | 96.77% | 96.67% | 0.1pp |
| 80 | 98.77% | 98.75% | 0.0pp |

**The conclusion survives.** Identity-wide freezing puts `r` in the tens or
hundreds, where the two formulas agree to within a tenth of a point. But the
figure the spec quotes was produced by a broken function, the error was found by
external review rather than by us, and the spec should not go on citing it as
though it were evidence.

## §B The argument that does hold

A moderator active on a given day votes in `L` cases. Each incoherent vote adds
`F` days to a running freeze total — the proposal's own wording, *"added to the
total freeze time"* — and a frozen moderator votes in nothing.

Per active day they accrue `F(1−p)L` frozen days. So the duty cycle is

    a  =  1 / (1 + F(1−p)L)

and realised throughput is

    L·a  =  L / (1 + F(1−p)L)   →   1/(F(1−p))   as L → ∞

Checked at `p = 0.665`, `F = 8`, 200,000 simulated days:

| L (concurrent cases) | predicted | simulated |
|---:|---:|---:|
| 1 | 0.272 | 0.272 |
| 2 | 0.314 | 0.314 |
| 5 | 0.347 | 0.347 |
| 10 | 0.360 | 0.359 |
| 50 | 0.370 | 0.370 |
| 200 | 0.372 | 0.373 |

**Going from one open case to two hundred buys a 37% throughput increase and then
nothing.** The freeze converts unlimited concurrency into a hard ceiling.

## §C The ceiling

Sustainable cases per day per identity, `1/(F(1−p))`:

| F (days per loss) | p = 0.665 | p = 0.80 | p = 0.90 | p = 0.95 |
|---:|---:|---:|---:|---:|
| 0.25 | 11.94 | 20.00 | 40.00 | 80.00 |
| 1 | 2.99 | 5.00 | 10.00 | 20.00 |
| 2 | 1.49 | 2.50 | 5.00 | 10.00 |
| 4 | 0.75 | 1.25 | 2.50 | 5.00 |
| 8 | 0.37 | 0.63 | 1.25 | 2.50 |
| 16 | 0.19 | 0.31 | 0.63 | 1.25 |

**No price appears in the expression.** It is a time-against-time constraint, so
raising the fee raises both sides equally and the ceiling does not move. This is
the same structural reason the v2 risk/reward ratio could not be tuned with money.

## §D What this does and does not say

**It does not say freezing is wrong.** `F` is a free parameter, and at `F = 0.25`
days the ceiling is 12 cases a day even at `prior = 0.665`.

**It says the trade is between deterrence and throughput, and the dial is one
number.** A freeze long enough to deter a careless moderator is a freeze long
enough to throttle a careful one, and both effects scale with the same `F`.
Nothing separates them, because the penalty and the capacity are denominated in
the same unit — time.

**That is the actual difference between the two designs.** Under a freeze,
throughput is capped by accuracy, which cannot be bought. Under a debit,
throughput is not capped at all and *concurrency* is capped by capital,
`(bond − BOND_MIN)/λ`, which can be. A moderator who wants to do more work can
post more bond; no amount of anything lets them out from under `1/(F(1−p))`.

So the irony is worth stating plainly: **the design that grants infinite
concurrency delivers less usable throughput than the one that caps it**, because
the cap in the second is on something purchasable.

## §E Assumptions

1. Losses are independent across cases at rate `1 − p`. Correlated errors — a
   batch of similar content misjudged together — make the freeze bursty and
   lower the realised duty cycle further.
2. `p` is the probability of being **coherent with the verdict**, not of being
   right. They differ, and under a lottery verdict the gap is the floor in
   `FINDINGS-floor.md`.
3. A frozen identity earns nothing anywhere. That is the proposal's "the only
   penalty is freeze" read literally — a per-case freeze would be a different
   mechanism and is not modelled.
4. Nothing here prices the *deterrent* side. §D's claim is that one parameter
   controls both, not that any particular `F` is right.
