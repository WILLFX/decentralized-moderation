# v2 Simulation — Findings

Engine: `protocol_v2.py`. Experiments: `experiments_v2.py`. Run: `python3 run_v2.py`.
Design under test: `specs/design-v2.md`, `specs/state-machine-v2.md`.

These are simulation results, not proofs. The model gives the attacker every
advantage the design admits — their turnout is insensitive to pay, because their
prize is the listing and the listing is external to the protocol — while honest
turnout is a rational response to expected earnings net of freeze risk. That
asymmetry is the design's own claim about motives, not a pessimistic assumption.

**Headline: at the working parameters, honest turnout is zero.** The design is not
broken, but three parameters in it are, and one of them cannot be fixed by choosing
a better number.

---

## A. The freeze term makes honest moderation irrational, and no fee level fixes it

A suspension removes a moderator from **every** case for its duration. A reward
pays for **one** case. So:

```
downside = freeze_days × cases_per_day × pay_per_case
upside   = pay_per_case
ratio    = freeze_days × cases_per_day
```

Voting is rational only when `p / (1−p) > freeze_days × cases_per_day`, where `p`
is the moderator's confidence that the verdict will match their reading.

At the working values — `FREEZE_BASE` 7 days, ten cases a day — that ratio is 70,
so a moderator must be **98.6% confident** before voting is worth it. An honest
moderator's actual prior, with 30% of the population hostile and a 95%-clear case,
is **66.5%**.

**The fee cannot rescue this.** Raising the fee raises the reward *and* the
foregone earnings a suspension costs, by the same factor. The ratio is
fee-invariant. This is the map:

```
round-0 honest turnout, of a 32 cohort
                  fee 3     fee 9    fee 30    fee 90   fee 300
     freeze 7d      0.0       0.0       0.0       0.0       0.0
     freeze 1d      0.0       0.0       0.0       0.0       0.0
     freeze 6h      0.0       0.0       0.0       0.0       0.0
     freeze 1h      0.0       0.0      22.4      22.5      22.2
     no freeze      0.0      22.3      22.2      22.2      22.2
```

Read across a row: the fee buys turnout only against **gas**. Read down a column:
the freeze term is what actually gates participation.

Margin-scaling the freeze — a shorter term for losing narrowly than for losing
badly — was tested and does not rescue it. The problem is the absolute scale, not
the shape.

**What this means for the design.** Deterrence cannot come from the size of a
single penalty without making honest moderation irrational. It has to come from
**serial stacking** (`design-v2` §5): make the base term small — hours — and let
repeated losses accumulate. An honest moderator rarely loses and so rarely
accumulates; an attacker loses constantly and stacks up quickly. That is the same
mechanism the design already specifies, doing work nobody had asked it to do.

This also means `FREEZE_BASE` inherits nothing from the first architecture. Seven
days was calibrated for a design where being frozen also meant defaulting on an
assigned duty. There are no duties now.

---

## B. The dilution asymmetry is real and measurable

`design-v2` §4.6 predicted that a fixed pot split across a growing tally would
suppress honest turnout while leaving attacker turnout intact. It does.

```
honest votes per round (viable parameters, 32 cohort)
    q=0.20     25.6   23.6   22.7   20.5
    q=0.30     22.5   19.7   15.2    8.7
    q=0.40     19.2   12.9    5.6    1.7
```

The decline steepens with the attacker's share, because a larger hostile fraction
lowers every honest moderator's confidence of being coherent at the same time as
the pot thins.

The consequence shows up in the verdict rate. Pooling is supposed to hold
`P(attacker verdict)` at their population share `q`:

```
       q    P(attacker wins)    ratio
    0.10               0.126     1.26
    0.20               0.213     1.07
    0.30               0.418     1.39
    0.40               0.759     1.90
    0.50               0.959     1.92
```

At low `q` the claim holds. At `q ≥ 0.3` it does not: the attacker's share **of the
pool** exceeds their share of the population, because the honest half stops
turning up. Pooling still closes retry — that part of §4.5 stands — but it cannot
close a composition attack.

