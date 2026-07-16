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
  draw in `[0, a+b)` against `a`. Here `a` and `b` are **seat counts** (§5.2),
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
| `ACTIVATION_DELAY` | Delay before newly staked xBZZ is eligible for seat draws | 7 days |
| `COMMIT_TARGET[d]` | Counted **seats** at depth `d` (flat votes; drawn stake-weighted with replacement, §5.2) | `d0:5, d1:11, d2:23, d3:47` |
| `COMMIT_TIMEOUT` | Max commit-phase duration if not all seat-holders commit | 24 h |
| `REVEAL_WINDOW` | Reveal-phase duration | *(working)* 24 h |
| `MIN_REVEALS` | Minimum revealed seats to tally; below this the panel widens | 3 |
| `MAX_WIDEN` | Max widen re-draws before a round VOIDs (§5.3) | 3 |
| `APPEAL_WINDOW[d]` | Appeal window after depth `d`'s outcome | `d0:4 days, else:3 days` |
| `MAX_DEPTH` | Maximum appeal depth | 3 |
| `BOND_MULTIPLIER` | Each appeal flip-bond ≥ this × current pot | 2× |
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
`FEE_BASE` covers the depth-0 panel's minimum voter pay (`COMMIT_TARGET[0] ·
margin · c`, for per-judgment cost `c`) plus fixed gas; `FEE_PER_TOPIC` covers one
index write's gas. Derivation and calibration: `simulation/costs.py`, FINDINGS §2b.

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
  uint     openPotsTotal             // sum of all LIVE case pots only (committed and
                                     // frozen are tracked per-moderator; all three are
                                     // summed separately in the §9 conservation invariant)

  // --- governance (P6) ---
  address  governanceMultisig
  uint     timelockDelay
  mapping(uint => bytes32) guidelinesHashByVersion  // version -> pinned hash (full
                                     // history, so a case pinned to version N is verifiable
                                     // against N's hash after later updates)
  uint     guidelinesVersion         // current version
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

### 5.1 Case and round state

```
Case {
  uint     id
  uint8    kind              // SUBMISSION | REMOVAL
  address  submitter
  bytes32  contentHash
  bytes32  metaHash
  bytes32[] topicKeys        // ≤ MAX_TOPICS
  uint     targetCaseId      // removal only: the submission case whose index
                             // entries (across all its topics) this removal targets (§8.2, P1)
  uint     guidelinesVersion // pinned at submission
  uint8    phase             // see §5.3
  uint8    depth             // 0..MAX_DEPTH
  uint     pot               // fee + forfeited (losing) bonds accumulated
  Round[]  rounds            // one per depth actually reached
  uint     phaseDeadline     // timestamp the current phase auto-advances / times out
  int8     finalOutcome      // UNSET | APPROVE | REJECT | VOID
}

Round {
  uint8    depth
  uint     nSeats            // COMMIT_TARGET[depth] — counted seats this round
  uint     seatSnapshotBlock // block whose prevrandao seeds THIS round's seat draw
  uint     outcomeSnapshotBlock // block AFTER reveals close, seeding the outcome draw (§7)
  bytes32  seatSeed          // realized: the seat draw
  bytes32  outcomeSeed       // realized after reveals close: the outcome draw
  mapping(address => uint) seats     // seat-holder -> seats won (§5.2)
  mapping(address => bytes32) commits
  mapping(address => Vote) reveals   // Vote ∈ {None, Approve, Reject}; flat, unweighted
  uint     approveSeats      // Σ seats revealing Approve
  uint     rejectSeats       // Σ seats revealing Reject
  int8     outcome           // drawn probabilistically ∝ seat counts
  int8     appealFor         // the outcome this round's appeal argues for (0 at depth 0)
  uint     bond              // total flip-bond that opened THIS round (0 at depth 0)
  mapping(address => uint) bondContribs  // contributor -> amount (pro-rata refund/bonus, §5.4)
}

