# M1 Simulation — Findings (first pass)

Interpreted results from the agent-based model, with the parameter directions
they point to. Numbers below are from the default `Params` at 1000 trials/seed=1
(`python3 run.py all`); they are **orders of magnitude and directions**, not
final constants. Reproduce with the commands shown.

> Status: first-generation model. It confirms the qualitative security claims
> and ranks parameter regimes; it does not yet emit protocol constants. Each
> finding lists what to harden before M2.

---

## 1. The whale cannot buy a *certain* outcome, and profits nothing internally

`python3 run.py whale-sweep`

| attacker stake share | attack success (newcomer) | attacker net | attacker capital frozen (stake·days) |
|---|---|---|---|
| 20% | 0.39 | −1017 | 1.41M |
| 35% | 0.59 | −498 | 1.78M |
| 50% | 0.79 | −997 | 1.97M |
| 75% | 0.93 | −169 | 0.87M |
| 90% | 0.98 | +66 (≈0/case) | 0.24M |

**Reading.** Attack success rises smoothly with stake share — there is *no*
threshold at which the attacker becomes certain, and *no* threshold below which
it is powerless. This is the probabilistic-outcome design working: every attack
is a priced gamble (README §3.6 "Why not deterministic majority?").

Crucially, **attacker net is ≤ ~0 everywhere**. The only regime where it is
mildly positive is ~90% stake — and there it is +0.07/case, the residue of
occasional mis-timed honest appeals, not a farmable internal transfer. The
mechanism never pays the attacker; the sole prize is the listing itself (README
§4), which remains re-litigable. `tests/test_attacker_never_nets_large_profit`
guards this.

**Freeze drag is the real cost.** A sub-majority whale loses most rounds and has
its capital frozen for 1–2M stake·days per 1000 attacks. Against **veteran**
honest moderators the freeze is longer still (principle 4) — the `veteran`
columns of the sweep show larger per-round freeze duration at equal stake.

**Direction:** the security claim holds under the default `weight_policy="capped"`.
Before M2, re-run the sweep under `--weight-policy whole` and `fixed` to choose
§11.6: `whole` lets a whale dominate a single small round (higher success at
mid stake), `fixed` is egalitarian but re-opens identity-splitting pressure.
Recommend documenting the chosen policy as a first-class protocol parameter.

## 2. Honest moderators are paid, and losing a borderline draw is not ruinous

`python3 run.py honest`

| content difficulty | correctness | honest net / case | honest frozen (stake·days/1000) |
|---|---|---|---|
| 0.0 (clear) | 0.99 | +1.51 | 21.9k |
| 0.25 | 0.94 | +1.76 | 169k |
| 0.50 | 0.84 | +1.83 | 290k |
| 0.75 (borderline) | 0.74 | +1.86 | 373k |

**Reading.** Clear content finalizes correctly ~99% of the time and pays
moderators the fee with negligible freezing (principle 1: near risk-free on the
easy majority of cases). Borderline content produces more freezing, but honest
net stays **positive** — the fee/bond flow rewards honest judgment even where a
share of honest voters lose the draw. Freezing is deterrence, not confiscation,
so a frozen honest moderator keeps its principal.

**Direction.** `honest_net/case` is currently ≈ the fee floor. Whether that
clears the real cost of running an AI classifier is the `FEE_BASE`/`FEE_PER_TOPIC`
calibration (§11.7) — it needs a cost model of a moderation call, which this
sim does not yet include. Add one before fixing the fee floor.

## 3. Track-record farming is currently **too cheap** — hardening required

`python3 run.py track-farming`

- Farming 30 innocuous self-submissions cost the attacker **~13 xBZZ net**
  (45 in fees, 32 recovered as coherent rewards).
- That bought **freezing power 7.7 of a cap of 8** — near maximum.
- Post-farm, a 50%-stake attack froze honest moderators for **~2.5k stake·days
  per attack** while still netting the attacker nothing (−1100 over 1000
  attacks).

