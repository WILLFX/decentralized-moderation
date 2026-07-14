# Moderation Contract — Formal State-Machine Specification

**Milestone:** M1
**Status:** Draft for simulation. Parameters marked *(working)* are inputs to the
M1 simulation, not final protocol values.
**Scope:** the on-chain moderation contract (README §5, component 1). Everything
else in the system is a client of this specification.

This document defines the contract as a set of typed state, two interacting state
machines (per-**stake** and per-**case**), the transitions between their states,
the triggers and timers that fire those transitions, the settlement arithmetic,
and the invariants that must hold at every block. It is written to be executable
as a mental model and directly testable in M2.

---

## 0. Conventions

- **xBZZ** amounts are integers in base units (wei-equivalent). No floating point
  anywhere in the contract.
- **Time** is measured in block timestamps (seconds). Durations are `uint`
  seconds. All "days"/"hours" below are working values expressed as durations.
- **Randomness** is `block.prevrandao` snapshotted per §7.
- **Probabilistic draw** means: given two non-negative weights `a` (approve) and
  `b` (reject) with `a + b > 0`, the outcome is `APPROVE` with probability
  `a / (a + b)` and `REJECT` otherwise, realized by comparing a uniform random
  draw in `[0, a+b)` against `a`. Here `a` and `b` are **seat counts** (§5.3),
  not stake — stake influences the outcome only through how many seats it wins.
- `H(x)` is keccak-256.
- A **coherent** voter in a case is one whose revealed vote equals the case's
  **final** outcome. **Incoherent** = revealed a vote ≠ final outcome. A voter who
  committed but failed to reveal is neither (handled separately, §6.3).

---

## 1. Parameters *(working values — M1 simulation outputs)*

| Symbol | Meaning | Working value |
|---|---|---|
| `MIN_STAKE` | Minimum stake to be a moderator | 10 xBZZ |
| `EXIT_COOLDOWN` | Delay from withdrawal request to free-stake release | 7 days |
| `ACTIVATION_DELAY` | Delay before newly staked xBZZ is eligible for subset draws | 7 days |
| `SUBSET_FRACTION(N)` | Fraction of moderator set drawn eligible, tightening as set size `N` grows | 1–10% |
| `COMMIT_TARGET[d]` | Counted **seats** at depth `d` (flat votes; drawn stake-weighted with replacement, §5.3) | `d0:5, d1:11, d2:23` |
| `COMMIT_TIMEOUT` | Max commit-phase duration if target not reached | 24 h |
| `REVEAL_WINDOW` | Reveal-phase duration | *(working)* 24 h |
| `MIN_REVEALS` | Minimum reveals to tally; below this the subset widens | 3 |
| `APPEAL_WINDOW[d]` | Appeal window after depth `d`'s outcome | `d0:4 days, else:3 days` |
| `MAX_DEPTH` | Maximum appeal depth | 3 |
| `BOND_MULTIPLIER` | Each appeal bond ≥ this × previous round's total reward | 2× |
| `FREEZE_BASE` | Base freeze duration for incoherent voters | 7 days |
| `FREEZE_CAP` | Max multiplier on `FREEZE_BASE` from freezing power | *(working)* 8× |
| `TRACK_DECAY` | Decay rate of track-record count | *(working)* |
| `TRACK_SAT` | Saturation point of track-record → freezing power | *(working)* |
| `FEE_BASE` | Fixed part of the fee floor | *(working)* |
| `FEE_PER_TOPIC` | Per-topic part of the fee floor | *(working)* |
| `MAX_TOPICS` | Topics per submission | 5 |
| `CLAIM_BOUNTY` | Bounty paid to the finalization claimant, from the pot | *(working)* |
| `SUPERSAFE_AGE` | Age an uncontested entry must reach for supersafe view | 96 h |

`minFee = FEE_BASE + FEE_PER_TOPIC * nTopics` (P8). Submitters MAY overpay.

---

## 2. Global state

