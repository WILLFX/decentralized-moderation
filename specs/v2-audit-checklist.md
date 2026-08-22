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

**Headline: 3 of 10 P0s are closed.** The rest are open, and most of them wait on
one architectural change — voluntary risk units — that **is not adopted, not
specified, and not in the repo.** It is a recommendation from the review awaiting
the senior reviewer's ruling. Nothing below should be read as fixed because a fix
has been proposed for it.

---

## P0

| # | Finding | Status | Note |
|---|---|---|---|
| P0-1 | Unlimited concurrent votes per stake | **OPEN** | Waits on risk units |
| P0-2 | Cross-case and portfolio retry | **DECISION** | D1. The deepest finding; no answer from anyone yet |
| P0-3 | Successful attacker recovers its own fee | **DECISION** | D3. Needs a nonrecoverable listing component |
| P0-4 | No penalty for commit-without-reveal | **OPEN** | Waits on risk units |
| P0-5 | Exit cooldown does not cover open liabilities | **OPEN** | Waits on risk units |
| P0-6 | Serial freeze is settlement-order-dependent | **OPEN** | Verified here (24 vs 19 days) and **not fixed** |
| P0-7 | Next-round challenge seed is circular | **DONE** | F7, `a4ac471` |
| P0-8 | Repeated draws permit optional stopping | **NEEDS SPEC** | One-final-draw agreed, not written |
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
| 4.2 | Commit creates a free reveal option | **OPEN** |
| 4.3 | Last revealer influences outcome-seed timing | **DONE** F10 |
| 4.4 | Exit cooldown vs open cases | **OPEN** |
| 4.5 | Serial freeze not order-independent | **OPEN** |
| 4.6 | `totalActiveModerators` unmaintainable | **DONE** F9 |
| 4.7 | Later cohorts are not the same size | **DONE** F8 |
| 4.8 | Pooling does not stop rerolls | **NEEDS SPEC** |
| 4.9 | Challenge-round quorum ambiguous | **DONE** F11 |
| 4.10 | Batched settlement and immediate penalties | **OPEN** |
| 4.11 | Lazy randomness selective abort | **DEFERRED** |
| 4.12 | Integer-neutrality bound misstated | **DONE** F1 |

**6 of 12.**

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
| 10.1 | Identity + K voluntary risk units | **DECISION** — recommended, awaiting the senior reviewer |
| 10.2 | Commit reserves a unit; non-reveal freezes it | **DECISION** — same |
| 10.3 | Epoch-based active set | **DONE in part** — F9 pins per-round snapshots |
| 10.4 | One challenge, one final draw, `MAX_ROUNDS` 2 | **NEEDS SPEC** |
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
| One case at a time | **OPEN** — the largest gap; it is what hid P0-1 |
| Risk units vs whole-identity suspension | **OPEN** |
| Strategic commitment and selective reveal | **OPEN** |
| Outcome-conditioned stopping | **OPEN** |
| Exits during unresolved cases | **OPEN** |
| Settlement-order permutations | **OPEN** |
| Pre-aged Sybil inventories | **OPEN** |
| Reputation farming and churn | **OPEN** |
| Correlated AI error, prompt injection | **OPEN** |
| Cross-case retry and substitute portfolios | **OPEN** |
| Successful-attacker fee recovery | **OPEN** |
| Bribery, proposer bias | **OPEN** |

**2 of 14.**

### Invariants the review asks the spec to add

None are written yet. All **OPEN**.

- `withdraw` implies zero open liabilities
- reserved risk units cannot be reused
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
| P0 | 3 | 10 |
| P1 / P2 | 1 | 5 |
| §4 state machine | 6 | 12 |
| §5 safety product | 1 | 6 |
| §6 removal | 0 | 2 |
| §9 documentation | 6 | 6 |
| §10 v2.1 proposals | 0.5 | 10 |
| §11 simulation | 2 | 14 |
| Invariants | 0 | 11 |

What has been closed is almost entirely **documentation and specification
mechanics** — real work, and the cheapest tier. Every economic finding is open.

## What unblocks the most

1. **The senior reviewer's ruling on risk units.** Unblocks P0-1, P0-4, P0-5,
   P0-6, §4.10 and the freeze/reward problem — six items, one decision.
2. **One-final-draw into the spec.** Closes P0-8; agreed, unwritten.
3. **D1, portfolio attacks.** No proposal exists from anyone. It is the one
   finding that questions the mechanism rather than its parameters.
