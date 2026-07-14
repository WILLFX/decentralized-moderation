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

- **Counted voters** are drawn stake-weighted without replacement
  (Efraimidis–Spirakis). Subset eligibility (1–10%) followed by
  "first-N-commits-count" collapses to this single draw under the assumption
  that response speed is independent of stake.
- **Outcomes** are drawn with probability proportional to the stake behind each
  side (`_draw_outcome`).
- **Vote weight** — how much stake a counted voter puts behind its side — is a
  policy knob (`Params.weight_policy`: `whole` / `fixed` / `capped`), because it
  is an open spec question (§11.6).
- **Appeals** are EV-gated: an appellant bonds only when its own side showed
  real strength in the round just decided. This is why a dominant whale earns
  nothing from honest appellants (they rationally decline to fund a lost cause).
- **No internal transfer:** settlement moves only external money (fees +
  forfeited bonds) to coherent voters; principal is never touched. Enforced by
  `tests/test_no_internal_stake_transfer`.

## Layout

```
simulation/
  run.py                       CLI: scenarios, sweeps, JSON output
  moderation_sim/
    params.py                  Params dataclass — every spec §1 symbol
    protocol.py                case engine: rounds, draws, appeals, settlement
    agents.py                  voting strategies (honest, attacker, copy-voter)
    scenarios.py               the README §7 attack experiments
    metrics.py                 Monte-Carlo aggregation
  tests/test_protocol.py       invariant + sanity tests
  FINDINGS.md                  what the runs show + parameter recommendations
```

## Scenarios

| Command | README ref | Demonstrates |
|---|---|---|
| `whale` / `whale-sweep` | §3.6, §4 | A stake majority cannot force an outcome with certainty and earns nothing internally; cost = fees + forfeited bonds + freeze drag. |
| `bond-war` | §3.6 | Honest challengers re-litigate whale wins up the appeal ladder; who funds whom. |
| `track-farming` | §7 | Cost of manufacturing freezing power via innocuous self-submissions vs the power gained. |
| `honest` | principle 1 | Honest-moderator ROI on clear vs borderline content; losing a borderline draw is annoying, never ruinous. |
| `copy` | §7 | First-come racing / copy-voting degrades correctness only as independence breaks — quantifies why commit-reveal matters. |
| `underparticipation` | §5.2 | Offline moderators trigger subset widening; effect on liveness and correctness. |

See `FINDINGS.md` for the interpreted results and the parameter directions they
point to. The parameters this simulation exists to resolve are enumerated in
`../specs/state-machine.md` §11.

## Caveats

This is a first-generation model built to expose *directions and orders of
magnitude*, not to emit final constants. It abstracts network timing, gas,
proposer/randomness manipulation, and heterogeneous AI-classifier error
correlation. Extending it toward those is future M1 work; the current model is
enough to falsify the qualitative claims (and it does confirm them) and to rank
parameter regimes against each other.
