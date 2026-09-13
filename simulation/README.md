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

## One estimator, in one place

`estimator.py` holds the draw as `specs/protocol.md` §5 decides it and
`Moderation._estimator` implements it: the **raw share `A/N`**, the three tickets,
and the `u < a` comparison the contract makes by cross-multiplication. Both live
engines import it — `staged.py` samples, `exact.py` enumerates — and neither keeps
its own copy.

That is not tidiness. They did each keep their own copy, both of the Laplace form
`â = (A+1)/(N+2)`, which the contract does not use, so every figure in
`FINDINGS-staged.md` was computed against the wrong estimator until it was re-run.
The conclusions held — they rest on both committees' votes feeding one draw, which
is structural — but the figures moved, and in a direction worth knowing: Laplace
pulls the estimate toward 0.5, so it **understated** capture wherever the attacker's
share ran above half. At a 40% attacker share the old figure was 0.6726 against a
true 0.6954.

An engine for the superseded design (`protocol_v3.py` — widening, quorum gates,
balance debits, `REVEAL_BOND`/`LAMBDA`) used to live here as the source of those
primitives. It is gone; nothing imported it once `estimator.py` existed.

`floor.py`, `floor_price.py` and `draw.py` were never affected: the first two derive
their own quantities and the third reproduces the contract's keccak by
construction.

## What these models do not do

They are economic and statistical, not cryptographic, and they abstract network
timing, gas, and proposer influence over randomness. Turnout and honest error are
modelled as independent across identities; real moderators are correlated — the
same people are busy at the same times — and in every place it matters that
correlation makes the reported number optimistic rather than pessimistic. Each
findings file ends with its own assumptions section, and those are the places the
result could still be wrong.
