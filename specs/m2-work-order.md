# M2 Work Order — Solidity Contract

**From:** Fable 5 (orchestrator, M2 scoping pass)
**To:** Opus 4.8 (builder)
**Base:** `main` @ `1e9747a` (M1 fully landed: WO-1→9 + README sync)
**Branch:** `claude/determined-curie-nkf71s` (already reset to base)
**Target:** README §8 M2 — the Solidity contract implementing `specs/state-machine.md`,
with a full Foundry test suite including invariant/fuzz tests, differential tests
against the M1 simulation, and gas-bound tests on finalization/settlement.

Same rules as the M1 work order:

1. One work item per commit, in order. Commit message `M2-N: <summary>`.
2. `forge test` green at every commit. Never move on with a red suite.
3. Part A decisions are **made** — do not re-litigate them. If one proves
   genuinely unimplementable, stop that item, record why in
   `contracts/DEVIATIONS.md`, and ask before improvising a replacement.
4. Small discoveries (a missing guard, an off-by-one) get fixed in the item
   where you find them and mentioned in that commit message — not silently.
5. The spec (`specs/state-machine.md`) is the source of truth for mechanics;
   the sim (`simulation/`) is the source of truth for calibrated magnitudes and
   settlement arithmetic order. Where the two disagree, the spec's structure
   wins and the disagreement goes in `DEVIATIONS.md`.

---

## Part A — Decisions (resolved; build to these)

### D1. Toolchain: Foundry, minimal dependencies

- Install via `foundryup`, pin the version in `contracts/README.md`. Outbound
  HTTPS goes through the environment proxy (CA bundle
  `/root/.ccr/ca-bundle.crt`); if installs fail TLS, consult
  `/root/.ccr/README.md` — never disable TLS verification.
- Project root: `contracts/` (repo top level), standard forge layout
  (`src/`, `test/`, `foundry.toml`).
- Dependencies: `forge-std` (tests) and `solady` (FixedPointMathLib — `expWad`
  for the freeze-power curve; optionally its ERC20 for the mock token). Nothing
  else. No OpenZeppelin unless a concrete need appears (record it if so).
- Solidity `^0.8.24` or the current forge default 0.8.x, pinned in
  `foundry.toml`.

### D2. Sortition: clean 0.8.x port of the Kleros sum-tree design (verified MIT)

Verified 2026-07-16: `kleros/kleros` is MIT-licensed; its
`SortitionSumTreeFactory.sol` is `pragma ^0.4.24`, so verbatim import is
impossible. Therefore:

- Write `src/lib/SortitionTree.sol` as a **storage-struct library**, a clean
  0.8.x implementation patterned on the Kleros design (sum tree, weighted
  descent draw). Header comment: *"Design after Kleros' SortitionSumTreeFactory
  (MIT); reimplemented for Solidity 0.8.x."*
- Binary tree (K=2). Kleros uses higher K for gas; K is an internal detail we
  can tune later — correctness first.
- API: `set(tree, id, weight)` (insert/update; weight 0 removes),
  `draw(tree, rand) → id`, `total(tree)`, `weightOf(tree, id)`.
- **Seats with replacement** (spec §5.2): seat `i` of a round is
  `draw(tree, uint(keccak256(abi.encode(seatSeed, i))))`. One address may win
  several seats.
- **Eligibility is maintained eagerly, in the tree itself** — the tree always
  contains exactly the draw-eligible weight, so `draw` never filters and never
  rejection-samples:
  - tree weight of a moderator = their **activated free stake**, and **0 while
    frozen** (see D5/D6);
  - every transition that changes eligible weight updates the tree in the same
    tx: `activate()`, `commitVote` (weight down), settlement (weight
    restored/zeroed), `thaw()` (restored), `requestExit`/`withdraw` (down).

### D3. Module decomposition: one deployed contract + internal libraries

- Single deployed contract `src/Moderation.sol` holding all state: moderators,
  the sortition tree, cases, index, accounting, governance. The §9.1
  conservation invariant is over one token balance — keep it in one contract;
  no cross-contract calls in the core loop.
- Internal libraries for testable units: `src/lib/SortitionTree.sol` (D2) and
  `src/lib/FreezeMath.sol` (freeze power + track update, pure WAD math).
  Settlement order lives in `Moderation.sol` itself (it touches everything).
