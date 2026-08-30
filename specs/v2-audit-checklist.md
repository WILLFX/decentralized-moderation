# v2 External Review — Checklist

Every finding in the review, with honest status. Companion to
`v2-audit-triage.md`, which explains the reasoning; this file is the score.

**Status vocabulary**

| | Meaning |
|---|---|
| **DONE** | Landed in a commit, named here |
| **NEEDS SPEC** | The answer is agreed; nothing is written yet |
| **DECISION** | Blocked on the project owner and/or senior reviewer |
| **OPEN** | No answer yet, from anyone |
| **DEFERRED** | Real, deliberately not now |

**Headline: 5 of 10 P0s are closed.** This was 8 while risk units stood. The senior
reviewer has since ruled per-case reservation out as non-negotiable, and **four of
those eight were closed by units** — P0-1, P0-4, P0-6 and §4.10 all revert. What
remains closed is what does not depend on the unit mechanism.

Nothing here is **implemented**. No Solidity exists for any of v2.

**Read this before the tables.** Three external proposals have landed since the
revision this file scores (parallel audit cohort; two-ticket confirmation with a
terminal `CONTESTED`; adaptive phase windows). `specs/design-v3.md` now carries the
adopted direction — challenge-free, three tickets, 2-of-3 majority, no abstention
state, exact cash neutrality deliberately abandoned — but no
state machine specifies it and nothing is implemented, so the tables below score
`main` **as written**, not the design under discussion. Where a proposal names a replacement for something units used to close,
it is noted as *shape agreed* — which means an answer exists and is not yet written
down, not that the finding is closed.

---

## P0

| # | Finding | Status | Note |
|---|---|---|---|
| P0-1 | Unlimited concurrent votes per stake | **REOPENED** | Closed by v2.1 §3.3b units; units are ruled out. *Shape agreed:* the reviewer's own analysis concedes unlimited simultaneous votes and bounded per-case consequence cannot coexist without a per-case **price**, and admits a refundable per-commit bond. A price is not a reservation |
| P0-2 | Cross-case and portfolio retry | **DECISION** | D1. The deepest finding; no answer from anyone yet |
| P0-3 | Successful attacker recovers its own fee | **DECISION** | D3. *Shape named:* nonrecoverable fee component plus listing bond or renewal — costs that attach to the prize rather than to honest concurrency |
| P0-4 | No penalty for commit-without-reveal | **REOPENED** | `NONREVEAL_FREEZE` froze a unit. *Shape agreed:* a small refundable reveal-completion bond, forfeited to a maintenance reserve — never to opposing voters, which would create punishment farming |
| P0-5 | Exit cooldown does not cover open liabilities | **DONE** | v2.1 §2.3. Survives without units as `require(openVoteCount == 0)` |
| P0-6 | Serial freeze is settlement-order-dependent | **REOPENED** | Per-unit expiry is what made it order-independent. The property to preserve is that **penalties commute**: a balance debit does, a deadline extension does not |
| P0-7 | Next-round challenge seed is circular | **DONE** | F7, `a4ac471` |
| P0-8 | Repeated draws permit optional stopping | **DONE** | v2.1 §4.2 — one draw, after the last round |
| P0-9 | Active-moderator counter unmaintainable | **DONE** | F9, `a4ac471` |
| P0-10 | "Supersafe" far weaker than the name implies | **DONE** | F4, `1dc186d` — renamed to *unopposed* |

## P1 / P2

| # | Finding | Status | Note |
|---|---|---|---|
| P1-1 | Reputation is reward, anti-churn and weapon at once | **DECISION** | D4 |
| P1-2 | Lazy blockhash allows selective realization | **DEFERRED** | Created by a choice made here, to keep selection at zero transactions |
| P1-3 | Removal is an underfunded public good | **DECISION** | D-removal; already an accepted limitation in the README |
| P1-4 | AI/operator correlation not modelled | **DEFERRED** | `q` should mean stake units, not independent judgments |
| P2-1 | Documentation and arithmetic inconsistencies | **DONE** | F1–F6, F12 |