```
Contract {
  // --- moderators & stake ---
  mapping(address => Moderator) moderators
  uint     totalFreeStake            // sum of all free balances
  SortitionTree stakeTree            // stake-weighted, over ACTIVATED stake only

  // --- cases ---
  mapping(uint => Case) cases
  uint     nextCaseId

  // --- index: topic -> approved entries (README 3.8) ---
  mapping(bytes32 => Entry[]) indexByTopic     // key = keccak(normalizedTopic)
  mapping(bytes32 => bool)    submissionExists  // key = H(contentHash,metaHash,topicKey) (P3)

  // --- accounting ---
  uint     openPotsTotal             // sum of all live case pots + committed + frozen
  // token balance invariant, see §9

  // --- governance (P6) ---
  address  governanceMultisig
  uint     timelockDelay
  bytes32  guidelinesHash
  uint     guidelinesVersion
}

Moderator {
  uint free            // withdrawable (after cooldown)
  uint committed       // backing votes in open cases
  uint frozen          // locked as penalty
  uint frozenUntil     // timestamp; frozen -> free transition time
  uint activatesAt     // timestamp new stake becomes draw-eligible
  uint exitRequestedAt // 0 if no pending exit
  uint exitAmount      // amount requested for withdrawal
  TrackRecord track    // decayed, capped count of coherent+undisputed participations
}

Entry {
  bytes32 contentHash
  bytes32 metaHash
  uint40  approvalTime
  bool    uncontested   // true iff no reject vote AND never appealed; cleared by any contest
  uint    caseId        // back-reference for removal/settlement
}
```

`Case` is defined in §5.

---

## 3. Stake state machine

Each unit of a moderator's stake is in exactly one of three states. Stake is
**never destroyed and never transferred to another moderator** (design principle
2). Only the *owner's* balance moves between their own three sub-states.

```
        stake()                       commit to a vote
  ─────────────────▶ (activating) ───▶  FREE ───────────────▶ COMMITTED
                        │  activatesAt      ▲                     │
                        │  reached          │ case settles        │ settle:
                        ▼                    │ (coherent OR        │  coherent
                       FREE ◀────────────────┘  undisputed)       │  → FREE (+reward)
                        │                                          │  incoherent
              requestExit()                                        ▼  → FROZEN
                        │  after EXIT_COOLDOWN            ┌──────────────────┐
                        ▼                                 │      FROZEN      │
                     withdrawn                            │ until frozenUntil│
                                                          └────────┬─────────┘
                                                                   │ frozenUntil reached
                                                                   ▼
                                                                 FREE
```

States and transitions:

| From | To | Trigger | Notes |
|---|---|---|---|
| — | activating(FREE) | `stake(amount)` | `amount ≥ MIN_STAKE` on first stake; `activatesAt = now + ACTIVATION_DELAY`. Counts as free immediately but **not** draw-eligible until activated. |
| activating | draw-eligible FREE | `now ≥ activatesAt` | Enters `stakeTree`. Lazy: realized at next draw referencing it. |
| FREE | COMMITTED | `commitVote(caseId, H(vote,salt))` | Locks the moderator's at-risk stake for that case. Requires eligibility (§5.2). |
| COMMITTED | FREE (+reward) | case settles, voter **coherent or in an undisputed round** | Stake returns free; reward credited to `free`. |
| COMMITTED | FROZEN | case settles, voter **incoherent** | `frozenUntil = now + freezeDuration` (§6.4). |
| COMMITTED | FROZEN (brief) | committed but failed to reveal | short freeze (§6.3), vote discarded. |
| FROZEN | FREE | `now ≥ frozenUntil` | Lazy release on next interaction / explicit `thaw()`. |
| FREE | withdrawn | `requestExit()` then claim after `EXIT_COOLDOWN` | Only `free` stake; cooldown ensures pending judgments settle first. |

Constraints:
- A moderator may not `requestExit` more than their `free` balance.
- Committed stake cannot be exited or re-committed to another open case beyond
  the moderator's free balance (the amount at risk per case is a fixed working
  value or the moderator's stake, TBD by simulation — modeled in §11).
- `MIN_STAKE` is a floor on *total* (free+committed+frozen); dropping below it via
  exit is allowed only by fully exiting.

---

## 4. Case types

Two case types share the entire machine below:

1. **Submission** — approve/reject new content for the index.
2. **Removal request** (P1) — approve/reject deletion of an existing `Entry`.
   Same fee, subsets, outcomes, appeals. Coherence semantics per
   `MODERATION_GUIDELINES.md` §3.

They differ only in the settlement side effect (§8): a submission APPROVE writes
an `Entry`; a removal APPROVE deletes the targeted `Entry`.

