# Moderation Protocol Simulation (M1)

An agent-based simulation of the decentralized moderation game, written to turn
the README's *working values* into data-backed protocol parameters **before any
Solidity is written** (roadmap M1). It plays full cases — stake-weighted subset
draws, commit-reveal voting, stake-proportional probabilistic outcomes, bonded
appeals, and freeze-based settlement with no internal stake transfer — over
populations of honest and adversarial moderators, and prices each attack from
README §7 and §3.6.

- **Runtime:** Python 3.9+ standard library only. No dependencies to install.
- **Reproducible:** every scenario is seeded; pass `--seed` to vary.

## Quick start

```bash
cd simulation
python3 run.py all                 # run every scenario
python3 run.py whale-sweep         # attack success & attacker net vs stake share
python3 run.py honest              # honest-moderator ROI by difficulty
python3 tests/test_protocol.py     # invariant tests (no pytest needed)
```

Add `--json out.json` to any command to dump machine-readable results, and
`--trials N` to change the Monte-Carlo sample size (default 1500).

## What it models

The engine (`moderation_sim/protocol.py`) implements the case state machine of
`../specs/state-machine.md` §5. It is deliberately **economic, not
cryptographic**: commit-reveal is represented by its *effect* (hidden,
independent votes), not by hashing. Key abstractions, and where they diverge
from the chain, are documented at the top of `protocol.py`. The load-bearing
ones:

- **Seats, not weighted voters** (spec §5.2). Each round has N counted **seats**
  drawn stake-weighted **with replacement** — a large stake can win several. Every
  seat is one **flat vote**; the outcome is drawn ∝ seat counts (`_draw_seats`,
  `_draw_outcome`). Stake buys selection frequency, not vote weight (no
  double-count). No `weight_policy` knob.
- **Solvent settlement:** refunds first, bounty/bonus from the residual, so no
  case mints money (`test_settlement_conserves_funds`).
- **Freezing power** comes from the **seat-weighted mean** track of the winning
  side (split-resistant), and only *bites* in **campaign mode** (below).
- **Appeals are configurable, not assumed benign.** `Params.honest_appeal_threshold`
  (EV-gate) and `Params.naive_appeal_frac` (a caring honest side that appeals
  regardless) both drive results — the attacker's profit is a function of them,
  not a constant. Likewise `error_correlation` (shared honest blind spots).
- **No internal transfer:** settlement moves only external money (fees + forfeited
  bonds) to coherent voters; principal is untouched (`test_no_internal_stake_transfer`).

### Campaign mode (freeze must persist to matter)

`campaign.py::run_campaign` drives a persistent population on an absolute clock so
a frozen moderator is actually absent from later draws. The single-case scenarios
rebuild the population each trial, under which freezing is inert. All freeze,
farming, and veteran-effect results come from campaign mode; it is a sequential
approximation of overlapping cases (documented in `campaign.py`). Campaign
outcomes are high-variance, so they are averaged over several seeds with ±sd.

## Layout

```
simulation/
  run.py                       CLI: scenarios, sweeps, JSON output
  moderation_sim/
    params.py                  Params dataclass — every spec §1 symbol
    protocol.py                case engine: draw→commit→reveal→tally→appeal→settle
    campaign.py                persistent-population campaigns (freeze bites)
    agents.py                  voting strategies (honest, attacker, copy-voter)
    costs.py                   fee-floor cost model (gas + voter pay)
    scenarios.py               the attack experiments + sweeps
    metrics.py                 Monte-Carlo aggregation (± sd, per-case units)
  tests/test_protocol.py       invariant + sanity tests
  FINDINGS.md                  interpreted results, stated with their conditions
```

## Scenarios

| Command | Demonstrates (see FINDINGS for numbers + conditions) |
|---|---|
| `whale` / `whale-sweep` | Attack success vs (stake, difficulty, honest liveness). A minority whale is not powerless on borderline content with honest offline. |
| `naive` | Attacker net/case as a function of the honest side's appeal rationality — "attacker profits nothing" is conditional. |
| `track-farming` | Campaign-mode farming: bounded, not eliminated; split and concentrated both give no reliable attack-success uplift. Reports honest freeze p95. |
| `honest` | Honest ROI and correctness by difficulty (± sd); plus correlated-error rows. |
| `fee-floor` | Fee floor from per-vote op cost; gas negligible; margin ~2 clears borderline. |
| `copy` | Copy/correlated voting degrades correctness only as independence breaks; whale × copy helps the attacker. |
| `underparticipation` | Widen path holds correctness down to ~15% online. |

See `FINDINGS.md` for interpreted results **with their conditions and confidence
bands**, and `../specs/state-machine.md` §11 for the open-parameter list.

## Caveats

This is a first-generation model built to expose *directions and orders of
magnitude*, not to emit final constants. It abstracts network timing, exact gas,
proposer/randomness manipulation, and the *cost of acquiring* a stake majority
(the real external defense against supermajority capture, which the model does
not price). Campaign mode is a sequential approximation of concurrent cases, and
liveness/honest-error are modeled as i.i.d. where reality is correlated.

Crucially, the model is set up to **falsify** claims, not just confirm them: an
adversarial review showed several first-pass headlines depended on
defender-favorable assumptions, and the scenarios now relax those (content
difficulty, honest liveness, appeal rationality, correlated error). FINDINGS
reports what survives and what does not.
