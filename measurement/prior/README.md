# Measuring `prior` (and `rho`)

Two numbers decide whether the rest of this project is worth deploying, and
neither has been measured.

- **`prior`** — how often a moderator's judgment agrees with the truth.
  `simulation/FINDINGS-floor.md` shows every safety figure in the design is a
  function of `q + (1−q)(1−prior)`, not of `q`: a moderator who misjudges the
  content votes with the attacker and the tally cannot tell them apart. It derives
  the consequence exactly — safe and unsafe content are separable only when
  `prior > (1 + q/(1−q)) / 2`, which at a 30% attacker share is `prior > 0.714`.
  Below that bound **no rule over the tally separates them at any cohort size.**
- **`rho`** — how correlated those errors are. `f(a) = 3a² − 2a³` is the CDF of the
  median of three uniforms, so it assumes independent draws. If moderators err
  *together*, a cohort of N is one opinion sampled N times and the variance
  reduction the design pays a cohort for does not exist.

## The instrument is a testnet

**An earlier revision of this file said the measurement "needs no contract and no
testnet" and described a panel of model configurations or volunteer readers.**
That was wrong, and the simulation findings of the time said so in the same
repository, calling it the single most valuable measurement a testnet can make.
Two documents, one claim each, pointing opposite ways. This section is the
resolution; the reasons below are why the testnet wins, and none of them depend on
that older file, which is not on this branch.

The testnet is the right instrument for a reason that is not just convenience:

**It supplies the votes for free.** Every settled case is already a panel of
independent readers judging one item under pinned guidelines, having committed
before seeing anyone else's answer. That is the exact experimental design a
volunteer study would be trying to reconstruct, and the protocol enforces the
independence rather than asking people to respect it.

**It supplies the difficulty banding for free.** `prior` must be reported per band
and never as one average: the separability bound above is a threshold, so a design
can sit above it on ordinary content and below it on borderline content, and one
average hides exactly that. A hand-built corpus needs difficulty assigned by hand,
which is a judgment call about the very thing under test. A testnet does not: **the
tally is the band.** A case that split 17/17 was hard for the people who judged it;
33/1 was not. `band_of()` reads it off the revealed share directly.

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
  emit the moderator and their vote. `Moderation` keeps only `pooledApprove` /
  `pooledReject` in case state, which is correct for the contract and insufficient
  for this. It is the single highest-value line in this document: `rho` and the
  per-rater distribution both need `(rater, item)` keying and neither can be
  recovered from pooled counts afterwards.
- **The guidelines version and document hash, per case.** This does **not** exist.
  `MODERATION_GUIDELINES.md` claimed it did and no longer does; `specs/protocol.md`
  §11 now carries it as an open item. Cases decided under different guideline text
  are different experiments and must not be pooled — and with nothing recorded on
  chain, there is no way after the fact to tell which case belongs to which
  experiment. **Pinning it is a prerequisite for this measurement, not a nice-to-have.**

## The one thing that cannot wait for the testnet

**Write the guidelines you intend to ship, first.**

The testnet measures whatever text moderators were reading. A rewrite partway
through splits the data into two underpowered samples instead of one usable one —
and until the version is recorded per case (above), it splits it *invisibly*,
which is worse than splitting it. A rewrite is cheap, entirely within our control,
and closes one of the two failure modes outright:

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
turns every clarification into a governance event once versions are pinned per
case at all.

## What the model path is for, and it is not this

`Config` / `run()` in `measure.py` drive a panel of model configurations. That
answers a **different** question, and only if models ever moderate:

> Are AI identities independent moderators at all? Nothing in the design can tell
> a model apart from a person, so if models moderate, a cohort's independence is
> an assumption rather than a property.

For a human cohort, correlated error comes from shared ambiguity in the guidelines.
For a model cohort it also comes from shared training data, which is a much
stronger effect and the one that question is about. **If the moderator population
is human, the question is moot and the model path measures nobody who exists.**

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
already keyed `(rater, item)` for `rho`'s sake.

Be clear about what it is and is not for here. **It is not an argument for
reliability weighting.** `specs/protocol.md` §9 excludes vote weighting outright:
one identity, one vote, and influence bought only by staking more identities. An
earlier design measured what weighting would buy and that work is not on this
branch; none of its numbers should be quoted, and the spread is not being collected
to revive it.

What the spread is for under the current design:

- **`sd`** — whether the moderator population is uniform. If it is, the mean
  `prior` is the whole story and there is no better-and-worse to reason about. If
  it is not, then a per-band mean is an average over readers of visibly different
  accuracy, and the bound in §1 applies unevenly across the population.
- **`p95`** — an estimate of what a *motivated careful reader* achieves on this
  content mix, which is the attacker-capability input the separability bound needs
  and the one quantity that otherwise requires guessing. **The testnet measures it
  without labelling anybody hostile**: the best honest raters are careful readers,
  so the upper tail of the per-rater distribution is the estimate. Same votes, read
  at the top of the distribution instead of the middle — no panel, no separate
  study, no new instrument.

One trap, encoded in the docstring because it runs in the dangerous direction:
**`p95` is biased upward.** It is the near-maximum of a set of noisy estimates, so
it captures whoever got lucky as well as whoever is good. At 30 items a genuinely
0.665 rater reads 0.80 or better about 5% of the time — which is exactly the
quantile being reported. `min_items = 30` is a floor, not a target, and a `p95`
from thin data is an upper bound on an upper bound.

Then read the result against `simulation/FINDINGS-floor.md`, which is where `prior`
and `q` meet: the bound is stated there in closed form, so the measurement lands
directly on a threshold rather than needing another model run to interpret.

## What the answer decides

There is one threshold and it is not a soft one. `simulation/FINDINGS-floor.md`
derives it: safe and unsafe content are separable only when

```
prior  >  ( 1 + q/(1−q) ) / 2
```

| `prior` at the hard band | consequence |
|---|---|
| **comfortably above the bound** | The tally carries signal, and the remaining questions are the ones the rest of the repository is about — turnout, the per-committee floor, the cost of non-reveal, the parameter values in `specs/protocol.md` §11. |
| **near the bound** | The design works on ordinary content and fails on exactly the content a submitter would choose to send, which is why the figure must be reported per band and never as one average. |
| **below the bound** | A revealed vote is *more* likely to be Approve on unsafe content than on safe content. The tally is anti-correlated with the truth and **no rule over it separates them** — not the lottery, not a threshold, not unanimity, at any cohort size. Nothing in the state machine repairs that, and no parameter choice reaches it. |

At a 30% attacker share the bound is `prior > 0.714`. The two figures this project
has historically carried, 0.665 and 0.95, sit on opposite sides of it — and they
are not two guesses about how good people are, they are two different content
mixes. That is the whole reason the mix has to come from a testnet rather than a
corpus somebody assembled.

**This blocks deployment, not work.** The standing constraint already blocks
deployment. Nothing in `specs/` or `contracts/` waits on these numbers; what waits
on them is whether any of it should be launched with material funds, and whether
the index may be described as safe-search certification.
