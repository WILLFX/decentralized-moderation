# Simulation

Every quantitative claim the repository makes comes from here. The normative
design is [`../specs/protocol.md`](../specs/protocol.md); nothing in this
directory is normative, and where a finding disagrees with the spec the finding
is either out of date or a reason to change the spec — never a silent third
design.

- **Runtime:** Python 3.9+, standard library only. No dependencies.
- **Exact where it can be.** Three of the four measurements enumerate a finite
  state space rather than sampling, so they have no seed and no confidence band.

## What is here

| findings | produced by | engine | method |
|---|---|---|---|
| `FINDINGS-floor.md` | `run_floor.py` | `floor.py` | exact + proved asymptotics |
| `FINDINGS-staged.md` | `run_staged.py`, `run_exact.py` | `staged.py`, `exact.py` | Monte Carlo, cross-checked against exact enumeration |
| `FINDINGS-floor-price.md` | `run_floor_price.py` | `floor_price.py` | exact binomial tails |
| the draw differential | `check_draw_vectors.py` | `draw.py`, `keccak.py` | re-derivation against contract-emitted vectors |

```bash
cd simulation
python3 run_floor.py          # the separability bound
python3 run_staged.py         # the staged pair, sampled
python3 run_exact.py          # the same comparison, enumerated
python3 run_floor_price.py    # pricing §11's per-committee minimum
python3 check_draw_vectors.py # after: forge test --match-test test_emitDrawVectors
```

## The four results, shortest form

**`FINDINGS-floor.md` — the one that outranks the others.** Safe and unsafe
content are distinguishable only when `prior > (1 + q/(1−q)) / 2`; at a 30%
attacker share that is `prior > 0.714`. Below it the tally is *anti-correlated*
with the truth and **no rule over it separates them** — not the lottery, not a
threshold, not unanimity, at any cohort size. It also establishes that the
lottery's error converges to a positive constant in cohort size while a
threshold's decays exponentially, which is a `Θ(1)` against `exp(−Θ(N))`
difference rather than a tuning question. `prior` is unmeasured; see
`../measurement/prior/`.

**`FINDINGS-staged.md` — the staged pair comes out worse, and the reason is
checkable on paper.** The preliminary outcome's tickets are drawn from the
*combined* tally of both committees, so capturing committee 1 alone buys nothing
and the staging does not create the separation it was meant to. Two engines that
share no code agree on it: `staged.py` samples a behavioural model, `exact.py`
enumerates the state space, and `run_exact.py`'s first experiment cross-checks
them before reporting anything else.

**`FINDINGS-floor-price.md` — a floor works, and costs most exactly where it is
needed.** Three identities that are the only committers take a case with
certainty (pinned in `../contracts/test/ThreeVote.t.sol`). A per-committee
minimum closes that; its price is cases that cannot resolve, and it turns
entirely on turnout, which is unmeasured. `k` between 2 and 4 is defensible at
20% turnout or better; nothing is defensible below 10%.

**The draw differential — the contract's ticket derivation, re-derived
independently.** `Draw.t.sol` constrains the *rate*, that the outcome tracks
`3a² − 2a³`. That is not enough: a domain-separation mistake keeps `u` uniform,
keeps the rate exactly right, passes every statistical test, and silently makes
two draws identical. So `check_draw_vectors.py` recomputes every `u[i]` from a
pure-Python keccak that refuses to load unless it reproduces published KATs, and
**sabotages its own derivation** — dropping the round from the preimage — failing
loudly if the comparison does not notice. A differential that agrees is only
evidence if it would have disagreed.

## `protocol_v3.py`, and a divergence to know about

`protocol_v3.py` is an engine for an **earlier design** — widening, quorum gates,
balance debits, `REVEAL_BOND`/`LAMBDA`. That design is gone and its findings file
is not on this branch. The module survives only because `staged.py` imports four
primitives from it: `a_hat`, `draw_tickets`, `verdict`, `f`.

One of those four does not match what is implemented. `a_hat` is the Laplace
estimator `â = (A+1)/(N+2)`; `Moderation._estimator` uses the **raw share
`A/N`**. So `FINDINGS-staged.md`'s numbers are computed against an estimator the
contract does not use. The direction of its conclusion does not depend on the
estimator — it rests on both committees' votes feeding one draw — but the figures
do, and raw `A/N` is the more permissive of the two, so the staged pair is if
anything worse than reported rather than better. Tracked as work to do, not as a
result to cite around.

Everything else here is estimator-independent: `floor.py` and `floor_price.py`
derive their own quantities, `exact.py` enumerates, and `draw.py` reproduces the
contract exactly by construction.

## What these models do not do

They are economic and statistical, not cryptographic, and they abstract network
timing, gas, and proposer influence over randomness. Turnout and honest error are
modelled as independent across identities; real moderators are correlated — the
same people are busy at the same times — and in every place it matters that
correlation makes the reported number optimistic rather than pessimistic. Each
findings file ends with its own assumptions section, and those are the places the
result could still be wrong.
