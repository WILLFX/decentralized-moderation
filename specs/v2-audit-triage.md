# v2 External Review — Triage

Source: independent mechanism review of `design-v2.md` / `state-machine-v2.md` at
commit `139bad3`. This document sorts its findings into what gets fixed, what needs
a decision, and what is deferred — and records which claims were verified here
rather than accepted.

**Verdict on the review: it is correct on the substance.** Its central sentence is
the one this project should have reached itself:

> Eliminating involuntary assignment does not require eliminating voluntary
> per-case risk accounting.

Only *involuntary* assignment created the capacity attack v2 exists to fix. Per-case
risk accounting was collateral damage, and removing it is the source of most of the
economic findings below.

---

## 1. Verified here, not taken on trust

| Claim | Verification |
|---|---|
| Serial freeze is settlement-order-dependent | Reproduced: two 7-day terms finalized at t=10 and t=5 give **24 days** settled A→B and **19 days** settled B→A |
| …and can *shorten* an existing suspension | Reproduced: existing `until`=100, old case `finalizedAt`=5, cap 50 → **55**, a reduction |
| Cohorts shrink across rounds | Reproduced. At 100 active: **32.0 → 21.8 → 14.8 → 10.1**, so round 4 is 31% of round 1. At 1000 active it is 91% — which is why the simulation, run at n=1000, never saw it |
| `design-v2` integer bound is misstated | Reproduced. The bound is ~1 base unit, not `1/N`. Worst case in a sweep: **0.95** base units. `state-machine-v2` has it right |
| Challenge seed is circular | Confirmed by reading: §4.7 requires eligibility for round `r+1`, whose seed §7 arms only when round `r+1` opens |
| Exit cooldown does not cover liabilities | Confirmed: `EXIT_COOLDOWN` 7 days against a case that runs 4 rounds × ~5 days |
| The simulation's challenge check ignored eligibility | Confirmed and **fixed**. It tested "does an unused attacker exist", always true at scale |
| The simulation never pooled the challenger's vote | Confirmed and **fixed** |

**The simulation corrections did not rescue the findings.** After both fixes the
attacker ratio is 1.15 / 1.21 / **1.48** / 1.87 / 1.91 at q = 0.1…0.5 — marginally
*worse* than the published 1.39 at q=0.3. The review's critique of the model was
right and its conclusions survive it.

---

## 2. One change closes six findings

**Voluntary risk units.** An identity holds `K` units; committing to a case reserves
one; settlement releases it (coherent), freezes it locally (incoherent), or applies
a short fixed freeze (committed but never revealed). A submission still reserves
nothing from anyone.

| Finding | Closed |
|---|---|
| P0 unlimited pre-settlement leverage | Capital becomes linear in concurrent votes |
| P0 no penalty for commit-without-reveal | The unit freezes on non-reveal |
| P0 exit cooldown vs open liabilities | Withdrawal blocked while units are reserved |
| P0 order-dependent serial freeze | Each unit expires on its own case's date; nothing accumulates on the identity |
| §4.10 settlement delay as a concurrency amplifier | The unit stays reserved until settled |
| `FINDINGS-v2.md` §A, the freeze/reward ratio | A loser drops `1/K` of throughput, not all of it |

That last row **supersedes this project's own recommendation** to cut `FREEZE_BASE`
to about an hour. With `K` units the ratio becomes `freeze_days × cases_per_day / K`;
at K=50 a moderator needs 58% confidence against the 66.5% they actually have.
Viable without shortening the term at all. The one-hour recommendation was treating
a symptom, and it should be withdrawn rather than adopted.

**Recommendation: adopt.** It does not reintroduce the capacity attack, because
nothing is reserved until a moderator voluntarily commits.

---

## 3. Second change: one final draw

The state machine redraws the verdict every round, so an attacker who loses a draw
challenges and one who wins stops. Pooling preserves the *votes*; it does not
prevent asking for another *sample* of them. The `design-v2` §4.5 claim that "the
dice cannot be re-rolled" is wrong as specified.

Fix: publish the deterministic plurality between rounds and draw **once**, after the
last evidence round. A challenge then adds evidence rather than requesting a reroll —
which is what a challenge was always supposed to be.

The review and this project's own simulation independently converge on
**`MAX_ROUNDS` = 2**.

---

## 4. Fixes to make now (no decision required)