---

## 5. Case state machine

### 5.1 Case state

```
Case {
  uint     id
  uint8    kind            // SUBMISSION | REMOVAL
  address  submitter
  bytes32  contentHash
  bytes32  metaHash
  bytes32[] topicKeys      // ≤ MAX_TOPICS
  uint     targetEntry     // removal only: index into indexByTopic
  uint     guidelinesVersion  // pinned at submission
  uint8    phase           // see §5.2
  uint8    depth           // 0..MAX_DEPTH
  uint     pot             // fee + forfeited bonds accumulated
  Round[]  rounds          // one per depth actually reached
  uint     snapshotBlock   // block whose prevrandao seeds current round's draw
  uint     phaseDeadline   // timestamp the current phase auto-advances / times out
  int8     finalOutcome    // UNSET | APPROVE | REJECT
}

Round {
  uint8    depth
  uint     nSeats           // COMMIT_TARGET[depth] — counted seats this round
  bytes32  seed             // realized randomness for the seat draw
  mapping(address => uint)    seats     // voter -> seats won (see §5.3)
  mapping(address => bytes32) commits
  mapping(address => bool)    reveals   // revealed vote (approve/reject); flat, unweighted
  uint     approveSeats     // Σ seats voting approve
  uint     rejectSeats      // Σ seats voting reject
  int8     outcome          // drawn probabilistically ∝ seat counts
  uint     bond             // bond that opened THIS round (0 for depth 0)
  address  appellant        // who bonded to open this round (0 for depth 0)
}
```

### 5.3 Selection and voting — one benefit from stake, not two

Stake grants a moderator exactly one advantage: it is drawn onto panels more
often. It does **not** additionally weight the verdict. This resolves a
double-count (stake-weighted selection *and* a stake-weighted tally over-
represented and over-weighted the same large stake); see the design review and
open question §11.6, now closed.

- **Seats.** A round has `nSeats = COMMIT_TARGET[depth]` counted seats. Each seat
  is drawn **stake-weighted, with replacement**, from the activated, unfrozen
  moderator set (the sortition tree, §2). A large stake may win several seats in
  proportion to its size; splitting a stake into many identities is neutral —
  expected seats track total stake however it is sliced (the anti-Sybil property
  of README §3.3).
- **Flat voting.** Every seat is worth exactly **one vote**. A voter holding `k`
  seats casts one commit-reveal vote that counts as `k` toward its chosen side.
- **Outcome.** Drawn probabilistically ∝ `approveSeats : rejectSeats` (§0). A
  50%-stake side therefore wins ≈ 50% of the time — never with certainty, and
  never more than its stake share (which a second, stake-weighted, tally would
  have granted).

