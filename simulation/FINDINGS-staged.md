# Staged committees — E24–E28

Produced by `run_staged.py` (engine: `staged.py`), 20,000 trials per cell.
Population 1,000, `q = 0.30`, `prior = 0.665`, honest availability 0.80,
attacker always-on and pay-insensitive.

The question, as asked:

> Conditional on the attacker obtaining a favourable first committee, what is
> the distribution of the final pooled vote after an independently hidden second
> committee?

**It has an answer, and the answer is that the question is the wrong one.**
Conditioning on a favourable first committee hides the term that decides the
outcome: how often a favourable committee exists at all. Staging improves the
first and worsens the second, by more.

---

## §A The headline

Four architectures. `A` is one committee per round; `B` is two committees with
the first tally visible to the second; `C` is two committees selected in sequence
with neither visible to the other; `D` is `C` plus challenge rounds with fresh
tickets each round, capped at two.

**Equal review effort** — `A` gets one committee of 40, `C` and `D` two of 20, so
every architecture puts the same expected number of reviewers on a case (E24b):

| architecture | attempts proceeded | admitted, given proceeded | **admitted per attempt** | attempts for 95% |
|---|---:|---:|---:|---:|
| A — one committee of 40 | 4.4% | 76.34% | **3.34%** | 88 |
| C — two staged of 20 | 23.5% | 58.51% | **13.73%** | 20 |
| D — staged + challenge | 23.1% | 67.63% | **15.62%** | 18 |

**Staging is four times worse per attempt, at the same review cost.**

## §B Why — and it is not subtle

Read the first two columns together. They move in opposite directions and the
second one wins.

*Conditional on proceeding*, staging works exactly as advertised: 76.34% → 58.51%,
an 18-point improvement. An attacker who captures one committee is genuinely
diluted by a second they could not see. **The protection the proposal claims is
real and it is measurable.**

But the attacker chooses when to proceed, and splitting one committee of 40 into
two of 20 raises the chance that *some* committee is favourable from 4.4% to
23.5% — more than five-fold. Two smaller draws have far more compositional
variance than one larger draw, and **the attacker needs only one of them to come
up favourable.** `mean_committed` is 1.07: they commit into one committee and let
the other run.

This is the standard result that splitting a sample and letting an adversary keep
the better half is worse than one whole sample. The staging is not the problem —
the *halving* is.

## §C The control, which is what settles it

E25 removes selection: the same attacker, forced to commit into every committee
whether favourable or not.

| architecture | admitted |
|---|---:|
| A — one committee | 58.38% |
| C — two staged, hidden | 59.09% |

**Staging itself does nothing.** Within noise, `C` equals `A` once the attacker
cannot choose. Every point of benefit in §A's second column came from changing
the *selection geometry*, and the same change hands the attacker more attempts
than it takes away.

## §D Robustness — the ordering never flips

E28 sweeps committee size and the threshold at which the attacker calls a
committee favourable, always at equal review effort. Campaign rate (admitted per
attempt made):

| reviewers/committee | favourable at | A: one of 2n | C: two of n | D: + challenge |
|---:|---:|---:|---:|---:|
| 10 | 40% | 23.47% | 36.62% | 47.34% |
| 10 | 50% | 9.34% | 24.59% | 29.70% |
| 10 | 60% | 1.77% | 10.02% | 11.98% |
| 20 | 40% | 18.61% | 32.39% | 40.98% |
| 20 | 50% | 3.06% | 13.20% | 15.95% |
| 20 | 60% | 0.18% | 2.71% | 2.89% |
| 40 | 40% | 12.37% | 25.75% | 32.85% |
| 40 | 50% | 0.40% | 4.62% | 5.54% |
| 40 | 60% | 0.01% | 0.18% | 0.25% |

`A < C < D` in all nine cells, and the gap **widens** as the defence gets
stronger: 11× at (40, 50%), 18× at (40, 60%). There is no corner of this
parameter space where splitting the committee helps.