Vote enum: None (not revealed), Approve, Reject.
```

### 5.2 Selection and voting — one benefit from stake, not two

Stake grants a moderator exactly one advantage: it is drawn onto panels more
often. It does **not** additionally weight the verdict. This resolves a
double-count (stake-weighted selection *and* a stake-weighted tally over-
represented and over-weighted the same large stake); design review, §11.6.

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
already proposes reusing (§5). There is no first-come race: the panel is the drawn
seat set, not whoever commits first. Commit-reveal still applies to the drawn
seats; under-participation (a drawn seat's holder offline) is handled by the widen
/ re-draw path (§5.3).

### 5.3 Phases and transitions — draw first, then commit

The panel is **drawn before commits open**, which the previous ordering left
undefined (it ended the commit phase on a commit count, yet drew the panel at the
commit→reveal edge — leaving "who may commit" ambiguous, and either resolution
broke a load-bearing property). Only drawn seat-holders may commit.

```
 submit()      DRAW: realize seatSeed,       only seat-holders commit    reveal
 fee≥minFee    draw nSeats from tree         (COMMIT_TIMEOUT)            (REVEAL_WINDOW)
 (none) ─────▶ DRAW ────────────────▶ COMMIT ──────────────────▶ REVEAL ─────────▶ TALLY
                 ▲                                                                    │
                 │ widen: +nSeats more seats, seatSeed=H(seatSeed,w), ≤ MAX_WIDEN  ◀──┤ reveals < MIN_REVEALS
                 │                                                                    │
                 │                          reveals == 0 after MAX_WIDEN ──▶ VOID  ◀──┤ (fee refunded − bounty;
                 │                                                                    │  dedup key cleared)
   appeal():     │                     realize outcomeSeed (block after reveals),     │ reveals ≥ MIN_REVEALS
   flip-bond ≥   │                     draw outcome ∝ seats                           ▼
   BOND_MULT×pot │                                                            APPEAL_WINDOW
   (depth<MAX) ──┘◀── DRAW (depth+1) ◀──────────────────────────────────────────┤    │
                                                                                      │ window closes, no appeal
                                                       claim() ──▶ SETTLED  ◀── FINALIZED
