# Measuring `prior` (and `rho`)

Two numbers decide whether the rest of this project is worth deploying, and
neither has been measured.

- **`prior`** — how often a moderator's judgment agrees with the truth.
  `simulation/FINDINGS-v3.md` shows every safety figure in the design is a
  function of `q + (1−q)(1−prior)`, not of `q`: a moderator who misjudges the
  content votes with the attacker and the tally cannot tell them apart.
- **`rho`** — how correlated those errors are. `f(â) = 3â² − 2â³` is the CDF of the
  median of three uniforms, so it assumes independent draws. If moderators err
  *together*, a cohort of N is one opinion sampled N times and the variance
  reduction the design pays a cohort for does not exist.

## The instrument is a testnet

**An earlier revision of this file said the measurement "needs no contract and no
testnet" and described a panel of model configurations or volunteer readers.**
That was wrong, and `FINDINGS-v3.md` said so in the same repository — *"the single
most valuable measurement a testnet can make."* Two documents, one claim each,
pointing opposite ways.

The testnet is the right instrument for a reason that is not just convenience:

**It supplies the votes for free.** Every settled case is already a panel of
independent readers judging one item under pinned guidelines, having committed
before seeing anyone else's answer. That is the exact experimental design a
volunteer study would be trying to reconstruct, and the protocol enforces the
independence rather than asking people to respect it.

**It supplies the difficulty banding for free.** `prior` must be reported per band
and never as one average (§8.6's permanence is defensible at one band and not
another). A hand-built corpus needs difficulty assigned by hand, which is a
judgment call about the very thing under test. A testnet does not: **the tally is
the band.** A case that split 17/17 was hard for the people who judged it; 33/1 was
not. `band_of()` reads it off `â` directly.

**It samples the real submission mix.** This is the one a volunteer panel cannot
fix at any budget. `prior` is not a property of readers alone — it is a property of
readers *and* what they are shown. The 0.665 and 0.95 figures this project carries
are not two guesses about how good people are; **they are two different content
mixes**, borderline and ordinary. A corpus of hard cases measures one, a corpus of
easy ones the other, and choosing the mix is choosing the answer. A testnet is
shown whatever submitters send — which is the distribution the design will actually
face, including whatever an adversary chooses to send.

## What you still have to supply

Ground truth, on a **sample** of settled cases — not on all of them. The chain
records what moderators said; it cannot record what was correct.

Sample stratified by band, because the bands have very different `prior` and the
hard band is the one that matters: a submitter choosing what to send will choose
borderline content, so the hard-band figure is the security-relevant one and the
average flatters it.

```python
from measure import CaseRecord, from_testnet, report

cases = [CaseRecord(id=..., votes={moderator: approved, ...}, truth=...), ...]
report(*from_testnet(cases))
```

`votes` is per-moderator so `rho` can separate moderator quality from item
difficulty. The aggregate `(A, R)` alone is enough for a Beta-binomial fit but not
for that separation.

## What the testnet must record

Nothing the design does not already produce, with one requirement worth stating
because it is easy to omit:

- **Per-moderator revealed votes**, not only the pooled counts. `reveal()` must
  emit the moderator and their vote. `specs/protocol.md` §4.1 stores only
  `pooledApprove` / `pooledReject`, which is correct for the contract and
  insufficient for this. **This one requirement now carries three measurements
  rather than one** — `rho`, and both halves of the reliability spread below — so
  it is the single highest-value line in this document.
- **The pinned `guidelinesVersion` per case** (§4.1 already pins it). Cases decided
  under different guideline text are different experiments and must not be pooled.

## The one thing that cannot wait for the testnet

**Write the guidelines you intend to ship, first.**

The testnet measures whatever text is pinned into its cases. A rewrite partway
through fragments the data along `guidelinesVersion` and you get two underpowered
samples instead of one usable one. And a rewrite is cheap, entirely within our
control, and closes one of the two failure modes outright:

- readers disagree with **each other** → the sentence is ambiguous → rewrite it
- readers agree with each other but not the **truth** → the sentence is clear and
  points somewhere we did not intend → rewrite it
- readers agree on easy items and scatter on hard ones → the sentence is fine and
  the content is genuinely hard → **not fixable by writing**, and this is the case
  the measurement exists for

Only the third needs a testnet. The first two need an afternoon and a text editor,
and doing them afterwards wastes the run.

Note that clarity of the *instruction* is not determinacy of the *answer*.
"Would Google SafeSearch return this?" is a perfectly clear instruction; what is
unclear is the answer for a borderline image, and no rewrite reaches that. The
alternative — enumerating what to reject — produces a rulebook that is harder to
apply identically than one sentence, has gaps that are judgment calls again, and
becomes a governance surface because §4.1 pins its version per case.