---

## C. More challenge rounds strictly favour the attacker

This one contradicts the intuition the design was built on.

```
    round cap    P(attacker wins)    last-round honest turnout
            1               0.335                         22.3
            2               0.352                         21.5
            3               0.348                         19.4
            4               0.418                          8.7
            6               0.873                          0.2
```

Rounds 1–3 are flat at roughly `q`. From round 4 the attacker's advantage climbs
sharply, and by round 6 the honest side has left entirely.

Challenges exist to correct wrong verdicts. Under dilution they systematically
transfer the pool toward whoever is insensitive to pay — which is the attacker, by
construction. **`MAX_ROUNDS` should be 2, not the 4 currently specified.** Three is
defensible; four is measurably worse than one.

---

## D. The trilemma — why dilution cannot simply be engineered away

The obvious fix is to stop diluting: give each round its own pot so pay per voter
stays constant. That is not available, and the reason is the neutrality theorem
itself.

Neutrality requires `E[pay]` to be independent of vote direction. With payment
`f(W)` to each winner:

```
E[pay | Approve] = (A/N)·f(A)      E[pay | Reject] = (B/N)·f(B)
```

Equality for all `A, B` forces `A·f(A) = B·f(B)`, hence `f(W) = c/W` — and the
total paid out is therefore the constant `c`, whatever the turnout. **Any scheme
that pays out more when more people vote breaks neutrality.** Per-round pots do
exactly that, and they fail the check directly: a round-`r` voter's expected pay
becomes `(A/N)·(pot_r/A_r)`, which is direction-independent only when the round's
composition happens to match the pool's.

So, pick two of three:

| | Neutral payouts | Free challenges | Non-diluting pay |
|---|---|---|---|
| **as designed** | ✅ | ✅ | ❌ |
| challenger pays a round fee | ✅ | ❌ | ✅ |
| per-round pots | ❌ | ✅ | ✅ |

The design currently takes the first row and caps the damage with `MAX_ROUNDS`.
The second row is the principled fix — a challenge fee that funds the round it
opens — but it reintroduces paying to challenge, which the design deliberately
removed. The third row is not available at any price.

**This is a decision, not a defect.** It needs the project owner and the senior
reviewer, and it should be made with the numbers in §C in front of it.

---

## Recommended working values

| Parameter | Was | Now | Why |
|---|---|---|---|
| `FREEZE_BASE` | 7 days | **≤ 1 hour** | §A. Deterrence moves to serial stacking. |
| `MAX_ROUNDS` | 4 | **2** | §C. Four is measurably worse than one. |
| `FEE_BASE` | — | **≥ 30 xBZZ** at 1h freeze, ≥ 9 with none | §A map. Buys turnout against gas only. |
| `TARGET_COHORT` | 32 | 32 — unchanged | Turnout saturates near 22 of 32; no evidence to move it. |

`FREEZE_BASE` at an hour is a factor of ~170 below the first architecture's value.
That is not a tuning adjustment, and it should not be adopted without the campaign
experiment that shows serial stacking actually supplying the deterrence the single
term no longer does. **That experiment does not exist yet** — this engine models one
case at a time, and stacking only bites across many. It is the next thing to build.

---

## What this engine does not yet model

Stated so nothing here is read as broader than it is.

- **Multi-case campaigns.** Serial freeze stacking is the mechanism §A leans on and
  it cannot be observed in a single-case model. This is the largest gap.
- **Reputation.** `TRACK_DECAY`, saturation, and freezing power are unimplemented,
  so §9 Q1 of the design is untouched.
- **Identity churn.** The attacker never abandons a suspended identity for a fresh
  one, which is the behaviour maturation and reputation exist to price.
- **The age-widening threshold.** Modelled, but no experiment sweeps
  `AGE_FACTOR_STEP` against time-to-quorum.
- **Removals.** Not modelled at all.
