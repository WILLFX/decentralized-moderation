# v2 simulation — the unassigned architecture

Models `specs/design-v2.md` / `specs/state-machine-v2.md`. Separate from
`../moderation_sim/`, which models the assigned-panel design and still validates
the contracts in `contracts/`. Neither replaces the other.

```
python3 run_v2.py
```

- `protocol_v2.py` — the case engine: hash eligibility, self-selected turnout,
  pooled tallies, serial freezes.
- `experiments_v2.py` — E1 pooling, E2 dilution, E3 fee, E4 round cap,
  E5 the viable region.
- `FINDINGS-v2.md` — **read this first.** Results, and what they say about the
  design's working parameters.

The model gives the attacker every advantage the design admits: their turnout is
insensitive to pay, honest turnout is not. That asymmetry is the design's own
claim about motives, not a pessimistic assumption.

**Not yet modelled:** multi-case campaigns (so serial freeze stacking is
unobserved — the largest gap), reputation, identity churn, removals.