This refines README §3.3/§3.4's "stake-weighted eligibility subset + first-five-
commits + stake-weighted tally" into the Kleros-style seat draw the README
already proposes reusing (§5). Commit-reveal still applies to the drawn seats;
under-participation (a drawn seat's holder offline) is handled by the widen /
re-draw path (§5.2). `SUBSET_FRACTION` bounds the eligible pool the seats are
drawn from for liveness and may, at small set sizes, be the whole activated set.

### 5.2 Phases and transitions

```
                    submit()                      first-5-commits OR COMMIT_TIMEOUT
   ┌──────────┐  fee ≥ minFee   ┌──────────┐   (≥ target commits landed)   ┌──────────┐
   │  (none)  │ ──────────────▶ │ COMMIT   │ ───────────────────────────▶ │  REVEAL  │
   └──────────┘  dedupe ok      └────┬─────┘                               └────┬─────┘
                                     │ COMMIT_TIMEOUT                            │ REVEAL_WINDOW ends
                                     │ & <target                                │
                                     ▼                                          ▼
                                (still opens REVEAL with whatever landed)   ┌──────────┐
                                                                            │  TALLY   │
                            reveals < MIN_REVEALS: widen subset, reopen ◀───┤ (atomic) │
                                                                            └────┬─────┘
                                                             draw outcome; write │ provisional
                                                             provisional index    ▼
                                                                            ┌──────────┐
                                        appeal() with bond ≥ floor          │  APPEAL  │
                              ┌──────── (depth < MAX_DEPTH) ◀───────────────┤  WINDOW  │
                              │                                             └────┬─────┘
                              ▼  depth++, new larger subset                      │ window ends, no appeal
                          ┌──────────┐                                           ▼
                          │  COMMIT  │  (loops back into the round cycle)   ┌──────────┐
                          └──────────┘                                      │FINALIZED │
                                          claim() after last window ───────▶│ (settle) │
                                                                            └──────────┘
```

Phase enum: `COMMIT, REVEAL, TALLY, APPEAL_WINDOW, FINALIZED, SETTLED`.

| From | To | Trigger | Guard / effect |
|---|---|---|---|
| (none) | COMMIT (depth 0) | `submit(content,meta,topics,fee)` | `fee ≥ minFee`; `nTopics ≤ MAX_TOPICS`; `!submissionExists[key]` (P3); pull fee → `pot`; `snapshotBlock = block + k`; set `phaseDeadline = now + COMMIT_TIMEOUT`. |
| COMMIT | REVEAL | `commitVote` makes commits reach `COMMIT_TARGET[depth]` **or** `now ≥ phaseDeadline` | Seed realized from `snapshotBlock`'s prevrandao (§7). Seats drawn stake-weighted with replacement for `seed` (§5.3). `phaseDeadline = now + REVEAL_WINDOW`. |
| REVEAL | TALLY | `now ≥ phaseDeadline` (or all committers revealed) | Atomic. |
| TALLY | COMMIT (same depth) | reveals `< MIN_REVEALS` | Widen subset (larger fraction / re-seed), reopen commit; bounded retries. |
| TALLY | APPEAL_WINDOW | reveals `≥ MIN_REVEALS` | Draw outcome ∝ seat counts (§0, §5.3). Update provisional index (§8.1). `phaseDeadline = now + APPEAL_WINDOW[depth]`. |
| APPEAL_WINDOW | COMMIT (depth+1) | `appeal(caseId){bond}` with `bond ≥ BOND_MULTIPLIER × pot` and `depth < MAX_DEPTH` | `bond → pot`; `depth++`; new `snapshotBlock`; `nSeats = COMMIT_TARGET[depth]`; record appellant. |
| APPEAL_WINDOW | FINALIZED | `now ≥ phaseDeadline` (no valid appeal) **or** `depth == MAX_DEPTH` window closes | `finalOutcome = rounds[last].outcome`. |
| FINALIZED | SETTLED | `claim()` | Anyone; pays `CLAIM_BOUNTY`; runs §6/§8. Idempotent guard: only once. |

Notes:
- The **appeal window at MAX_DEPTH still runs** (a final round can still be
  observed) but no further appeal is accepted; it closes to FINALIZED.
- At depth 0 there is no bond and no appellant; `pot` = fee only.

---

## 6. Settlement

Runs atomically inside `claim()` after `finalOutcome` is set. Order matters.

### 6.1 Determine coherence per round

For each `Round r` in the case, and each address that revealed a vote in `r`:
- **coherent** iff `reveal.approve == (finalOutcome == APPROVE)`.
- A **case** is **undisputed** iff no appeal was ever opened (it finalized at
  depth 0). Track record accrues only on undisputed cases (§6.5); the pot is
  split across coherent seats of **all** rounds (§6.2).

### 6.2 The pot → coherent voters (no transfers between moderators)

```
pot = fee + Σ forfeited bonds of losing appellants
```

An appellant **loses** their bond iff the outcome they were appealing *for*
(i.e. flipping to) is not the final outcome. A **winning** appellant (their
appeal flipped the case toward `finalOutcome`) gets their bond returned **plus a
bonus** from the pot (appealing a wrong outcome is a paid service).

Reward distribution (by **coherent seats**, flat — consistent with §5.3; stake
already paid off in selection, so it is not re-counted here):
- Compute `winnersSeats` = total seats, across all rounds, whose vote is coherent
  with `finalOutcome`.
- Each coherent voter receives `pot_remaining × (theirCoherentSeats /
  winnersSeats)`, credited to their `free` balance. (Exact per-round weighting —
  whether later rounds count more — is a simulation deliverable; §11.)
- `CLAIM_BOUNTY` and winning-appellant bonuses come off the top of `pot` first;
  a winning appellant's bond is refunded (its own capital) before distribution.
- **No moderator's principal is ever paid to another moderator.** Every credit
  above is external money (fee + forfeited bonds).

### 6.3 Failed-reveal handling

An address that committed but did not reveal in a round:
- its vote is discarded (does not count in tally),
- takes a **brief freeze** (short, fixed working value — deters commit-and-vanish
  griefing), independent of coherence,
- earns no reward.

### 6.4 Freezing incoherent voters

For each incoherent voter `v` (revealed ≠ finalOutcome):
```
meanTrack     = Σ(seats_i × track_i) / Σ seats_i   over coherent voters   // seat-weighted MEAN
power         = 1 + (FREEZE_CAP − 1) × (1 − exp(−meanTrack / TRACK_SAT))  // 1 .. FREEZE_CAP
freezeDur     = FREEZE_BASE × power
v.frozen     += v.committedInCase
v.committed  -= v.committedInCase
v.frozenUntil = max(v.frozenUntil, now + freezeDur)
```
`freezingPower` uses the **seat-weighted mean** of the winning side's track
records, *not the sum* — this is what makes it **identity-split resistant**:
dividing one moderator's history across many identities cannot inflate an
average (principle 4). The saturating curve above is the chosen shape; `TRACK_SAT`
is calibrated so a cheap farm cannot approach the cap (§11.3, now closed; see
`simulation/FINDINGS.md` §3). No stake leaves `v` — it is locked, not taken.

### 6.5 Track-record update

A coherent voter increments its `track` only on a participation that is
**undisputed** (the case drew no appeal) **and** whose stake is at/above the
`MIN_STAKE` floor — so a min-stake identity farm accrues slowly and a disputed
case grants no history. Everyone else's `track` only **decays**
(`track ← track × TRACK_DECAY`). Together with the seat-weighted-mean freezing
power above, this bounds track-record farming (README §7); `TRACK_DECAY`/
`TRACK_SAT` are calibrated in `simulation/FINDINGS.md` §3.

---

## 7. Randomness

- Seed source: `block.prevrandao` on Gnosis.
- **Snapshot rule:** the seed for a round's seat draw *and* outcome draw is the
  `prevrandao` of `snapshotBlock`, where `snapshotBlock` is set a few blocks *after*
  the phase boundary (submission / appeal). It is realized (read and stored in
  `Round.seed`) by the **first transaction after** `snapshotBlock`.
- Rationale and limits: proposer manipulation is real but only pays above per-case
  pot sizes that fee/bond caps keep small (README §3.7). VDF / randomness-oracle
  upgrade path documented if pots grow.
- The subset draw is stake-weighted over the moderator set **as it existed before
  the submission block**, restricted to **activated** stake (`now ≥ activatesAt`).

---

## 8. Index effects (README 3.8)

### 8.1 Provisional (at each TALLY that yields APPROVE, depth 0 only writes)

On the **depth-0** APPROVE tally, a submission writes an `Entry` per topic:
```
Entry{ contentHash, metaHash, approvalTime = now, uncontested = (rejectStake == 0), caseId }
```
- `uncontested` starts `true` only if **no reject vote was revealed** in round 0.
- Any **contest** — a revealed reject vote, or any appeal being opened — sets
  `uncontested = false` and it is never restored.

### 8.2 At FINALIZED/SETTLED

- Submission finalizes **REJECT** → remove the `Entry` (if it was written).
- Submission finalizes **APPROVE** → keep the `Entry`; `uncontested` reflects
  whether it was ever contested.
- Removal-request finalizes **APPROVE** (remove) → delete `targetEntry`.
- Removal-request finalizes **REJECT** (keep) → no index change.

### 8.3 Search views (client-side, from view functions)

- **Superset:** every current `Entry` under a topic.
- **Supersafe subset:** `uncontested == true && now − approvalTime ≥ SUPERSAFE_AGE`.
- Provisional badge (P7): `now − approvalTime < SUPERSAFE_AGE || !uncontested`.

### 8.4 Topic hygiene (P2)

- Topic keys are `keccak(normalize(topic))`, `normalize` = lowercase + trim + NFC.
- First use of a topic emits `TopicCreated(string)` for UI autocomplete.
- `nTopics ≤ MAX_TOPICS` — **also** a gas-safety cap: finalization loops over
  topics, so an unbounded loop could exceed the block gas limit and strand the
  pot (must be tested explicitly, §10).

---

## 9. Invariants (must hold at every block)

1. **Conservation:** `tokenBalance(contract) == totalFreeStake + Σ committed +
   Σ frozen + Σ live case pots`. No idle treasury (README §4).
2. **No internal transfer:** no execution path moves stake principal from one
   moderator to another. Rewards credited to voters come only from `pot` (fees +
   forfeited bonds). *(Test: property test that Σ principal per address is
   non-decreasing except by that address's own `requestExit`/withdraw.)*
3. **Stake sub-state partition:** for every moderator, `free + committed + frozen`
   equals their tracked stake; each unit in exactly one sub-state.
4. **Freeze is release-only-forward:** a frozen balance can only become free after
   `frozenUntil`; it can never be paid out to anyone.
5. **Withdrawals never pausable** (P6): `requestExit`/`withdraw` have no admin gate.
6. **Guidelines pinning:** a case's `guidelinesVersion` never changes after submit.
7. **Dedup:** `submissionExists[H(content,meta,topicKey)]` prevents a duplicate
   (content,meta,topic) triple (P3); different topics for same content are
   distinct keys and each pays its own fee.
8. **Finalizability:** every case that reaches FINALIZED can be SETTLED within one
   block's gas (bounded by `MAX_TOPICS` and subset sizes) — no stranded pots.
9. **Governance bound (P6):** only the parameters in §1 are mutable, only via
   multisig+timelock; core transitions in §3/§5 are immutable.
10. **Single stake benefit (no double-count):** stake affects a case only through
    seat selection (§5.3); the tally and reward are by flat seat counts. No path
    weights a vote or a reward by stake. A faction's expected influence and payout
    are proportional to its stake exactly once. *(Test:
    `test_first_round_outcome_tracks_stake_share`.)*

---

## 10. Gas-bound / failure-mode tests (M2 must include)

- Finalization/settlement at `nTopics == MAX_TOPICS` and largest subset
  (`COMMIT_TARGET[MAX_DEPTH]`) stays under block gas limit (Invariant 8).
- A case that reaches MAX_DEPTH with maximal reveals settles in one `claim()`.
- Widen-on-under-participation cannot loop unboundedly.
- Duplicate submission rejected (P3). Over-`MAX_TOPICS` rejected (P2).
- Removal of a non-existent / already-removed entry is a no-op / reverts cleanly.

---

## 11. Simulation status — resolved vs still open

Parameters and formula choices the agent-based simulation (README §7, M1) is
resolving. See `simulation/FINDINGS.md` for the evidence behind each.

**Resolved (decided; reflected above):**

- **§11.3 freezing-power shape** — saturating curve `1 + (CAP−1)(1 − e^(−mean/SAT))`
  over the **seat-weighted mean** winning-side track (split-resistant); §6.4.
- **§11.4 anti-farming** — mean (not sum) track, plus accrual gated on
  undisputed + coherent + `MIN_STAKE`; §6.5. Sim shows a cheap 30-case farm buys
  ~1.6× power and no real freeze advantage (FINDINGS §3).
- **§11.6 per-case stake benefit (the double-count)** — **stake-weighted seat
  selection with replacement + flat voting** (reviewer decision); §5.3, invariant
  10. Bonds scale with the pot; §5.2.

**Still open (calibration, not structure):**

1. `SUBSET_FRACTION(N)` curve, and `COMMIT_TARGET` (seat counts) per depth.
2. `BOND_MULTIPLIER` magnitude (structure fixed: bond ≥ `BOND_MULTIPLIER × pot`).
3. `FREEZE_BASE` and `FREEZE_CAP` magnitudes; `TRACK_SAT`/`TRACK_DECAY` fine-tuning.
4. Per-round reward weighting (do later, larger rounds count more? §6.2).
5. `FEE_BASE`, `FEE_PER_TOPIC` floor — needs an external cost-of-a-moderation-call
   model before it can be fixed (FINDINGS §2).
6. `REVEAL_WINDOW`, under-participation retry bound, `MIN_REVEALS` under
   correlated (bursty) offline behaviour.

Each is validated against the attack scenarios: probability-buying whales, bond
wars up the appeal ladder, track-record farming, first-come racing / copy-voting,
under-participation, and honest-moderator earnings across the fee/bond/freeze
values.