- Token: xBZZ is an ERC20 on Gnosis, injected as `IERC20` in the constructor.
  Tests use a local mock. **Caution: BZZ/xBZZ uses 16 decimals, not 18** —
  verify at M2-0 and record in `contracts/README.md`; all internal fixed-point
  math is WAD (1e18) regardless of token decimals; never hardcode 1e18 as "one
  token".

### D4. Randomness: blockhash-snapshot realization with re-arm (spec delta)

Spec §7 says "prevrandao of the snapshot block, realized by the first tx after
it" — but the EVM cannot read a **past** block's prevrandao. Implement the same
discipline with `blockhash`:

- On arming: `snapshotBlock = block.number + SEED_LAG` (`SEED_LAG = 2`,
  working value).
- Realization poke (permissionless): requires `block.number > snapshotBlock`;
  `seed = blockhash(snapshotBlock)`. If `blockhash` returns 0 (older than 256
  blocks — nobody poked for ~21 min), **re-arm**: `snapshotBlock =
  block.number + SEED_LAG` and wait again. Unbounded re-arms are fine (pure
  liveness, same trust class as `claim()` being permissionless).
- Two seeds per round exactly as spec §7: `seatSeed` armed at round open;
  `outcomeSeed` armed **only after the reveal window closes** (tally fixed
  before the outcome randomness exists). Widen re-draws derive
  `seatSeed = keccak256(seatSeed, widenCount)` — no new snapshot.
- Threat model unchanged (proposer influence, accepted MVP per spec §7);
  record the prevrandao→blockhash substitution in `DEVIATIONS.md` and as an
  (M2) note in spec §7 at M2-10.

### D5. Commit-stake semantics: `RISK_PER_SEAT`, a new working parameter

Spec §3 left the per-case at-risk amount "TBD by simulation". Pinned now:

- `RISK_PER_SEAT = MIN_STAKE` (i.e. 10 xBZZ per seat, working value).
- `commitVote` moves `RISK_PER_SEAT × seatsWon` from `free → committed` and
  reduces tree weight by the same amount. Requires `free ≥` that amount — a
  drawn seat-holder who can't cover it simply doesn't commit (the widen path
  §5.3 already handles absent seats).
- At settlement: coherent → committed slice back to `free` (+reward);
  incoherent → committed slice to `frozen` (D6); failed reveal → slice back to
  `free` but a **brief** freeze applies (spec §6.3, `FAILED_REVEAL_FREEZE = 1
  day`).
- This is a **new §1 parameter** — add it to the spec table at M2-10, marked
  *(working, uncalibrated — M1 sim did not model per-case locking)*.

### D6. Freeze semantics: balance-slice accounting, whole-moderator exclusion

Reconciling spec §6.4 (freezes `committedInCase`) with the sim (freeze excludes
the whole moderator from draws — what the M1 findings measured):

- **Balances** follow the spec partition: only the case's committed slice moves
  `committed → frozen`; it returns to `free` via `thaw()` once
  `now ≥ frozenUntil`.
- **Draw eligibility** follows the sim: `frozenUntil` is per-moderator; while
  `now < frozenUntil` the moderator's tree weight is **zero** (fully excluded
  from draws), regardless of how small the frozen slice is.
  `frozenUntil = max(frozenUntil, now + FREEZE_BASE × power)` per §6.4.
- `activate()` and `thaw()` are explicit permissionless pokes (the spec's "lazy
  realization" cannot work inside an eager sum tree). Record as spec delta.

### D7. Integer arithmetic and rounding

- All amounts `uint256` in token base units. No floating point (spec §0).
- Every pro-rata division **rounds down**; all dust from a settlement's
  round-downs is added to the **claim bounty** (the claimant absorbs the
  remainder). This keeps invariant 11 an **exact integer equality**, not a
  tolerance: `fee + Σbonds == Σrefunds + claimBounty + Σbonuses + Σrewards`.
- Track record and freeze power in WAD via solady; token amounts never mix
  with WAD without explicit scaling.

### D8. Settlement order: the WO-1 order, verbatim, in integers

`claim()` executes in exactly this order (mirrors `protocol.py` post-WO-1):

1. Refund each **winning** appeal-round's bond contributions pro-rata (their
   own capital back).
