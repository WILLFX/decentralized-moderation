# v2 Simulation — Findings

Engine: `protocol_v2.py` (one case), `campaign_v2.py` (many concurrent cases).
Run: `python3 run_v2.py`. Design under test: **v2.1** — `specs/design-v2.md`,
`specs/state-machine-v2.md`.

The model gives the attacker every advantage the design admits: their turnout is
insensitive to pay, because their prize is the listing and the listing is external
to the protocol. Honest turnout is a rational response to expected earnings net of
freeze risk. That asymmetry is the design's own claim about motives.

**Headline: v2.1 fixes what the first run broke.** The pre-v2.1 design produced zero
honest turnout at every fee tested, and an attacker who beat their population share
by up to 90%. Both are gone.

> **Provenance warning — §A and §D are produced by risk units.** The senior reviewer
> has since ruled per-case reservation out. Sections **A** (the `F / D_case = 1.4`
> ratio, and the viability map that follows from it) and **D** (the flood ceiling of
> 3,000 concurrent attacker votes) are *caused* by the unit mechanism: A by per-unit
> freezing, D by the `n_att × K` ceiling. Neither result survives its removal, and
> **neither may be cited as evidence for an unlimited-concurrency design.** Sections
> B and C do survive — they follow from one-final-draw and `MAX_ROUNDS` 2, which are
> independent of units. An unlimited-concurrency variant needs a fresh run covering
> identity-wide penalty economics, pre-settlement attack waves, mass selective
> reveal and withdrawal liabilities. That run does not exist yet.

---

## What changed, measured

| | pre-v2.1 | v2.1 |
|---|---|---|
| Honest turnout at a 7-day freeze | **0 at every fee from 3 to 300** | 22 of 32, at fee ≥ 30 |
| Attacker verdict rate ÷ population share, q=0.3 | 1.48 | **1.13** |
| …at q=0.4 | 1.87 | **1.21** |
| Honest turnout across rounds, q=0.4 | 19.2 → 12.3 → 4.9 → **1.0** | 19.2 → **18.3** |
| Attacker concurrent votes under flood (1000 cases/day) | **unbounded** — 57,966 observed | capped at **3,000** |

---

## A. The freeze term no longer gates participation

The pre-v2.1 problem: a suspension removed a moderator from **every** case while a
reward paid for **one**, so the downside/upside ratio was
`freeze_days × cases_per_day` — 70 at the working values, requiring 98.6%
confidence against a 66.5% prior. No fee fixed it, because raising the fee raised
the foregone earnings identically.

Under v2.1 a loss freezes **the unit that backed the vote**, and a unit is occupied
by a case for `D_case` days. Freezing it for `F` days costs exactly the `F / D_case`
cases that unit would have run:

```
ratio = F / D_case = 7 / 5 = 1.4     ->  vote when confidence > 58.3%
                                         honest prior is 66.5%
```

**`K` cancels.** Throughput is bounded by the same `K`, so holding more units raises
foregone and available cases in the same proportion. The ratio is identical for a
minimum-stake moderator and a large one, and it does not move with the fee.

The viability map, which was flat zero above six hours before:

```
round-0 honest turnout, of a 32 cohort
                  fee 3     fee 9    fee 30    fee 90   fee 300
     freeze 7d      0.0       0.0      22.3      22.4      22.2
     freeze 1d      0.0      22.1      22.6      22.6      22.6
     freeze 6h      0.0      22.4      22.6      22.6      22.6
     no freeze      0.0      22.5      22.6      22.6      22.6
```

**The freeze term is no longer the binding constraint — gas is.** Read across the
7-day row: participation switches on between fee 9 and fee 30, and that threshold is
about the fee clearing gas, not about the penalty. Two earlier proposals are
superseded: this project's, to cut `FREEZE_BASE` to an hour, treated a symptom; the
review's, to divide the ratio by `K`, points the right way but implies large
moderators are safer than small ones, which the derivation says they are not.