## §4 — state machine (finer than the P0 table)

| § | Finding | Status |
|---|---|---|
| 4.1 | Challenge seed circular | **DONE** F7 |
| 4.2 | Commit creates a free reveal option | **REOPENED** — see P0-4 |
| 4.3 | Last revealer influences outcome-seed timing | **DONE** F10 |
| 4.4 | Exit cooldown vs open cases | **DONE** v2.1 — survives without units |
| 4.5 | Serial freeze not order-independent | **REOPENED** — see P0-6 |
| 4.6 | `totalActiveModerators` unmaintainable | **DONE** F9 |
| 4.7 | Later cohorts are not the same size | **DONE** F8 |
| 4.8 | Pooling does not stop rerolls | **DONE** v2.1 |
| 4.9 | Challenge-round quorum ambiguous | **DONE** F11 |
| 4.10 | Batched settlement and immediate penalties | **REOPENED** — closed by unit reservation |
| 4.11 | Lazy randomness selective abort | **DEFERRED** |
| 4.12 | Integer-neutrality bound misstated | **DONE** F1 |

**8 of 12** (was 11 with units).

## §5 — safety product

| § | Finding | Status | Note |
|---|---|---|---|
| 5.1 | A proportional lottery is not a conservative classifier | **DECISION** | D5. Ties to D1 |
| 5.2 | "Supersafe" overclaimed | **DONE** | F4 |
| 5.3 | Guidelines too ambiguous to be the security primitive | **OPEN** | One line — "would SafeSearch return this" — carries the whole Schelling point |
| 5.4 | One binary vote bundles three claims | **DECISION** | D6. Structured ballot |
| 5.5 | Immutable bytes ≠ immutable rendered meaning | **DEFERRED** | Needs a canonical rendering envelope; prompt injection against AI reviewers sits here |
| 5.6 | AI identities are not independent moderators | **DEFERRED** | Same as P1-4 |

## §6 — removal and persistence

| § | Finding | Status |
|---|---|---|
| 6.1 | Requester-funded removal is undersupplied | **DECISION** |
| 6.2 | Old-policy approvals need expiry or revalidation | **OPEN** |

## §7 / §8

| § | Finding | Status |
|---|---|---|
| 7 | Privacy, bribery, coercion; public eligibility enables targeting | **DEFERRED** — belongs in the threat model now |
| 8 | Index scalability; on-chain topic normalization | **DEFERRED** |

## §9 — documentation inconsistencies

All six closed by F1–F6 and F12 (`ef78b15`, `1dc186d`, `a4ac471`). **6 of 6.**

## §10 — the proposed v2.1 architecture

Nothing here is adopted. This is the review's recommendation set.

| § | Proposal | Status |
|---|---|---|
| 10.1 | Identity + K voluntary risk units | **WITHDRAWN** — approved by the project owner, then ruled out by the senior reviewer |
| 10.2 | Commit reserves a unit; non-reveal freezes it | **WITHDRAWN** — with 10.1 |
| 10.3 | Epoch-based active set | **DONE in part** — F9 pins per-round snapshots |
| 10.4 | One challenge, one final draw, `MAX_ROUNDS` 2 | **DONE** — v2.1 |
| 10.5 | Separate challenge *funder* from challenge *endorser* | **DECISION** — gives publishers the appeal path F5 removed |
| 10.6 | Permanent cumulative claim history | **DECISION** — part of D1 |
| 10.7 | Evidence-rich index instead of one safety bit | **DECISION** — D5 |
| 10.8 | Reputation redesign | **DECISION** — D4 |
| 10.9 | Listing collateral and expiry | **DECISION** — D3 |
| 10.10 | Randomness: replace lazy re-arming | **DEFERRED** |