| # | Fix | Where |
|---|---|---|
| F1 | Integer-neutrality bound: `1/N` → one base unit | `design-v2` §4.4 |
| F2 | Neutrality theorem is **local** — state that it covers cash for a fixed final tally, not the dynamic game | `design-v2` §4.2, README |
| F3 | Suspension scales with the *winner's* track record, so total utility is direction-dependent even though cash is not. Principle 4 is overclaimed | README §3 principle 4, `design-v2` |
| F4 | `fullQuorum` is `≥ MIN_REVEALS` (5), not "a full cohort". Rename or strengthen; do not describe five votes as near-certainty | README §3.8, `state-machine-v2` §8 |
| F5 | Publishers cannot challenge a rejection — only eligible unused moderators can. README's submit interface promises an appeal path the spec does not provide | README §5, `state-machine-v2` §4.7 |
| F6 | `ageFactor` is described as growing with case age but specified as incrementing only on quorum-failure extension | `design-v2` §2.2 vs `state-machine-v2` §3.3 |
| F7 | Challenge seed circularity — arm round `r+1`'s seed on entering the challenge window | `state-machine-v2` §4.7, §7 |
| F8 | Cohort threshold must divide by *unused* eligible population, not all active | `state-machine-v2` §3.3 |
| F9 | `totalActiveModerators` cannot be a counter when ACTIVE is a time predicate. Use explicit activate/thaw and per-round snapshots | `state-machine-v2` §2, §3.3 |
| F10 | Outcome seed must derive from the scheduled reveal deadline, not the transaction that closes the phase | `state-machine-v2` §4.3, §7 |
| F11 | Challenge-round quorum is ambiguous — specify whether the challenger's public vote counts toward `committedThisRound` | `state-machine-v2` §4.3 |
| F12 | Guidelines still describe bonded appeals reimbursed with a bonus (v1 mechanics) | `MODERATION_GUIDELINES.md` |
| F13 | Maturation must be set independently of `FREEZE_BASE`, not coupled to it | `state-machine-v2` §2.2 |

F2–F5 are overclaims in documents written here, not defects the review introduced.
They are the highest priority in this table: a wrong number is cheap, a wrong
*claim* is what an outside reader relies on.

---

## 5. Decisions — owner and senior reviewer, not the implementer

| # | Decision | Why it cannot be settled here |
|---|---|---|
| D1 | **Portfolio attacks.** A per-item probabilistic defence is linear against fungible volume: 100 substitute items at 30% yields ~30 listings. Per-content history does not help — different hashes | This questions the proportional lottery as a *primary definition of safe*, which is the foundation the whole design rests on |
| D2 | **Challenger-funded rounds.** Confirmed mathematically available: if the pot grows to `P'` and payment stays `P'/W`, then `E[pay] = P'/N` and neutrality holds. So neutral payouts + non-diluting pay is reachable — at the cost of free challenges | The senior reviewer removed paying-to-challenge deliberately. The variant worth putting to him: the submitter pre-funds one challenge reserve, refunded if unused |
| D3 | **Nonrecoverable listing collateral.** A successful attacker who controls submitter, winning voters and the claim caller recovers essentially the whole fee. Expected cost per success is `fee × (1−p)/p` — 2.33 fees at p=0.3 | Listing bond, approval TTL, renewal fee, or a maintenance reserve are all product decisions about what a listing costs to hold |
| D4 | **Reputation's role.** It currently sets freezing power, prices churn, and rewards tenure. Using it to determine how hard a bloc can freeze dissenters invites cartel behaviour, and it measures conformity with past stochastic outcomes, not accuracy | The proposed split — penalty from the *voter's own* incoherence history, reputation for eligibility and earnings only — changes what reputation is for |
| D5 | **Evidence registry vs safety oracle.** Expose counts, turnout, rounds, policy version and let clients pick a threshold, rather than shipping one `supersafe` bit | Decides what the product is |
| D6 | **Structured ballot.** One binary vote currently bundles safety, metadata accuracy and topic relevance, so a rejection says nothing about which failed | Real improvement, real scope increase |

---

## 6. Deferred — real, not blocking a v2.1 spec

- **AI/operator correlation.** 32 addresses may be one model behind one API. `q`
  should be described as a share of stake units, not of independent judgments. The
  simulation models honest error as independent per moderator, which is optimistic.
- **Privacy, bribery, coercion.** Public eligibility plus permanent public reveals
  makes targeted bribery and pressure feasible; commit-reveal is not receipt-free.
  Belongs in the threat model now, in the design later.
- **Lazy randomness selective abort.** A party can compute whether an armed seed
  favours them and simply not realize it, letting it expire. This is a consequence
  of lazy realization, which was introduced *here* to keep selection at zero
  transactions — the feature created the surface.
- **Index scalability**, canonical topic normalization enforced on-chain rather
  than in the submit UI, tombstones, pagination.
- **Rendering envelope** for review: no external fetches, content-addressed
  dependencies, decompression limits, prompt-injection resistance for AI reviewers.

---

## 7. What the review does not change

The capacity fix stands. Nothing here touches the property the pivot was for: a
submission still reserves no moderator, locks no stake, and creates no obligation.
Risk units preserve that by construction.

Also unchanged and independently endorsed: no transfer of moderator principal;
permanent registries with replaceable logic; content-addressed content and metadata;
version-pinned policy; fixed-window commit-reveal; cumulative evidence; one vote per
identity per case.

---

## 8. Sequence

1. **F1–F13** — documentation and specification corrections. No decisions needed.
2. **Risk units and one-final-draw** into `design-v2` and `state-machine-v2`, with
   the payout derivation redone for `K` units.
3. **D1–D6** — decisions, then whatever they imply.
4. **Simulation v2.1** — the review's list is right: simultaneous cases and
   pre-settlement waves, risk units vs whole-identity suspension, selective reveal,
   outcome-conditioned stopping, settlement-order permutations, pre-aged Sybils,
   correlated AI error, portfolio retries. The single-case model cannot see any of
   them, and the largest finding in this review is one it structurally could not
   have found.
5. Only then, Solidity.

No contract source is affected by any of this. `contracts/` implements the first
architecture and is unchanged.