```

Phase enum: `DRAW, COMMIT, REVEAL, TALLY, APPEAL_WINDOW, FINALIZED, VOID, SETTLED`.

| From | To | Trigger | Guard / effect |
|---|---|---|---|
| (none) | DRAW (depth 0) | `submit(content,meta,topics,fee)` | `fee ≥ minFee`; `nTopics ≤ MAX_TOPICS`; `!submissionExists[key]` (P3); pull fee → `pot`; `seatSnapshotBlock = block + k`. |
| DRAW | COMMIT | first tx after `seatSnapshotBlock` | Realize `seatSeed` from its prevrandao (§7); draw `nSeats` seats stake-weighted with replacement (§5.2). `phaseDeadline = now + COMMIT_TIMEOUT`. |
| COMMIT | REVEAL | all seat-holders committed **or** `now ≥ phaseDeadline` | Only drawn seat-holders may `commitVote`. `phaseDeadline = now + REVEAL_WINDOW`. |
| REVEAL | TALLY | `now ≥ phaseDeadline` (or all committers revealed) | Atomic. |
| TALLY | DRAW (same depth, widen) | revealed seats `< MIN_REVEALS` and `widen < MAX_WIDEN` | Draw `nSeats` **additional** seats with `seatSeed = H(seatSeed, widen)`; reopen COMMIT. |
| TALLY | VOID | revealed seats `== 0` after `MAX_WIDEN` | No outcome. Refund `fee − CLAIM_BOUNTY` to submitter; clear `submissionExists[key]` (resubmittable, §8/P3). |
| TALLY | APPEAL_WINDOW | revealed seats `≥ MIN_REVEALS` | Set `outcomeSnapshotBlock = block + k`; realize `outcomeSeed` from its prevrandao; draw outcome ∝ seat counts (§0). `phaseDeadline = now + APPEAL_WINDOW[depth]`. |
| APPEAL_WINDOW | DRAW (depth+1) | flip-bond contributions reach `BOND_MULTIPLIER × pot` and `depth < MAX_DEPTH` (§5.4) | `bond → pot`; `depth++`; `appealFor = opposite(outcome)`; `seatSnapshotBlock = block + k`; `nSeats = COMMIT_TARGET[depth]`. |
| APPEAL_WINDOW | FINALIZED | `now ≥ phaseDeadline` (bond floor not met) **or** `depth == MAX_DEPTH` window closes | `finalOutcome = rounds[last].outcome`. |
| FINALIZED | SETTLED | `claim()` | Anyone; pays `CLAIM_BOUNTY`; runs §6/§8. Idempotent guard: only once. |

Notes:
- The **appeal window at MAX_DEPTH still runs** but accepts no further appeal; it
  closes to FINALIZED.
- At depth 0 there is no bond and no appellant; `pot` = fee only.
- The **outcome seed is realized only after reveals close** (§7), so the tally is
  fixed before the outcome randomness exists — strategic reveal-withholding
  cannot steer a draw whose seed is already known.

### 5.4 Appeals are directional flip requests, not slots

An appeal is a request to **flip** the current outcome, funded by a bond — not a
first-come slot that one address captures. During an appeal window, **anyone** may
contribute toward the window's flip-bond (`bondContribs`); the next round opens
once contributions reach the floor `BOND_MULTIPLIER × pot`. At settlement, if the
flip succeeds (this round's `appealFor` equals `finalOutcome`), contributors are
refunded pro-rata and share the winning-appellant bonus pro-rata (§6.2); if it
fails, their contributions are forfeited into the pot. This removes the
single-appellant capture where one sock-puppet monopolizes the slot.

**Self-appeal economics.** A majority attacker can still bond an appeal of a round
it just won (to burn depth or intimidate). This is a *costly discount*, not a free
move: the forfeited bond, when the self-appeal loses, is split among the round's
coherent seats — of which only the attacker's **seat share** is its own, so a
fraction `(1 − attackerSeatShare)` leaks to honest voters; and each self-appeal
re-rolls a probabilistic round the attacker had already won, risking reversal. A
global-majority attacker gains nothing structural from self-appeal; it only pays.

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

Reward distribution (by **coherent seats**, flat — consistent with §5.2; stake
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

A coherent voter increments its `track` only on an **undisputed** participation
(the case drew no appeal) — so a disputed case grants no history. Everyone else's
`track` only **decays** (`track ← track × TRACK_DECAY`). (An earlier draft also
gated on a `MIN_STAKE` floor, but every moderator's stake is ≥ `MIN_STAKE` by
construction, so that clause was vacuous and has been removed.) The split-resistant
seat-weighted-mean freezing power (§6.4) is what bounds farming; `TRACK_DECAY` /
`TRACK_SAT` are calibrated in `simulation/FINDINGS.md` §3.

---

## 7. Randomness — two independent seeds

- Seed source: `block.prevrandao` on Gnosis.
- **Two seeds per round, not one.** The earlier design used a single snapshot for
  both the seat draw and the outcome draw; that seed is public before reveals
  close, so a voter could compute which tally wins under the known seed and
  withhold reveals to steer it — defeating "no outcome can be engineered"
  (README §2). The round therefore has:
  - **`seatSeed`** — `prevrandao` of `seatSnapshotBlock` (a few blocks after the
    round opens), realized by the first tx after it. Seeds the seat draw only.
  - **`outcomeSeed`** — `prevrandao` of `outcomeSnapshotBlock`, set only **after
    the reveal window closes** and the tally is fixed, realized by the first tx
    after it. Seeds the probabilistic outcome draw only.
  Because the tally is final before `outcomeSeed` exists, strategic
  reveal-withholding cannot target a known draw. (Withholding a reveal still
  incurs the §6.3 failed-reveal freeze and forfeits that seat's pay.)
- **Manipulation cost is priced against the listing, not the pot.** Proposer
  influence over either snapshot block is real. A prior claim bounded its value by
  per-case pot size, but the attacker's actual prize is the **listing itself**
  (uncapped SEO value, README §3.6/§4), so pot-size caps do not bound it. This is
  an accepted MVP assumption (Gnosis proposer set, per-case leverage is small and
  a biased listing remains re-litigable); the VDF / randomness-oracle upgrade
  path is the mitigation if listing value grows large.
- Both draws are over the moderator set **as it existed before the round opened**,
  restricted to **activated, unfrozen** stake (`now ≥ activatesAt`, not frozen).

---

## 8. Index effects (README 3.8)

### 8.1 Entries are written at SETTLEMENT, not provisionally

Index writes happen **only at settlement, on a final APPROVE** — there is no
depth-0 provisional write. The previous design wrote at the depth-0 APPROVE tally
and deleted on a later REJECT, which had two defects: an approval **won on
appeal** (rejected at depth 0, flipped to APPROVE later) was never written, and a
provisional entry briefly polluted the index. Writing at settlement fixes both.

On a submission finalizing **APPROVE**, write an `Entry` per topic:
```
Entry{ contentHash, metaHash, approvalTime = settlementTime, uncontested, caseId }
```
- `approvalTime` is the settlement time (used by the supersafe age filter, §8.3).
- **`uncontested = true` iff no `Reject` vote was ever revealed in any round of
  the case.** An **appeal alone does not clear it**: a frivolous appeal that draws
  a fresh panel which again reveals *no* reject vote leaves the entry uncontested.
  Rationale: `uncontested` exists to mark entries no dissenting voter ever
  opposed; unanimous rounds involve no probabilistic draw, so the "snuck back in
  via a lucky draw" concern the flag guards against cannot arise. This also closes
  a griefing vector — under the old rule a vandal could permanently exclude any
  entry from the supersafe view for the price of one abandoned appeal.

### 8.2 At SETTLED

- Submission finalizes **APPROVE** → write the per-topic entries (§8.1).
- Submission finalizes **REJECT** → no entry is written; clear `submissionExists`
  (P3, resubmittable).
- Submission **VOID** (all-offline, §5.3) → no entry; `submissionExists` cleared.
- Removal-request finalizes **APPROVE** (remove) → delete every entry with
  `caseId == targetCaseId` across all its topics (by `(topicKey, caseId)`,
  swap-and-pop); clear that submission's `submissionExists` (P3).
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
   block's gas (bounded by `MAX_TOPICS` and seat-panel sizes) — no stranded pots.
9. **Governance bound (P6):** only the §1 numeric parameters are mutable, and new
   `guidelinesHashByVersion` entries may be added (never mutated), all via
   multisig+timelock; core transitions in §3/§5 are immutable and withdrawals are
   never pausable.
10. **Single stake benefit (no double-count):** stake affects a case only through
    seat selection (§5.2); the tally and reward are by flat seat counts. No path
    weights a vote or a reward by stake. A faction's expected influence and payout
    are proportional to its stake exactly once. *(Test:
    `test_first_round_outcome_tracks_stake_share`.)*
11. **Funds conservation:** for every settled case, `fee + Σ bonds == Σ refunds +
    claim bounty + Σ rewards` — no path mints or destroys value (WO-1). *(Test:
    `test_settlement_conserves_funds`.)*

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
- **§11.4 anti-farming** — mean (not sum) track, accrual gated on undisputed +
  coherent (§6.5). Campaign-mode simulation (freeze now bites) shows farming buys
  no reliable attack-success advantage (FINDINGS §3); magnitudes calibrated in
  WO-6/§6.
- **§11.6 per-case stake benefit (the double-count)** — **stake-weighted seat
  selection with replacement + flat voting** (reviewer decision); §5.2, invariant
  10. Appeals are directional flip bonds scaling with the pot; §5.4.
- **Structural fixes from adversarial review** — solvent settlement (§6.2,
  invariant 11); two-seed randomness (§7); index writes at settlement (§8.1);
  `uncontested = no reject ever` (§8.1); dedup cleared on REJECT/VOID/removal
  (§8.2); draw-then-commit ordering with VOID (§5.3).
- **fee-floor structure** — `minFee = COMMIT_TARGET[0] · (margin · c) + gasCost`
  (`simulation/costs.py`); gas negligible, moderators clear costs at `margin ≈ 2`
  (FINDINGS §2b).

**Still open (magnitudes and behaviours bound to real inputs, not structure):**

1. `COMMIT_TARGET` (seat counts) per depth.
2. `BOND_MULTIPLIER` magnitude (structure fixed: bond ≥ `BOND_MULTIPLIER × pot`).
3. `FREEZE_BASE`, `FREEZE_CAP`, `TRACK_SAT`, `TRACK_DECAY` — freeze/farming
   magnitudes (see §6, calibrated in FINDINGS §3).
4. Per-round reward weighting (do later, larger rounds count more? §6.2).
5. Fee-floor inputs: `margin` and the operator cost `c`; final gas from M2's
   measured `SSTORE` costs.
6. `REVEAL_WINDOW`, `MAX_WIDEN`, `MIN_REVEALS` under correlated (bursty) offline.
7. **Behavioural sensitivities the model exposes (README §7):** attacker profit
   as a function of the honest side's appeal rationality (naive vs EV-gated);
   whale success as a function of content difficulty and honest liveness;
   correlated honest error. These are not single numbers — FINDINGS reports them
   as ranges, and they inform, not resolve, the parameter choices.

Each is validated against the attack scenarios: probability-buying whales, bond
wars up the appeal ladder, track-record farming, copy/correlated voting,
under-participation, and honest-moderator earnings across the fee/bond/freeze
values.