2. `residual = pot − refunds`.
3. `claimBounty = CLAIM_BOUNTY_FRAC × residual` (+ all dust, D7) → claimant.
4. Winning-appellant **bonus** = `BONUS_FRAC × residual`, pro-rata over that
   round's `bondContribs`.
5. `distributable = residual − claimBounty − bonuses` → coherent seats, flat
   pro-rata by seat count across all rounds (§6.2).
6. Freezes (incoherent, then failed-reveal briefs), tree-weight zeroing.
7. Track updates (§6.5): coherent participants in an **undisputed** case get
   `track = track × TRACK_DECAY + 1`; every other **participant** of the case
   gets `track ×= TRACK_DECAY`. Only the case's participants are touched
   (bounded by panel sizes). Match `protocol.py` semantics exactly — read it
   first, port faithfully.
8. Index effects (§8.2), dedup lifecycle.

### D9. Gas budgets

Worst case is bounded by design: max voters/case = 5+11+23+47 = **86 seats**,
`MAX_TOPICS = 5`. Initial budgets (assert via forge gas snapshots + explicit
`vm` gas metering in tests):

| Path | Budget |
|---|---|
| `claim()` worst case (MAX_DEPTH, all reveal, 5 topics) | **< 8,000,000 (hard ceiling)** |
| `submit` (5 topics) | < 400k |
| seat-draw poke (1000 moderators, 47 seats) | < 2M |
| `commitVote` / `reveal` | < 150k / < 120k |
| `contributeAppealBond` | < 150k |

Soft budgets may be adjusted to measured reality (record actuals in
`contracts/GAS_BUDGETS.md`); the **8M ceiling is hard** — it's block-limit
headroom (Gnosis ≈ 17M — verify at M2-0 and record). If worst-case `claim()`
breaches it, that is a design change (pull-based reward claims), which you
stop and report rather than improvise.

### D10. The simulation is the test oracle (differential testing)

Floats in the sim can't be compared to uint256 directly, so:

- Write `simulation/vectors/reference_int.py`: a small **integer** reference
  implementation of the D8 settlement order (same rounding rules as D7,
  ~100–150 lines, pure functions).
- Write `simulation/vectors/export_vectors.py`: generates ≥ 50 JSON vectors
  (case shape: rounds, seats per voter, reveals, bond contributions, final
  outcome → expected per-address payouts, freezes, track updates), including:
  forced max-depth flip-flops (the M1 insolvency reproducer), VOID, unmet
  bond floors, multi-contributor appeals, failed reveals, dust-heavy amounts
  (odd primes). Commit vectors under `contracts/test/vectors/`.
- Foundry reads them with `vm.readFile` + `vm.parseJson` and replays against
  the real contract. **Exact equality required.**

### Parameter constants (working values — from the M1-calibrated sim)

`MIN_STAKE = 10 xBZZ`, `RISK_PER_SEAT = MIN_STAKE`, `EXIT_COOLDOWN = 7d`,
`ACTIVATION_DELAY = 7d`, `COMMIT_TARGET = [5, 11, 23, 47]`,
`COMMIT_TIMEOUT = 24h`, `REVEAL_WINDOW = 24h`, `MIN_REVEALS = 3`,
`MAX_WIDEN = 3`, `APPEAL_WINDOW = [4d, 3d, 3d, 3d]`, `MAX_DEPTH = 3`,
`BOND_MULTIPLIER = 2` (bond floor = 2 × pot), `FREEZE_BASE = 7d`,
`FREEZE_CAP = 4 (WAD)`, `TRACK_SAT = 60 (WAD)`, `TRACK_DECAY = 0.95 (WAD)`,
`FAILED_REVEAL_FREEZE = 1d`, `CLAIM_BOUNTY_FRAC = 1%`, `BONUS_FRAC = 10%`,
`MAX_TOPICS = 5`, `SUPERSAFE_AGE = 96h`, `SEED_LAG = 2 blocks`,
`TIMELOCK_DELAY = 7d` (working). Fee floor: `FEE_BASE`/`FEE_PER_TOPIC` are
governance-settable numerics seeded from `simulation/costs.py` defaults.

All of these are §1 *(working)* values behind the governance path (D3/M2-7) —
constants only where the spec says immutable.

---

## Part B — Work items

### M2-0: Foundry scaffold

- Install Foundry (`foundryup`), record the pinned version.
- `contracts/` forge project; install `forge-std`, `solady`; `.gitignore`
  additions (`out/`, `cache/`).
