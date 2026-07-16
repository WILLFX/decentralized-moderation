# M1 Simulation — Findings

Interpreted results from the agent-based model. This document was **substantially
rewritten after an adversarial review** (two blind reviewers plus a context-aware
audit) found that the earlier headlines were produced by defender-favorable
modeling assumptions and one accounting bug. The claims below are stated with
their conditions and confidence bands; where the mechanism has real limits, they
are named rather than smoothed over.

Numbers are from `python3 run.py all` at 800 trials, means over 5 seeds ± sd.
They are **directions and orders of magnitude**, not final constants.

> Status. Structural bugs are fixed and test-guarded (settlement solvency,
> two-seed randomness, index-at-settlement, draw-then-commit). The security
> *headlines* are now reported conditionally: several depend on assumptions
> (honest appeal rationality, content difficulty, liveness symmetry) that, when
> relaxed, move or reverse them. What the mechanism guarantees is narrower than
> the first pass claimed — see §7, *Limits*.

## Methodology notes

- **Campaign mode.** Freezing only matters if a frozen moderator is absent from
  later draws. The single-case scenarios rebuild the population every trial, so
  freeze was inert (zero frozen moderators at any eligibility check). Freeze
  results here come from `run_campaign`: a persistent population on an absolute
  clock. It is a *sequential approximation* — cases arrive faster than they
  resolve, so many overlap; we resolve each fully before the next, which slightly
  front-loads freeze onset (if anything favorable to the freeze deterrent).
- **Variance.** Freeze is a compounding feedback loop, so a single campaign is a
  high-variance random walk. Campaign results are averaged over 5–8 seeds and
  reported with ±sd; several have sd large enough that only the sign and rough
  magnitude are meaningful.
- **Point estimates → bands.** All headline tables carry ±sd over seeds. The
  earlier single-seed numbers should not be compared directly.

---

## 1. The whale: success rises smoothly with stake; a minority is NOT powerless

`python3 run.py whale-sweep` — clear content, full honest liveness:

| attacker stake | attack success | attacker net/case |
|---|---|---|
| 20% | 0.049 ± 0.006 | −1.89 |
| 35% | 0.253 ± 0.020 | −2.15 |
| 50% | 0.651 ± 0.006 | −1.43 |
| 60% | 0.862 ± 0.010 | −0.76 |
| 75% | 0.982 ± 0.006 | −0.10 |
| 90% | 1.000 ± 0.001 | −0.02 |

But an attacker **chooses** borderline content and stays online while honest
liveness fluctuates. A 35%-stake minority whale:

| difficulty \ honest online | 1.0 | 0.5 | 0.3 |
|---|---|---|---|
| 0.0 | 0.253 | 0.600 | **0.824** |
| 0.25 | 0.415 | 0.704 | 0.877 |
| 0.50 | 0.601 | 0.794 | **0.901** |

**Reading.** The old "minority whales are near-powerless" claim held only for
clear content against a fully-online honest set. A 35% attacker that picks
plausibly-borderline content and exploits honest downtime wins **~0.82–0.90** of
the time. Attacker success is a function of (stake, content difficulty, honest
liveness), not stake alone. The *net cost* while a minority stays negative (bonds
+ fees), so the attack is not free — but "cannot force outcomes" is false for a
determined minority that controls its content and timing.

## 2. "Attacker profits nothing" is conditional on honest appeal rationality

`python3 run.py naive` — 60%-stake whale, varying the share of *naive* honest
challengers (who appeal any wrong approval regardless of their seat share):

| naive share | attacker net/case | attack success |
|---|---|---|
| 0.00 | −0.76 ± 0.15 | 0.86 |
| 0.25 | +0.29 ± 0.31 | 0.82 |
| 0.50 | +1.13 ± 0.53 | 0.73 |
| 1.00 | **+6.38 ± 0.83** | 0.51 |