**Reading.** This is the README §7 open threat, quantified: with the default
`track_saturation=20` and `track_decay=0.98`, freezing power saturates far too
cheaply, and because `freezing_power` reads the *summed* track of the winning
side, **identity-splitting inflates it** (many modest-track identities sum to a
high aggregate). Farming does not help the attacker *win* (win-rate is unchanged
from the base whale), but it lets a determined attacker turn losses into long
honest freezes — a griefing vector.

**Direction (before M2):**
1. Base freezing power on a **split-resistant** aggregate of the winning side's
   track (e.g. stake-weighted mean, or max, not raw sum). Re-run this scenario
   under each and pick the one where split vs unsplit farming gives equal power.
2. Raise `track_saturation` and/or steepen `track_decay` so 30 cheap cases do
   not approach the cap. Sweep both and report farm-net-cost to reach power = 4×
   and 8×; target a farm cost that exceeds the freeze damage it can inflict.
3. Consider gating track increments on *undisputed* participations only (already
   the intent in spec §6.5; the model currently approximates it) and on a
   minimum stake, so min-stake identity farms accrue slowly.

## 4. Copy-voting / first-come racing is mild until independence badly breaks

`python3 run.py copy`

| copy-voter share | correctness (difficulty 0.1) |
|---|---|
| 0% | 0.97 |
| 50% | 0.97 |
| 75% | 0.96 |
| 95% | 0.93 |

**Reading.** Correctness is robust to a moderate share of copy-voters and only
degrades meaningfully near 95%. This quantifies *why commit-reveal matters*: its
job is to keep votes independent, and the cost of losing that independence is
bounded but real. Accepted for MVP (README §7 "First-come voting dynamics").

**Direction.** Keep commit-reveal; no parameter change indicated. If a future
model adds correlated AI-classifier errors (a realistic form of accidental
"copying"), re-check — correlated honest error is a more likely path to this
regime than deliberate copy-voting under working commit-reveal.

## 5. Liveness holds until moderators are very scarce online

`python3 run.py underparticipation`

| online share | correctness | avg latency (days) |
|---|---|---|
| 100% | 0.99 | 4.0 |
| 50% | 0.99 | 4.6 |
| 30% | 1.00 | 5.2 |
| 15% | 0.99 | 6.3 |
| 8% | 0.90 | 6.8 |

**Reading.** The widen-on-under-participation path (spec §5.2) keeps cases both
correct and roughly on-schedule down to ~15% of committers online; only at 8%
does correctness dip and latency stretch. This supports the README's liveness
argument for eligibility-over-a-subset (§3.3).

**Direction.** Confirm `MIN_REVEALS=3` and `max_widen` against a larger and more
realistically bursty online distribution; the current model uses an i.i.d.
`reveal_prob`, which understates correlated offline periods.

---

## Parameter directions summary (for spec §11 / M2)

| Spec §11 item | First-pass direction from this model |
|---|---|
| Subset fraction / `COMMIT_TARGET` | 5→11→23 keeps rounds decisive; revisit with correlated liveness. |
| `BOND_MULTIPLIER` | 2× makes honest re-litigation self-funding; not the binding constraint. |
| **Freeze `FREEZE_CAP` / `freezingPower` shape** | **Make split-resistant; raise cost to reach the cap — current default is farmable.** |
| **`TRACK_DECAY` / `TRACK_SAT` / anti-farming** | **Harden: 30 cases must not approach cap; gate on undisputed + min stake.** |
| Per-round reward weighting | Not yet differentiated; needs a variant that weights larger rounds more. |
| Per-case at-risk stake / `weight_policy` | Choose `whole`/`fixed`/`capped` deliberately; each shifts whale-in-one-round dynamics. |
| `FEE_BASE` / `FEE_PER_TOPIC` | Needs an external cost-of-a-moderation-call model before calibration. |
| `REVEAL_WINDOW` / under-participation | 3-reveal minimum robust to ~15% online; test correlated offline. |

**Bottom line.** The two structural security claims — *no certain attack* and
*no internal attack profit* — hold in the model and are test-guarded. The one
parameter family that is clearly unsafe at its working defaults is the
**track-record / freezing-power** machinery, which is exactly the sub-system the
README already flags as unresolved. That is the priority to harden before the
Solidity in M2.
