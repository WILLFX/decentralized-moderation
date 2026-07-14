# M1 Simulation — Findings

Interpreted results from the agent-based model, with the parameter decisions they
drove. Numbers are from the default `Params` (`python3 run.py all`, 1200–1500
trials, seed 1); they are **orders of magnitude and directions**, not final
constants. Reproduce with the commands shown.

> Status: the model confirms the structural security claims, is test-guarded, and
> has resolved the two design questions that were open at first pass — the
> stake **double-count** and **track-record farming**. Remaining open items are
> calibration magnitudes, not structure (spec §11).

---

## 0. Headline decision — stake buys one benefit, not two

A design review caught that the first model let stake help the *same* moderator
twice in a case: stake-weighted **selection** put a large stake on the panel more
often, and a stake-weighted **tally** then let it swing the verdict harder once
there. The protocol now grants stake exactly one benefit:

- **Selection** is stake-weighted **with replacement** — a round has N seats and
  a large stake can win several, in proportion to its size (Kleros sortition).
- **Voting is flat** — every seat is one vote; the outcome is drawn ∝ the seat
  counts behind each side.

The alternative (uniform selection + stake-weighted vote) was rejected on Sybil
grounds: with a `MIN_STAKE` floor, splitting capital into floor-sized identities
maximises panel presence under uniform selection, re-introducing stake-weighting
through identity count and *rewarding* Sybils. Stake-weighted selection is what
keeps splitting neutral (spec §5.3, invariant 10; `test_first_round_outcome_
tracks_stake_share`).

**Effect (whale sweep, below): minority attackers got much weaker.** A 20%-stake
whale's success fell from 0.39 (old double-count) to **0.047**; a 35% whale from
0.59 to 0.26. Removing the second, stake-weighted, benefit is what stops a
minority from buying outsized influence — a strict improvement for a safe-search
index, where a minority should not be able to force approvals.

## 1. The whale cannot buy a certain outcome, and profits nothing internally

`python3 run.py whale-sweep`

| attacker stake share | attack success | attacker net / case | attacker capital frozen (stake·days) |
|---|---|---|---|
| 20% | 0.05 | −1.91 | 7.8M |
| 35% | 0.26 | −2.28 | 15.5M |
| 50% | 0.66 | −1.05 | 12.5M |
| 60% | 0.89 | −0.12 | 5.7M |
| 75% | 0.98 | +0.10 | 1.3M |
| 90% | 1.00 | +0.01 | 0.01M |

