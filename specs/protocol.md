# Moderation Protocol — Specification

**Status:** Normative. This is the design. Where anything else in the repository
disagrees with it, this file wins.

**Not yet implemented.** `contracts/src/` implements an earlier design and is
being brought to this one. The differences are listed in §10.

---

## 1. What the system is

Publishers pay a fee to have content judged. Staked moderators judge it. Content
that passes is recorded in an on-chain, topic-indexed registry that anyone can
build a search application over.

A moderator's judgment is a vote. Votes are hidden until everyone has voted. The
outcome is drawn probabilistically from the tally, so no participant can force a
result. Anyone who disagrees with an outcome can challenge it, which buys another
round of voters whose votes are added to the pool.

## 2. Moderators

**Stake.** A moderator stakes a fixed amount to become active. Every stake is the
same size — there is no weighting by capital. Influence is bought by running more
identities, each costing its own stake.

**Concurrency is unlimited.** A staked moderator may vote in as many cases at the
same time as they choose. Nothing is reserved per case and nothing is locked.

**The only penalty is a freeze.** A vote incoherent with the final outcome adds a
fixed duration to the moderator's total frozen time. Freeze durations are
**additive to a running total**, not extensions from the present moment, so the
same set of losses costs the same regardless of the order they settle in.

A frozen moderator is not eligible for any case until the total elapses.

**The stake is never taken.** It is not slashed, not redistributed, not
transferred to another moderator. Time is the only currency of penalty.

| parameter | value |
|---|---|
| `STAKE` | *(open)* |
| `FREEZE_PER_LOSS` | *(open — §11)* |

## 3. Eligibility

For a case `c`, moderator `m` is eligible for committee `k` when

```
hash( c , m , R_k )   has at least   N − 5   leading zero bits
```

where `N` is chosen such that the count of non-frozen moderators lies between
`2^N` and `2^(N+1)`, and `R_k` is the randomness for that committee (§4).

Eligibility creates **no obligation**. A moderator who is eligible and does
nothing suffers nothing. There is no no-show penalty anywhere in this design.

Eligibility is publicly computable: anyone can determine their own eligible
identities as soon as `R_k` exists.

## 4. The case lifecycle

### 4.1 First outcome

```
submit
  │   R₁ = randao at submission
  ├── committee 1 eligible, commits
  │     closes 15 minutes after the 3rd commit
  │
  │   R₂ = randomness available after committee 1's last commit
  ├── committee 2 eligible, commits
  │     closes 15 minutes after the 3rd commit
  │
  ├── committees 1 and 2 reveal together — 30 minutes
  │
  └── 3 tickets drawn against the combined tally
      → PRELIMINARY OUTCOME
```

**Committee 2 is not knowable when committee 1 commits.** Its randomness does not
exist until committee 1's commit phase has closed. So a moderator committing in
committee 1 accepts exposure without knowing who else will review the case.

**Neither committee sees the other's votes.** Both reveal in the same phase, so
committee 2 commits without a tally to follow. This is what the staging is for:
payment is for coherence with the outcome, so a visible tally would make following
it more profitable than judging (`simulation/FINDINGS-staged.md` §B).

**The commit clock starts at the third commit, not the first.** Three commitments
start the timer; they are not a quorum and do not by themselves make a tally
sufficient.

### 4.2 Challenge

The preliminary outcome is published. A **one hour** challenge window follows.

**A challenge is a vote opposite the published outcome.** It is public and it
discloses its direction — you cannot challenge an Approve by approving. The
challenger's vote counts once and carries the ordinary vote liability.

If a challenge is registered:

```
  ├── committee 3 eligible, commits      (15 min from 3rd commit)
  │   R₄ = randomness after committee 3's last commit
  ├── committee 4 eligible, commits      (15 min from 3rd commit)
  ├── committees 3 and 4 reveal together — 30 minutes
  │
  └── 3 tickets drawn afresh against the combined tally of
      committees 1, 2, 3 and 4
      → PRELIMINARY OUTCOME
```

Another one hour challenge window follows. **At most two challenges.**

Committee 4 is unknowable when committee 3 commits, for the same reason committee
2 is unknowable when committee 1 commits.

### 4.3 Finalization

A case finalizes when the last challenge window closes with no challenge, or when
the second challenge has resolved.

**No payout happens before finalization.** Preliminary outcomes move no money.

## 5. The draw

Three tickets are drawn against the combined tally of every committee that has
revealed. The outcome is the majority of the three.

Tickets are drawn **fresh at each preliminary outcome**, over the pool as it
stands. Retry is bounded by the challenge cap rather than by reusing a single
draw.

| parameter | value |
|---|---|
| ticket rule | majority of 3 |
| estimator fed to the tickets | *(open — §11)* |

## 6. Settlement

At finalization:

- every moderator whose revealed vote is coherent with the final outcome is paid
  a share of the fee;
- every moderator whose revealed vote is incoherent has `FREEZE_PER_LOSS` added
  to their total frozen time;
- a moderator who committed and did not reveal is penalised (§11).

Settlement is **pull**: each moderator claims their own. No transaction has to
process an unbounded set of participants.

## 7. The index

A finalized Approve writes an entry: the content hash, the metadata hash, the
declared topics, and the tally.

Two facts are recorded alongside every entry rather than being compressed into a
label:

- **whether the entry was anonymous** — an entry that was challenged can never be
  anonymous;
- **whether all three tickets were Approve.**

There is no `SUPER_SAFE` flag. A client that wants a stricter filter reads these
facts and applies its own rule; the protocol does not decide what "safe enough"
means on a client's behalf.

## 8. Removal

