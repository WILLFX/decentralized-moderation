# Measuring `prior` (and `rho`)

Two numbers decide whether the rest of this project is worth building, and
neither has ever been measured.

- **`prior`** — how often an independent reader of the guidelines agrees with the
  ground truth. `simulation/v3/FINDINGS-v3.md` shows every safety figure in the
  design is a function of `q + (1−q)(1−prior)`, not of `q`: an honest moderator
  who misjudges the content votes with the attacker and the tally cannot tell them
  apart.
- **`rho`** — how correlated those judgments are across moderator configurations.
  `f(a) = 3a² − 2a³` is the CDF of the median of three uniforms, so it assumes
  independent draws. `v2-audit-checklist.md` P1-4 and §5.6 have carried
  "AI identities are not independent moderators" as DEFERRED since the first
  audit.

README §3.6 states the claim under test outright: *"Accuracy comes from the
guidelines being a clear Schelling point, not from cohort size."* The guidelines
are one line — **"Would Google SafeSearch return this?"** — and nobody has checked
whether independent readers converge on it.

## Why this comes before more specification work

Three audit rounds have produced roughly 24, 15 and 20 findings on
`state-machine-v3.md`, without converging. Meanwhile `design-v3.md` §8 makes
`REJECTED` **permanent and irreversible**, and justifies it with a false-rejection
rate of **0.725%** — which is `1 − f(0.95)`, i.e. the number you get at
`prior = 0.95`, `rho = 0`, and no attacker.

`simulation/v3/correlated.py` maps the surface. The 0.725% cell requires
**`prior ≈ 0.96+`, `rho ≈ 0`, and `q = 0` simultaneously.** Two of those three are
unmeasured, and the third is assumed away everywhere else in the design.

No amount of state-machine correctness moves those numbers.

## Running it

```python
from corpus import Item
from measure import Config, run, report

configs = [Config("gpt-x/temp0", my_classifier_a),
           Config("claude-y/temp0", my_classifier_b),
           ...]                      # >= 8 configs, >= 100 items — see below
report(run(configs, my_corpus, repeats=3), my_corpus)
```

A `Config` is what an *operator* actually runs — model, prompt, provider,
temperature. Two operators on the same model and prompt are **one** configuration
sampled twice, and counting them as two is precisely the error `rho` exists to
detect. `repeats > 1` separates model nondeterminism from genuine disagreement;
only the second is decorrelation the design can rely on.

Model access is yours to supply. `classify(system, user) -> bool` is the whole
interface.

## Reading the output

**Report `prior` per difficulty band, never as one average.** §8.4's permanence is
defensible at one band and not at another, and a single mean hides which. The
corpus must reflect the real submission mix: a corpus of hard cases measures the
wrong quantity and so does a corpus of easy ones.

**`rho` is unusable below ~8 configurations and ~100 items** — `rho_is_usable()`
says so, and the estimator reads *negative* on small samples even when errors are
strongly shared, because the per-item expectation is estimated from the same few
votes it is compared against.

Then feed both into `simulation/v3/correlated.py`.

## What the answer decides

| `prior` | consequence |
|---|---|
| **≈ 0.95+** | False rejection ~1% at `rho = 0`. §8.4's permanence is defensible, `SUPER_SAFE` is reachable, and the open findings in `state-machine-v3.md` are worth fixing. |
| **≈ 0.665** (v2's inherited borderline-case figure) | With *zero attackers*, ~27% of safe content is rejected and ~27% of unsafe content approved. That is not a search index, and no state machine repairs it. |

The measurement is cheap, needs no contract and no testnet, and it is the only
experiment here whose result changes what should be built.