## §11 — simulation

| Item | Status |
|---|---|
| Challenge check ignored real eligibility | **DONE** — fixed, `ef78b15` |
| Challenger's vote never pooled | **DONE** — fixed, `ef78b15` |
| One case at a time | **DONE** — `campaign_v2.py` models concurrent cases |
| Risk units vs whole-identity suspension | **VOID** — E6 measures a withdrawn mechanism |
| Strategic commitment and selective reveal | **OPEN** |
| Outcome-conditioned stopping | **DONE** — removed by one-final-draw; E1 measures the effect |
| Exits during unresolved cases | **OPEN** |
| Settlement-order permutations | **OPEN** |
| Pre-aged Sybil inventories | **OPEN** |
| Reputation farming and churn | **OPEN** |
| Correlated AI error, prompt injection | **OPEN** |
| Cross-case retry and substitute portfolios | **OPEN** |
| Successful-attacker fee recovery | **OPEN** |
| Bribery, proposer bias | **OPEN** |

**4 of 14.**

### Invariants the review asks the spec to add

**All eleven written into `state-machine-v2` §9 as I13–I21 plus I4/I12.** None are
*tested* — there is no implementation to test them against.

- `withdraw` implies zero open liabilities
- reserved risk units cannot be reused *(I14 — moot if units are withdrawn; the general form is that no unit of exposure backs two cases at once)*
- commit implies reveal or an explicit non-reveal consequence
- suspension never decreases because an older case settled
- penalties invariant under settlement permutation
- challenge eligibility seed exists before the challenge is verified
- round threshold immutable after the round opens
- no final outcome drawn more than once
- every unchanged claim has monotonic review history
- a finalized losing vote blocks reuse before batched settlement
- every state predicate mutually exclusive or explicitly prioritized

---

## Totals

| Group | Closed | Total |
|---|---|---|
| P0 | 5 | 10 |
| P1 / P2 | 1 | 5 |
| §4 state machine | 8 | 12 |
| §5 safety product | 1 | 6 |
| §6 removal | 0 | 2 |
| §9 documentation | 6 | 6 |
| §10 v2.1 proposals | 1.5 | 10 |
| §11 simulation | 4 | 14 |
| Invariants | 11 (written) / 0 (tested) | 11 |

What has been closed is almost entirely **documentation and specification
mechanics** — real work, and the cheapest tier. Every economic finding is open.

## What unblocks the most

1. **A penalty that commutes and does not cap concurrency.** This is the successor
   to "the ruling on risk units", which has arrived and went against them. One
   mechanism unblocks P0-1, P0-4, P0-6, §4.10 and the freeze/reward problem
   together, and the requirement is now stated as a property rather than a lever:
   a penalty must be **order-independent** and its cost per case must not scale
   with how many cases the moderator is in. Balance debits against a posted bond
   satisfy both; time freezes satisfy neither under unlimited concurrency.
2. **D1, portfolio attacks.** Still the one finding that questions the mechanism
   rather than its parameters. Nothing proposed by anyone closes it. The nearest
   shapes on the table are recurring listing cost and permanent claim history —
   both bound the *prize* rather than restricting moderators.
3. **A decision on `CONTESTED`.** New, from the two-ticket proposal. Making
   disagreement terminal cuts wrong certifications from `x` to `x²` but raises
   non-certification from `x` to `2x − x²`, and payout neutrality forces the
   contested branch to be penalty-free — so a censor's cheapest path is to force
   disagreement. Terminal-and-excluded, terminal-and-retryable, and pooled
   re-review are three different products.

## What was measured versus what was specified

Worth keeping visible: every P0 that reverted was closed by **specification**, and
the reversion cost nothing to discover because nothing had been built. The
simulation results in `simulation/v2/FINDINGS-v2.md` §A and §D are the exception —
they are *measurements of a mechanism that is now withdrawn*, and they carry a
provenance warning for that reason.