## §E Fresh tickets per round cost more than the cap saves

`D` is worse than `C` everywhere — 58.51% → 67.63% conditional, and worse in all
nine robustness cells.

The mechanism is an asymmetry in who uses the extra draw. The attacker is
pay-insensitive, so they challenge **every** loss; the honest side challenges at
`h = 0.5`. Capping challenges at two bounds how many extra draws exist; it does
not change who takes them. A cap is a bound on the count, not on the asymmetry,
and the asymmetry is where the leak is.

`D` also draws 4.52 committees per attempt against `A`'s 1.00 — **2.3× the review
effort for 4.7× the campaign rate.**

## §F What the proposal got right, measured

E26 isolates the one thing the two-committee idea was actually diagnosing: that a
second committee which can see the first committee's tally will follow it,
because coherence is what pays.

| P(honest voter follows a visible lead) | B: tally visible | C: tally hidden | cost of visibility |
|---:|---:|---:|---:|
| 0% | 67.38% | 57.42% | +9.96pp |
| 15% | 72.67% | 57.42% | +15.25pp |
| 35% | 77.20% | 57.42% | +19.78pp |
| 50% | 81.35% | 57.42% | +23.93pp |
| 75% | 86.31% | 57.42% | +28.89pp |

**The economic feedback problem is real and large** — between 10 and 29 points
depending on how strongly voters conform, and it is 10 points even at zero
conformity, because a visible tally still lets the *attacker* size its
intervention.

So the diagnosis was right and the remedy was wrong. **Not publishing a running
tally is worth 10–29 points. Splitting the committee to achieve that costs four
times more than it saves.** Both can be had: one committee, and no tally
published before it closes.

## §G Censorship is symmetric

E27 runs the same four against safe content, attacker driving Reject. Within a
point of E24 throughout (A 75.48%, C 58.15%, D 68.03% conditional). Nothing here
is specific to the admission direction.

## §H What this does not model

Stated because the numbers are only as good as these.

- **Independent honest errors.** `prior` is applied per voter independently. Real
  correlated error — a content class every reviewer misreads — is not modelled
  and would raise every figure. It is not obvious that it changes the *ordering*,
  since it applies equally to all four.
- **Independent attempts.** `n@95%` assumes attempts do not share fate. Correlated
  content classes make it smaller, never larger.
- **Cost.** Attempts are counted, not priced. The nonrecoverable expense per
  attempt is what actually bounds a campaign, and it is not modelled here — but
  note `D` draws 2.3× the committees per attempt, so its cost per attempt is
  higher for the defender too.
- **Honest attendance at 80% and attackers always-on.** This asymmetry carries a
  lot of the result. It is the design's own stated assumption about motive.
- **`D` is flattered.** Its challenge rounds vote *after* a preliminary outcome
  has been published, so committees 3 and 4 can see which side is winning — the
  same exposure §F prices at 10–29 points. The engine does not apply the
  conformity penalty to them (`visible_lead` is passed only in architecture `B`).
  Modelling it would push `D` further down, never up, so the ordering in §A and
  §D is a lower bound on how much worse `D` is rather than an artefact.

## §I Conclusion

The proposal's diagnosis holds and its mechanism does not.

1. **Do not split the committee.** One committee of `2n` strictly dominates two
   staged committees of `n`, everywhere tested, at equal review effort.
2. **Do not publish a tally before voting closes.** Worth 10–29 points, and
   obtainable without staging.
3. **Fresh tickets per challenge round make the campaign rate worse**, and a cap
   on challenge count does not repair it, because the leak is the asymmetry in
   who takes the extra draw rather than how many exist.
4. The residual is unchanged by any of this: at `q = 0.30` the pooled draw has a
   floor no amount of honest review pushes below. That is a property of deciding
   admission by lottery, and it is the finding that outranks everything here.