- `test/mocks/MockBZZ.sol` — mintable ERC20 with **16 decimals** (verify BZZ
  decimals; record the answer).
- Verify Gnosis Chain block gas limit; record in `contracts/GAS_BUDGETS.md`
  with the D9 table.
- One trivial test proving the toolchain runs.
- **Accept:** `forge test` green; versions + gas-limit fact recorded.

### M2-1: Staking

- `Moderator` struct per spec §2; `stake`, `activate`, `requestExit`,
  `withdraw`, `thaw`; ACTIVATION_DELAY, EXIT_COOLDOWN, MIN_STAKE floor
  (dropping below only by full exit, §3).
- Tree wiring for activate/exit/thaw per D2/D6 (tree from M2-2 may be stubbed
  as an interface until then if you prefer — or reorder M2-1/M2-2; builder's
  choice, note it).
- **Tests:** unit + fuzz for the partition invariant (§9.3: free + committed +
  frozen == tracked total, every unit in one sub-state); §9.5
  withdrawals-never-pausable (demonstrate no admin path can gate
  `requestExit`/`withdraw`); exit-below-floor rules.
- **Accept:** green incl. partition fuzz.

### M2-2: SortitionTree library

- Per D2. Include `weightOf` for tests.
- **Tests:** set/update/remove correctness (fuzz); **distribution property** —
  fixed weight set, ≥ 10k derived draws, each id's empirical frequency within
  a stated tolerance of its weight share (pick tolerance so the test is
  deterministic under the fixed seed, and say so in a comment); draw gas at
  1000 leaves recorded in the snapshot.
- **Accept:** distribution test green; gas recorded.

### M2-3: Case lifecycle (submit → DRAW → COMMIT → REVEAL → TALLY, widen/VOID)

- `submit` (both case kinds; fee ≥ minFee; ≤ MAX_TOPICS; dedup keys
  `H(content, meta, topicKey)` all registered, any-exists reverts, §9.7).
- Phase machine per spec §5.3 exactly, with `phaseDeadline`; seed discipline
  per D4 (arm/poke/re-arm); seat draw with replacement per D2; commit locking
  per D5; commit/reveal with `H(vote, salt)`; tally; widen path
  (additional seats, derived seed, ≤ MAX_WIDEN); VOID path (refund
  `fee − claimBounty`, clear dedup); outcome drawn ∝ seat counts with
  `outcomeSeed` armed only after reveals close.
- Events on every transition (the machine-facing interface, README §5).
- **Tests:** happy path; widen; VOID; non-seat-holder commit reverts; double
  commit/reveal reverts; reveal-hash mismatch reverts; timing guards; a test
  that `outcomeSnapshotBlock` is provably ≥ the reveal-close block (two-seed
  discipline, §7).
- **Accept:** lifecycle green.

### M2-4: Appeals (directional flip bonds)

- `contributeAppealBond` during APPEAL_WINDOW, depth < MAX_DEPTH; aggregate
  `bondContribs`; contributions are **capped at exactly the floor**
  (`BOND_MULTIPLIER × pot`; last contributor takes a partial fill); on floor:
  bond → pot, depth++, `appealFor = opposite(outcome)`, next round DRAW.
- **Unmet floor:** if the window closes below the floor, contributions are
  refundable (pull) after FINALIZED — spec is silent here; this is the pinned
  rule (record as delta).
- MAX_DEPTH window accepts no contributions; closes to FINALIZED.
- **Tests:** multi-contributor aggregation; exact-floor cap + partial fill;
  unmet-floor refund; self-appeal allowed and costed; depth advance; MAX_DEPTH
  close.
- **Accept:** green.

### M2-5: Settlement (`claim`)

- Implement D8's order exactly; freeze power via `FreezeMath` (seat-weighted
  mean coherent track, saturating curve §6.4, solady `expWad`); D6 freeze
  application; D5 slice returns; §6.5 track updates (port `protocol.py`
  faithfully — read it first); idempotence guard.
- **Tests:** exact-integer conservation (invariant 11) on every settlement
  test; forced flip-flop chains to MAX_DEPTH (the M1 insolvency reproducer,
  in integers); no-internal-transfer property (§9.2: no address's principal
  decreases except by its own exit); freeze-excludes-from-draws (settle a case
  freezing X, then run another case and assert X never drawn until after
  `frozenUntil` + `thaw`); failed-reveal brief freeze; `FreezeMath` unit tests
  against Python-computed reference values (≥ 10 points on the curve).