**Reading.** With a fully EV-rational honest side (naive share 0), the whale's
net is negative — the earlier headline. But honest moderators who *care about the
index* will appeal wrong approvals of unsafe content even when the odds are poor,
and their forfeited bonds flow to the winning attacker. At half naive, the whale
nets **positive**; at fully naive, strongly positive. The stake-invariant
(principle 2) still holds — this is *bond* flow (external money the honest side
chose to post), never a stake transfer — but the clean "no attack pays from the
inside" reading depends on honest actors not over-appealing. The honest guidance
"appeal wrong outcomes" and the guideline "when in doubt, reject" both push toward
*more* appealing, so this tension is real and should inform the appeal-bond and
window parameters.

## 3. Honest moderators are paid, and a borderline loss is not ruinous

`python3 run.py honest` (mean ± sd, 5 seeds; op cost 0, so net ≈ pot share):

| difficulty | correctness | honest net/case | honest freeze/case (stake·days) |
|---|---|---|---|
| 0.0 | 1.000 ± 0.000 | +1.485 | 21.6 |
| 0.25 | 0.985 ± 0.002 | +1.485 | 152.6 |
| 0.50 | 0.938 ± 0.005 | +1.484 | 335.0 |
| 0.75 | 0.864 ± 0.016 | +1.483 | 501.3 |

Freeze *duration* on borderline content in a mature (veteran) network, from
campaign mode: **mean 10.9d, p95 11.6d, max 11.7d** — under the 21-day
"annoying, not ruinous" bar (principle 1). Honest net stays positive; correctness
is high on clear content and degrades gracefully with difficulty.

## 4. Track-record farming — bounded, not eliminated

`python3 run.py track-farming` (campaign mode; recalibrated FREEZE_CAP=4,
TRACK_SAT=60, TRACK_DECAY=0.95):

| farm strategy | freezing power | attack-success uplift vs unfarmed |
|---|---|---|
| split (identity 100) | 1.15 | +0.02 ± 0.21 |
| mid (identity 1000) | 1.39 | +0.01 ± 0.32 |
| concentrated (all-in-one) | 1.51 | −0.01 ± 0.22 |

**Reading.** The first pass "resolved farming" with a mean-track (split-resistant)
freezing power, but that only defended one direction — a *concentrated* single
identity reaches high mean track and, under the old CAP=8/SAT=20, ~5.8× power.
Two fixes bound it: (a) freezing power from the seat-weighted **mean** track
(split-resistant), and (b) recalibration so decay holds realized power well below
the cap. Now realized power stays ≤ ~1.7 even at 600 farm cases (~590 xBZZ), and
in campaign mode the attack-success **uplift from farming is within noise for
every strategy**. Farming is bounded — but "eliminated" overstates it; it is a
weak, costly, high-variance lever, not a no-op. `test_concentrated_farm_bounded`
guards this.

Veteran effect (campaign, 50% whale): honest newcomers → attacker success
0.33 ± 0.11; honest veterans (track 20) → 0.19 ± 0.11. Principle 4 is now
*mechanically active* (freeze bites) where the pre-review model showed no
difference — but the effect is modest under the lower cap, with wide variance.

## 5. Copy/correlated voting, and correlated honest error

`python3 run.py copy` and the correlated-error rows of `run.py honest`:

- No attacker, correctness vs copy-voter share (difficulty 0.1): 0.998 → 0.958 at
  95% copy — robust until independence is nearly gone (why commit-reveal matters).
- **Whale × copy** (20% attacker): success 0.08 → 0.23 → **0.33** as honest
  copy-share rises 0 → 0.5 → 0.9. Loss of independence directly helps an attacker.
- **Correlated honest error** (difficulty 0.3): correctness 0.987 → 0.922 as
  error_correlation → 0.5. A shared blind spot is not washed out by plurality —
  the more realistic failure than deliberate copy-voting under working
  commit-reveal.

There is no "first-come racing" result: panels are drawn by sortition, so no race
exists at the protocol level (spec §5.2).

## 6. Fee floor and liveness (unchanged in direction)