A removal case targets an entry already listed and runs through the same engine,
the same committees, the same tickets. Approve means remove.

The fee is paid whether the removal succeeds or fails, so a speculative removal
costs its submitter every time.

## 9. What is deliberately not here

- **No quorum gate.** Three commits start a clock, nothing more.
- **No no-show penalty.** Eligibility is an opportunity.
- **No stake slashing or redistribution.** §2.
- **No vote weighting.** One identity, one vote.
- **No verdict before all voting closes** within a round. §4.1.

## 10. Distance from the current implementation

`contracts/src/` implements an earlier design. This section is built by reading
this document against the contracts, **not** by collecting the objections someone
happened to raise — an objection list stops wherever the reader stopped, and the
most dangerous divergences are the ones nobody thought to ask about.

### 10.1 Contradicts this document

| area | implemented | this document |
|---|---|---|
| committees per round | one | two, staged (§4.1) |
| penalty | balance debit | additive freeze (§2) |
| concurrency | capped by bond solvency | unlimited (§2) |
| pre-challenge publication | plurality, verdict withheld | preliminary outcome (§4.2) |
| challenge | bonded, direction hidden | a public opposite vote (§4.2) |
| draw | once per claim, reused on re-review | fresh per preliminary outcome (§5) |
| challenge window | 12 hours | 1 hour (§4.2) |
| commit window | 20 minutes, fixed | 15 minutes from 3rd commit (§4.1) |
| max challenges | 1 | 2 (§4.2) |
| strict label | `SUPER_SAFE` predicate | two recorded facts (§7) |
| eligibility | fixed cohort target, widened mid-window | `N−5` leading zero bits, no widening (§3) |

### 10.2 Required here, absent there

- **Freeze.** There is no freeze anywhere in the contracts. `FreezeMath` was
  deleted when penalties moved to balance debits. §2 needs it back, and it must be
  additive to a total rather than an extension from the present moment.
- **Staged committee selection.** No second seed derived after a first commit
  phase closes. §4.1 requires one per committee.
- **A commit clock anchored to the third commit.** Windows are currently fixed
  from phase open.

### 10.3 Built without being asked for

**This is the category that matters, and it was missing from earlier versions of
this table.** Each of these exists in the contracts, none appears in the design,
and each was our addition rather than a decision anyone took.

| subsystem | what it is | status |
|---|---|---|
| **Bonds** | `postBond`, `mayCommit`, `mayChallenge`, `createVoteClaim`, `createChallengeClaim`, `debit`, `discharge`, `dischargeCondemned`, `claimChallenge`, plus `bond`, `liabilities`, `openVoteCount`, `openChallenges` in storage | **A second capital system on top of the stake.** §2 has a stake and nothing else. Unlimited concurrency and a solvency-checked bond are the same decision taken twice in opposite directions — the bond is what caps concurrency. Removing the bond removes the cap. |
| **Maintenance reserve** | `sweepMaintenance`, `depositMaintenance`, `proposeMaintenanceWithdrawal`, `executeMaintenanceWithdrawal` | Exists to receive debits. With no debits there is nothing to receive. Whether the protocol should hold a treasury at all is undecided. |
| **Governance** | `RulesetGovernor`, `applyParams`, `applyGuidelines`, `proposeCaps`, `executeCaps`, `setGovernor`, timelocks | Never specified. Some upgrade path is probably needed; the shape of it was never agreed. |
| **Track record** | `track`, `recordParticipation`, decay and saturation | Never specified. Currently weights nothing and scales nothing, so it is storage with no consumer. |
| **Retry and reservation machinery** | `reopen`, `withdrawRefund`, claim keys, permanent reservations, `NO_TURNOUT` / `NO_REVEALS` / `NO_RANDOMNESS` terminal rows, retry cooldowns | Never specified. §4 has one lifecycle with one terminal state. |
| **Maturation and exit cooldown** | `maturesAt`, `exitRequestedAt`, `maturation`, `exitCooldown` | Never specified. A fresh stake currently cannot vote for a period. |
| **Permissionless phase pokes** | `closeCommit`, `closeReveal`, `closeTally`, `draw` as separate transactions, with bounties | Never specified. Partly an artefact of the plurality phase, which §4.2 removes. |
| **Index questions** | `openQuestion`, `closeQuestion`, the open-question counter | Existed to serve `SUPER_SAFE`. §7 drops that label, so this is likely orphaned. |
| **Topic cap** | `MAX_TOPICS = 5` | Never specified. |

**None of these is condemned by being listed here.** Several may turn out to be
necessary. The point is that each is an open decision that was taken silently,
and the list exists so that they are decided rather than inherited.

## 11. Open parameters

Not decided, and each needs a number before deployment.

- `STAKE`, `FREEZE_PER_LOSS`, fee level and its split.
- **The estimator fed to the tickets.** The implemented design uses
  `â = (A+1)/(N+2)`, which never returns certainty on a unanimous tally; that was
  introduced to stop a single vote deciding a case outright, a job the third-commit
  timer may already do. The raw share `A/N` and the smoothed form are alternatives
  for the same problem and have not been compared under this lifecycle.
- **Non-reveal.** A commitment never revealed must cost something, or withholding
  becomes free. Amount and mechanism open.
- **A maximum wait for the third commit.** Without one, a case with two commits
  stays open indefinitely.
- **Minimum participation per committee.** A combined threshold is not enough: 40
  commits in committee 1 and one in committee 2 is not two committees.
- **What "anonymous" means** in §7.
- **`prior`** — how often a moderator's judgment matches the truth. Unmeasured,
  and `simulation/FINDINGS-floor.md` shows it decides whether any of this works.