**Reading.** Success is a smooth S-curve in stake share — no threshold of
certainty, no threshold of powerlessness (README §3.6 "Why not deterministic
majority?"). **Attacker net is ≤ ~0 everywhere.** Below 60% it is firmly negative
(bonds forfeited + fees) and the capital is frozen for millions of stake·days;
above 75% it approaches zero, the tiny positive residue being honest
appeal-variance bonds (external money from honest players who appeal an
overturnable-looking round and lose), never a stake transfer. It is bounded by
the honest appeal threshold and is test-guarded to stay near zero
(`test_attacker_never_nets_large_profit`). The only prize is the listing itself
(README §4), which stays re-litigable.

## 2. Honest moderators are paid, and losing a borderline draw is not ruinous

`python3 run.py honest`

| content difficulty | correctness | honest net / case | honest frozen (stake·days/1000) |
|---|---|---|---|
| 0.0 (clear) | 1.00 | +1.48 | 29k |
| 0.25 | 0.99 | +1.53 | 188k |
| 0.50 | 0.93 | +1.59 | 392k |
| 0.75 (borderline) | 0.85 | +1.63 | 608k |

**Reading.** Clear content finalizes correctly ~100% of the time with little
freezing (principle 1: near risk-free on the easy majority of cases). Borderline
content freezes more honest voters, but honest net stays **positive** throughout
— honest judgment is paid even where a share of honest voters lose the draw, and
freezing is deterrence, not confiscation (a frozen moderator keeps its
principal). Correctness under flat voting is *higher* than under the old
stake-weighted tally, because no single large voter can drag a clear case.

**Open (§11.5).** `honest_net/case ≈ the fee floor`. Whether that clears the real
cost of running an AI classifier needs an external cost-of-a-moderation-call
model, which this sim does not yet include. Add one before fixing `FEE_BASE`/
`FEE_PER_TOPIC`.

## 3. Track-record farming — resolved (was the main flagged weakness)

`python3 run.py track-farming`

| farm effort | net cost (xBZZ) | mean track | freezing power | freeze vs non-farmed attacker |
|---|---|---|---|---|
| 30 cases | ~21 | 1.8 | **1.6×** | **1.05×** (no advantage) |
| 200 cases | ~150 | 10.4 | 3.8× | 1.49× |

**Reading.** The earlier model derived freezing power from the *summed* track of
the winning side, so a cheap 30-case farm (~13 xBZZ) bought **7.7×** power and,
worse, identity-splitting inflated the sum. Two changes fixed it (spec §6.4–6.5):

1. **Seat-weighted mean, not sum** — splitting a history across identities cannot
   inflate an average, so Sybil farming buys nothing. (`test_modest_farm_buys_
   little_freeze_power` guards this.)
2. **Accrual gated** on undisputed + coherent + `MIN_STAKE` participations, so a
   min-stake identity farm accrues slowly.

Now a 30-case farm buys ~1.6× power and **no measurable freeze advantage** over
an equal-stake attacker that never farmed; reaching even ~3.8× costs ~150 xBZZ
over 200 cases (which the honest side collects as fees). Farming never helped the
attacker *win* (win-rate matches the base whale), and now it barely helps it
grief either. `TRACK_SAT=20`, `TRACK_DECAY=0.98` hold up as calibrated defaults.

## 4. Copy-voting / first-come racing is mild until independence badly breaks

`python3 run.py copy`

| copy-voter share | correctness (difficulty 0.1) |
|---|---|
| 0% | 1.00 |
| 50% | 0.96 |
| 75% | 0.94 |
| 95% | 0.94 |

**Reading.** Robust to a moderate share of copy-voters; it degrades only as
independence is largely lost. This quantifies *why commit-reveal matters* — its
job is to keep the seat votes independent — and the cost of losing it is bounded.
Accepted for MVP (README §7). No parameter change indicated.

## 5. Liveness holds until moderators are very scarce online

`python3 run.py underparticipation`

| online share | correctness | avg latency (days) |
|---|---|---|
| 100% | 1.00 | 4.1 |
| 50% | 1.00 | 4.6 |
| 30% | 1.00 | 5.3 |
| 15% | 0.99 | 6.3 |
| 8% | 0.92 | 6.9 |

**Reading.** The widen / re-draw path (spec §5.2) keeps cases correct and roughly
on schedule down to ~15% of drawn seats online; only at 8% does correctness dip
and latency stretch. Supports the liveness argument of README §3.3.

**Open (§11.6).** The model uses an i.i.d. `reveal_prob`, which understates
correlated offline periods; re-check `MIN_REVEALS`/`max_widen` against bursty
liveness.

---

## Parameter decisions and remaining calibration (spec §11)

| Item | Status |
|---|---|
| **Per-case stake benefit (double-count)** | **Decided:** stake-weighted seat selection (with replacement) + flat voting. §5.3. |
| **Freezing-power formula** | **Decided:** saturating curve over seat-weighted **mean** winning-side track. §6.4. |
| **Track-record anti-farming** | **Decided:** mean-not-sum + accrual gated on undisputed/coherent/min-stake. §6.5. |
| Subset fraction / `COMMIT_TARGET` (seats) | Open: 5→11→23 keeps rounds decisive; revisit with correlated liveness. |
| `BOND_MULTIPLIER` magnitude | Open: 2× makes honest re-litigation self-funding; structure (bond ≥ 2×pot) fixed. |
| `FREEZE_BASE`/`FREEZE_CAP`, `TRACK_SAT`/`TRACK_DECAY` magnitudes | Open: current defaults defensible; fine-tune with `--track-saturation`/`--track-decay`. |
| Per-round reward weighting | Open: not yet differentiated; needs a variant weighting larger rounds more. |
| `FEE_BASE`/`FEE_PER_TOPIC` | Open: needs an external cost-of-a-moderation-call model. |
| `REVEAL_WINDOW` / under-participation | Open: 3-reveal minimum robust to ~15% online; test correlated offline. |

**Bottom line.** The structural security claims — *no certain attack*, *no
internal attack profit*, *Sybil-neutral selection* — hold in the model and are
test-guarded. Both design questions that were open at first pass (the stake
double-count and track-record farming) are now closed with justified formulas and
before/after numbers. What remains is magnitude calibration, which is exactly the
kind of thing that should stay open until M2 has a gas/cost model to calibrate
against.