`python3 run.py fee-floor`: Gnosis gas is 0.04–2% of the fee, so the floor is
essentially voter pay. Moderators clear costs at margin 1.5 on clear content and
~2 on borderline (the solvent-settlement correction from WO-1 thinned the margin;
`test_fee_floor_lets_moderators_clear_costs`). `c` (per-judgment cost) is an
operator input, swept, never baked in.

`python3 run.py underparticipation`: correctness holds (≥ 0.98) down to ~15% of
drawn seats online; at 8% it dips to 0.91 and the widen path stretches latency to
~6.8 days. i.i.d. `reveal_prob` understates correlated (bursty) offline — still open.

---

## 7. Limits of the mechanism (stated plainly)

The review's most important correction: some outcomes the first pass read as
security *confirmations* are the system working as designed toward capitulation.

- **A supermajority captures the system, cheaply and recoverably.** At 75–90%
  stake the whale wins ~1.0 of cases and nets ≈ 0 (only fees). Because stake is
  never slashed (principle 2), the *only* cost of holding a majority is temporary
  capital lock-up plus the exit cooldown — fully recoverable. No document models
  the cost of *acquiring* a stake majority, which is the real external defense.
  The protocol does not prevent majority capture; it prices minority attacks and
  keeps every listing re-litigable (removal path, P1).
- **Minority power is real** given content choice and liveness exploitation (§1).
- **Attacker bond income is real** against a non-EV-rational honest side (§2).
- **The Schelling focal point is an external, unpinnable standard.** "Would
  general-audience safe search return this?" is a shared-understanding genre, not
  a queryable oracle; coherence rewards are paid on moderators predicting each
  other's reading of it (guidelines §1.1). This is a deliberate v1 choice, but it
  is a genuine source of borderline-case variance, not a crisp test.
- **Randomness manipulation is priced against the listing, not the pot** (spec §7)
  — the prize is uncapped SEO value; the VDF path is the mitigation if it grows.

None of these breaks the two structural guarantees that survive and are
test-guarded: **no internal stake transfer** and **funds conservation**. But the
marketing-level "no attack can be engineered / attacker profits nothing / minority
powerless" claims are true only within stated conditions, and FINDINGS now says so.

---

## Parameter decisions and open items (spec §11)

| Item | Status |
|---|---|
| Per-case stake benefit (double-count) | **Decided:** seat selection + flat voting (§5.2). |
| Settlement solvency | **Decided/fixed:** refunds-first order, conservation test (§6.2, WO-1). |
| Randomness | **Decided:** two seeds, outcome seed after reveals (§7). |
| Index / uncontested / dedup lifecycle | **Decided:** write at settlement; no-reject-ever; clear on REJECT/VOID/removal (§8). |
| Freezing-power formula + anti-farming | **Decided:** seat-weighted mean track; bounded by recalibration (§6, this doc §4). |
| Freeze/track magnitudes (CAP/SAT/DECAY) | Working (4/60/0.95); revisit with veteran-effect vs principle-1 trade-off. |
| `COMMIT_TARGET`, `BOND_MULTIPLIER`, windows | Open magnitudes; structure fixed. |
| Fee-floor `margin`, op cost `c` | Open inputs; `margin ≈ 2` clears borderline; `c` is operator's. |
| **Appeal-behavior sensitivity** | **Open, important:** attacker profit = f(naive-appeal share). Needs a policy + window/bond design that stays safe against a caring honest side. |
| Correlated liveness / correlated error | Open; models use i.i.d.; both degrade results when correlated. |
| Stake-acquisition cost model | **Missing:** the real external defense against majority capture is unmodeled. |

**Bottom line.** The simulation now falsifies as well as confirms. It cleared one
money-minting bug and a class of spec-level defects, and it replaced four
over-strong headlines with conditional ones plus a named list of limits. That is
the M1 milestone doing its job: surfacing what the mechanism does and does not
guarantee, in numbers, before any Solidity is written.