**Caveat, stated because the arithmetic alone would overstate it.** The clean ratio
compares one case's pay against foregone cases' pay. Gas is charged per vote and
does not shrink, so at low fees voting stays unprofitable however cheap the penalty.
`FEE_BASE ≥ 30 xBZZ` at the working gas cost is what the map actually shows.

## B. Pooling now holds the attacker near their share

```
       q    P(attacker wins)    ratio      (pre-v2.1 ratio)
    0.10               0.125     1.25          1.15
    0.20               0.234     1.17          1.21
    0.30               0.339     1.13          1.48
    0.40               0.483     1.21          1.87
    0.50               0.686     1.37          1.91
```

The claim in `design-v2` §4.5 — that pooling holds `P(attacker verdict)` at their
population share — now roughly holds, where before it failed badly above q=0.3.

Two changes did it. **One final draw** removed the optional-stopping rule: with a
draw per round, a party who disliked a draw challenged and one who liked it stopped,
so `R` rounds approached `1 − (1−q)^R`. And **`MAX_ROUNDS` = 2** bounds how far the
pool's composition can be dragged by rounds the honest side has stopped attending.

It is not exactly 1.0 and should not be reported as such. The residual is the
composition effect: honest turnout still declines slightly across the two rounds.

## C. The dilution collapse is gone

```
honest votes per round, q=0.40
    pre-v2.1     19.2   12.3    4.9    1.0
    v2.1         19.2   18.3
```

Two causes removed at once: the freeze is affordable, so honest moderators keep
turning up; and with two rounds there is far less dilution to suffer.

**The trilemma has not been repealed.** Neutral payouts force `f(W) = c/W`, so the
total paid stays constant whatever the turnout, and dilution is still structurally
present. `MAX_ROUNDS` = 2 bounds it rather than solving it. Challenger-funded rounds
remain the principled fix and remain an open decision (`v2-audit-triage.md` D2).

## D. Risk units bound a flood, and only a flood

This is the experiment the first simulation could not run. A one-case-at-a-time
model has no "at once" in it, which is exactly where P0-1 was hiding — the external
review found it analytically because it read the design instead.

```
30-day horizon, 30% hostile, K=10, unit held 5+1 days

 cases/day    peak concurrent attacker votes
              unlimited      K units    bounded to    blocked
        10          623          623          100%          0
        40        2,405        2,273           95%        927
       100        5,884        2,999           51%     14,075
       250       14,543        3,000           21%     57,077
       500       29,022        3,000           10%    129,410
      1000       57,966        3,000            5%    273,393
```

Under v2.1 there is a **hard ceiling**: 300 hostile identities × K=10 = 3,000
concurrent votes, whatever the case rate. Under unlimited concurrency there is no
ceiling — the campaign grows with how many cases the attacker chooses to open, and
opening cases is the one thing the attacker fully controls.

**Note the shape.** At ordinary load the limit does not bind at all (100% at 10
cases/day, 95% at 40), so honest throughput is untouched. It binds precisely when
someone floods. That is the property that distinguishes this from returning to
assigned panels: nothing is reserved from anyone who did not choose to vote.

---

## What this engine still does not model

Stated so nothing here reads as broader than it is.

- **Selective reveal.** Committers who watch reveals arrive and withhold. v2.1
  prices this with `NONREVEAL_FREEZE`; nothing here tests whether the price is right.
- **Reputation.** Decay, saturation and freezing power are unimplemented, so the
  most load-bearing open parameter is untested.
- **Identity churn.** The attacker never abandons a frozen identity for a fresh one.
- **Settlement-order permutations.** v2.1 makes penalties order-independent by
  construction; that should be property-tested, not assumed.
- **Portfolio retry.** 100 substitute items at 30% gives ~30 listings, and nothing
  in v2.1 addresses it. This is the largest open finding and it is a decision, not a
  parameter (`v2-audit-triage.md` D1).
- **Successful-attacker fee recovery**, correlated AI error, bribery, proposer bias.