- **Accept:** conservation exact everywhere; freeze-exclusion test green.

### M2-6: Index registry

- Write at settlement only, on final APPROVE (§8.1); `uncontested` = no Reject
  reveal **ever** (an appeal alone does not clear it — encode the frivolous
  appeal case); removal APPROVE deletes by `(topicKey, caseId)` swap-and-pop
  and clears the target's dedup; REJECT/VOID clear dedup (§8.2); view
  functions for superset/supersafe (§8.3); `TopicCreated` (§8.4).
- **Tests:** approval-won-on-appeal writes (the §8.1 regression); no
  provisional write at depth-0 tally; uncontested semantics incl. frivolous
  appeal; removal of missing entry no-ops/reverts cleanly (§10); resubmit
  after REJECT succeeds (dedup lifecycle).
- **Accept:** green.

### M2-7: Governance

- Multisig + timelock over §1 numeric parameters **only**; `guidelinesHash`
  append-only versioned history (§2, invariant 9); no pause paths anywhere;
  case's pinned `guidelinesVersion` immutable (§9.6).
- **Tests:** every settable parameter enumerated and tested; timelock
  enforced; a non-listed mutation attempt has no path (compile-time by
  design — test the setters' bounds); guidelines history immutability;
  re-assert §9.5 with governance live.
- **Accept:** green.

### M2-8: Invariant + differential campaign

- Foundry **invariant tests** with a handler: random actors stake, submit,
  commit, reveal, appeal, claim, exit, thaw across overlapping cases.
  Invariants asserted after every call sequence: §9.1 conservation, §9.2
  no-internal-transfer, §9.3 partition, §9.4 freeze-forward, §9.7 dedup,
  §9.11 per-case funds conservation. Configure runs/depth meaningfully
  (≥ 256 runs, depth ≥ 64) and note the config.
- §9.10 single-stake-benefit as a **statistical fuzz test** (first-round
  outcome tracks stake share across many seeded runs — port
  `test_first_round_outcome_tracks_stake_share`'s intent).
- Differential vectors per D10: integer reference + exporter + ≥ 50 committed
  vectors + Foundry replay, exact equality.
- **Accept:** invariant campaign green at stated config; all vectors match.

### M2-9: Gas-bound suite

- `forge snapshot` committed; explicit gas assertions for the D9 table; the
  §10 checklist: worst-case `claim()` (MAX_DEPTH, 86 reveals, 5 topics) under
  the hard ceiling in **one transaction**; widen cannot loop unboundedly;
  duplicate submission reverts; over-MAX_TOPICS reverts; removal edge cases.
- Record actuals vs budgets in `contracts/GAS_BUDGETS.md`.
- **Accept:** snapshot committed; hard-ceiling assertion green.

### M2-10: Spec deltas + docs closeout

- Append an "**M2 implementation deltas**" section to
  `specs/state-machine.md` (and/or inline `(M2)` notes): blockhash
  realization + re-arm (D4); explicit `activate`/`thaw` pokes (D6);
  `RISK_PER_SEAT` new §1 param (D5); unmet-floor refund + exact-floor cap
  (M2-4); dust-to-claimant rounding (D7); failed-reveal slice handling. Each:
  what changed, why, threat-model impact.
- `contracts/README.md`: build/test instructions, module map, dependency
  licenses (Kleros-design attribution), gas table.
- Root `README.md` §8: mark M2 status.
- `contracts/DEVIATIONS.md`: final sweep — empty sections deleted, everything
  dated.
- **Accept:** full suite green; docs match the code; push.

---

## Part C — Boundaries

- **In scope:** everything above. **Out of scope:** deployment scripts beyond
  a local anvil sanity script, Chiado deployment (M4), any client/indexer work
  (M3), VDF/randomness-oracle upgrades (documented path only), re-calibrating
  M1 parameters.
- Push with `git push -u origin claude/determined-curie-nkf71s` (retry w/
  backoff on network failure). Do not open a PR until asked.
- If context is lost mid-execution: re-read this file, `specs/state-machine.md`,
  and `contracts/DEVIATIONS.md`; the task list mirrors M2-0…M2-10.