## What the model path is for, and it is not this

`Config` / `run()` in `measure.py` drive a panel of model configurations. That
answers a **different** question, and only if models ever moderate:

> **P1-4** — "AI identities are not independent moderators." `v2-audit-checklist.md`
> §5.6 has carried it DEFERRED since the first audit.

For a human cohort, correlated error comes from shared ambiguity in the guidelines.
For a model cohort it also comes from shared training data, which is a much
stronger effect and the one P1-4 is about. **If the moderator population is human,
P1-4 is moot and the model path measures nobody who exists.**

A `Config` is what an *operator* runs — model, prompt, provider, temperature. Two
operators on the same model and prompt are **one** configuration sampled twice, and
counting them as two is precisely the error `rho` exists to detect.

## Reading the output

**Report `prior` per band, never as one average.**

**`rho` is unusable below roughly 8 raters and 100 items** — `rho_is_usable()` says
so, and the estimator reads *negative* on small samples even when errors are
strongly shared, because the per-item expectation is estimated from the same few
votes it is compared against.

**Report the *spread* of `prior`, not only its mean.** `reliability_spread()` does
this and `report()` prints it. It costs nothing extra to collect — the votes are
already keyed `(rater, item)` for `rho`'s sake — and it answers a question the mean
cannot:

- **`sd`** — whether reliability weighting is worth having.
  `simulation/FINDINGS-weighted.md` §1 measures the gain as a function of this
  and finds it **exactly zero at zero spread**. If moderators are uniform there is
  nothing to sort. At `sd = 0.157` weighting is worth 15 points of false approval;
  at 0.273, 32 points. Nothing else measured in this project moves that number.
- **`p95`** — whether it is *safe* to have. Weighting is farmable: an attacker
  never has to dodge a known-answer case, because he can answer everything
  honestly except the one case he is attacking, so his score measures his
  **judgment** rather than his behaviour. Above a crossover he ends up holding
  more of the weight than the heads — 65% from 35% at the extreme — and no weight
  cap removes it (§6). The crossovers are **0.797** at `prior` 0.665 and **0.967**
  at 0.95.

**The testnet can measure the attacker's side of that without labelling
attackers.** It does not need to know who is hostile: the quantity that matters is
what a *motivated careful reader* achieves on this content mix, and **the best
honest raters are careful readers**. The upper tail of the per-rater distribution
is the estimate. No panel, no separate study, no new instrument — the same votes,
read at the top of the distribution instead of the middle.

One trap, encoded in the docstring because it runs in the dangerous direction:
**`p95` is biased upward.** It is the near-maximum of a set of noisy estimates, so
it captures whoever got lucky as well as whoever is good. At 30 items a genuinely
0.665 rater reads 0.80 or better about 5% of the time — which is exactly the
quantile being reported. `min_items = 30` is a floor, not a target, and a `p95`
from thin data is an upper bound on an upper bound.

Then feed `rho` into `simulation/correlated.py`, and the spread into
`simulation/run_weighted.py` as `concentration` and `attacker_gold_accuracy`.

## What the answer decides

| `prior` | consequence |
|---|---|
| **≈ 0.95+** | False rejection ~1.7% at `rho = 0`, and `simulation/FINDINGS-v3.md` §H puts the irrecoverable share at 0.7%. §8.6's permanence is defensible, `SUPER_SAFE` is reachable, and grinding a listing by resubmission costs ~229 fees. |
| **≈ 0.665** | With *zero attackers*, ~29% of safe content is rejected — 22.8% of it with no recourse that can reach it (§H) — and ~29% of unsafe content approved, with 9 resubmissions enough to list anything. That is not a search index, and no state machine repairs it. |

And one row the spread decides on its own:

| `sd` and `p95` | consequence |
|---|---|
| **`sd` ≈ 0** | Reliability weighting is inert. Whatever `prior` turns out to be, the design is stuck with it and the only remaining lever is better moderators or fewer of the hard cases. |
| **`sd` large, `p95` < crossover** | Weighting is worth 15–32 points of false approval, most of it at the low `prior` where the design is weakest. This is the largest improvement anything measured here has produced. |
| **`p95` ≥ crossover** | Weighting runs in reverse at comparable magnitude and is not adoptable at any weight cap. |

**This blocks deployment, not work.** The standing constraint already blocks
deployment. Nothing in `specs/` or `contracts/` waits on these numbers; what waits
on them is whether any of it should be launched with material funds, whether the
index may be described as safe-search certification, and — now — whether
reliability weighting is an improvement or an own goal.
