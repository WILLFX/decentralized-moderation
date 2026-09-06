# M2.7 Work Order — `Moderation.sol`

**Base:** `main` @ `bac361c`.
**Branch:** **`claude/determined-curie-nkf71s`** — commit and push there. Do **not**
create a new branch. The previous order omitted this line and a new branch was
created; that was the omission's fault, not the implementer's, and it is fixed here.
**Normative source:** `specs/state-machine-v3.md` @ `bac361c`. Where
`specs/design-v3.md` disagrees, the state machine wins.

**Scope:** one contract, `contracts/src/v3/Moderation.sol`, and its test suite. This
is the contract that holds the case state machine — §4 end to end, plus the parts of
§5, §7 and §8 that a case reaches.

---

## 0. What already exists, and what you must not touch

`contracts/src/v3/StakeRegistry.sol` is **done, tested and merged** (`b4dcaf8`;
9,058 B runtime, 44 tests, 25 mutations applied and 25 killed). It is a **dependency
of this work, not part of it.**

**Do not modify `StakeRegistry.sol` or its tests.** If you believe it has a defect,
stop and report it — do not fix it inside this order. A change there invalidates its
mutation run and its audit standing, and this order has no budget to re-establish
either.

`Moderation` is a **logic contract** in the registry's sense: governance grants it
`MAY_CREATE | MAY_DISCHARGE` and it drives moderator accounting through the registry
rather than holding it. §2.4 is the boundary and the registry is the authority on
solvency; `Moderation` never reads or writes a moderator's bond directly.

---

## 1. The spec changed under you — read these three first

`StakeRegistry` was written against §2. §4 has moved since, in ways that change what
you would otherwise write. **Read §4.8b, §4.8c and §4.5's closing paragraphs before
anything else.**

### 1.1 There is no quorum gate — `MIN_COMMITS` is gone (§4.8b)

`MIN_COMMITS` was removed as a parameter, not lowered. It is struck from §1's table.

- `COMMIT (r=0) → REVEAL` requires **`commitsThisRound ≥ 1`**.
- `COMMIT (r=0) → UNRESOLVED(NO_TURNOUT)` requires **`commitsThisRound == 0`**.

`NO_TURNOUT` now means an **empty** round, not a thin one. If you find yourself
writing a named constant for a minimum commit count, you have misread the section.

### 1.2 The draw must **not** guard `N > 0` (§4.5)

This is the one place the spec previously instructed you to write a bug, and it was
corrected at `bac361c`. The old text asked for an explicit `N > 0` guard against
division by zero. **The draw does not divide:**

- `â`'s denominator is `N + 2`, at least 2 at every tally including the empty one;
- the ticket comparison is cross-multiplied — `u·(N+2) < (A+1)·2^128`.

`N ≥ 1` is a **structural fact** — §4.3 routes `pooled == 0` to `NO_REVEALS` and the
pooled tally never decreases, so `DRAW` is unreachable with an empty tally. Adding
the guard converts an impossible state into a permanently stuck one, because a
revert inside `DRAW` strands the case forever. **Do not add it.**

### 1.3 `RETRY_COOLDOWN` is no longer a deferrable parameter (§4.8c)

Removing the gate cheapened the `NO_REVEALS` censorship path from sixteen
`REVEAL_BOND`s to one. It is still **open** and you must not pick a value (see §7),
but note in `DEVIATIONS.md` that the contract's behaviour at small registries
depends on it in a way it did not before.

---

## 2. What to build

### 2.1 Storage

§4.1's `Case` struct, verbatim in field set and width. It is written to fit; do not
widen a field for convenience without recording it in `DEVIATIONS.md`.

Two fields exist only to be read back later and are easy to drop:

- **`outcomeEntropy`** — `blockhash(outcomeSeedBlock)`, stored at the draw. The
  three uniforms are **not** stored; they re-derive from this word forever, which is
  what makes §8.5's re-review return an identical verdict after `blockhash` has
  expired. One slot, not three.
- **`unanimousDraw`** — whether all three tickets fell the same way. §8.3 reads it.
  Nothing else reads `u` back.

`phaseDeadline`, `eligSeedBlock`, `outcomeSeedBlock` are **block heights**.
`finalizedAt` is a **timestamp and is never compared** — it is a record (§0).

### 2.2 Transitions

§4.3's table is the specification of this contract. Implement every row, and note:

- **Every transition is permissionless.** No row has a privileged caller.
- **Guards must be pairwise disjoint (I18).** A state reachable by two rows with
  different effects is a defect, not a choice. Test this directly.
- **Every field must be written or provably preserved by every transition (I19).**
  `revealsThisRound` is the field this rule exists for: `TALLY → COMMIT` resets it,
  `TALLY → DRAW` does not.
- **`terminal` is written by every row reaching a terminal state and by no other.**
- **The index entry is written at the transition into a terminal**, in
  `O(MAX_TOPICS)` — never at settlement (§8.1, I15). This holds for all three
  `UNRESOLVED` reasons as well as `FINALIZED`.

The four non-phase writers in the second table (`commit`, `reveal`, `challenge`,
and the registry passthroughs) are also quantified over by I18–I19.

### 2.3 The draw (§4.5)

```
u[i] = uint128( H(OUTCOME_DOMAIN, chainId, contract, caseId, i,
                  blockhash(outcomeSeedBlock)) )        i = 0,1,2

N  = pooledApprove + pooledReject
â  = (pooledApprove + 1) / (N + 2)                      -- NOT pooledApprove / N
ticket[i] = ( u[i] · (N + 2)  <  (pooledApprove + 1) · 2^128 )
verdict   = (ticket[0] + ticket[1] + ticket[2] ≥ 2) ? Approve : Reject
```

**Two forms that are wrong and will pass a naive test:**

- `A/N` instead of `â`. At a unanimous tally `f(1) = 1` and one revealed vote
  decides the case with certainty. I12 is false under it.
- `u mod (N+2) < approve+1` instead of the cross-multiplied comparison. Both are
  uniform and both give `f(â)`; only the cross-multiplied form is **monotone in
  `â`**, and monotonicity is the entire reason a challenge cannot buy a re-roll
  (I22). The modulo form reshuffles on every change of `N`, so one added vote acts
  as a fresh draw.

Both operands fit `uint256` without care: `u` is 128 bits, `N+2` is at most 32.

### 2.4 Payment (§5.3)

```
reveals1  = (pooledApprove + pooledReject) − reveals0
activated = min( challengeReserve , floor(pot · reveals1 / reveals0) )
P         = pot + activated
W         = votes matching `verdict`, from either round
share     = floor(P / W)
remainder = P − share · W                 -> maintenance reserve, never a moderator
challengeReserve − activated              -> refunded to the submitter
```

**`reveals1` is derived, never stored, and §5.3 says why at length.** The only
stored binding available is `revealsThisRound`, and on the unchallenged path that
still holds round 0's count — so `activated` becomes the *entire* reserve on cases
nobody challenged, and the submitter's refund is zero on most cases. Written as
`(pooledApprove + pooledReject) − reveals0` it is zero on that path **by
arithmetic**. Do not introduce a `reveals1` field.

`pot` **never grows.** The reserve is added at settlement, not held in `pot`.

### 2.5 Settlement (§5.5)

Pulled **per moderator**, via `claim(c, m)`: permissionless, self-funded,
order-independent, and it may never complete. **There is no case-level `SETTLED`
state** — a state the machine can be permanently unable to enter is not a state.
"Settled" is a fact about a `(moderator, case)` pair and it is the registry claim
record's absence.

Settlement **never touches the index** (§8.1, I15).

Fire exactly the obligations whose requirement the terminal meets (§4.8's table,
I30) — not three groups:

```
obligation            fires iff                          NT  NR  NRand  A/R
CHALLENGE_BOND        a challenge was registered          -   -    y     y
non-reveal debit      a reveal phase OPENED               -   y    y     y
incoherence debit     a settled side exists               -   -    y     y
claim key held        a settled side exists               -   -    y     y
```

---

## 3. The registry boundary

`Moderation` calls, and must call nothing else on the registry:

| purpose | call |
|---|---|
| may this identity commit? | `mayCommit(a, lambda)` |
| may this identity challenge? | `mayChallenge(a, challengeBond)` |
| open a vote obligation | `createVoteClaim(a, caseId, lambda)` |
| open a challenge obligation | `createChallengeClaim(a, caseId, challengeBond)` |
| take a penalty | `debit(a, caseId, kind, amount)` |
| close an obligation | `discharge(a, caseId, kind)` |
| pay | `reward(a, amount)` |
| credit reputation | `recordParticipation(a, caseId, coherentUnits, decayFactor)` |

`kind` is `KIND_VOTE = 1` or `KIND_CHALLENGE = 2`.

**Custody (I32).** A claim is keyed `(moderator, caseId, kind)` and carries the
`logic` that created it. Only that `logic` may debit or discharge it, and a debit may
not exceed the recorded amount. `Moderation` must therefore discharge **every** claim
it creates, on **every** terminal — including the `UNRESOLVED` rows. A claim left
open is a moderator's liability left standing forever.

**Condemnation (§2.4).** If governance condemns `Moderation`, `dischargeCondemned`
becomes available to release moderators without it. Nothing in this contract needs
to handle that; do not add a path for it.

---

## 4. Traps

Ordered by how likely I think each is to be got wrong.

1. **`commit` consumes the one-vote-per-claim allowance, not `reveal`** (§3.4, I3).
   The check is "has not committed to `c` **in any round**".
2. **No phase closes early** (§4.4). Not when every committer has revealed, not when
   the challenge window is quiet. Early close on "everyone revealed" hands the last
   actor a free binary choice over outcome seeds. What *is* permitted and should be
   implemented: **permissionless immediate finalization** once the outcome block
   exists.
3. **`outcomeSeedBlock` is armed at submission from the scheduled heights** (§7.2),
   and includes the round-1 windows whether or not round 1 runs. On the unchallenged
   path, `TALLY → DRAW` enters a waiting state ~40 minutes before anything is
   enabled.
4. **Seed guards are block-height comparisons, never observations of the returned
   hash** (I29). "The seed is unavailable" is true in two different states and
   distinguishes neither.
5. **`challenge()` registers only.** No transfer, no phase change, no seed armed, no
   deadline moved. The bond is *covered*, not escrowed. A second call reverts (I17).
6. **`TALLY → COMMIT` resets `commitsThisRound` and `revealsThisRound`** and arms the
   round-1 **eligibility** seed only — there is no second outcome seed (§7.1).
7. **Round 1 has no quorum gate and needs none** (§4.9). An empty round 1 leaves the
   pooled tally identical, so the draw sees what it would have seen. Adding a gate
   here recreates the F8 defect: a rejected submitter challenges, stays quiet, and
   takes the free retry.
8. **The plurality is a total function including ties** — `A > R` is Approve,
   everything else Reject (§4.2). It decides who *owes*, never who wins.
9. **`paramsVersion` is pinned at submission and every debit is computed from it**
   (I27), never from live governance values.
10. **The three windows are converted to block counts once, at submission**, from
    `BLOCK_TIME(c)`. That is the only wall-clock→block conversion in the system (§0).

---

## 5. Not in scope

Do not implement, and do not leave hooks for:

- **Reliability-weighted aggregation.** Measured in
  `simulation/v3/FINDINGS-weighted.md`; deliberately **not** in the spec, because the
  sign of its value depends on two unmeasured quantities.
- **Adaptive / sequential stopping.** `FINDINGS-adaptive.md` §8 declines it.
- **Staged committees.** Not adopted.
- **Any parameter value left open by §1 or §10** — see below.
- Changes to `StakeRegistry.sol`.

---

## 6. Open parameters — do not invent values

`BOND_MIN`, `GAS_ALLOWANCE`, `CHALLENGE_BOND`, `MATURATION`, `SUPER_QUORUM`,
`RETRY_COOLDOWN` and `DRAW_BOUNTY`'s sizing are **open** (§1, §10).

Take them as **constructor or governance parameters**. Do not pick a number and do
not encode one as a default. Where a test needs a value, put it in the test and say
in `DEVIATIONS.md` that it is a test fixture and not a proposal.

`BLOCK_TIME` carries one hard bound and it is not open:
`commitBlocks ≤ SEED_LAG + BLOCKHASH_HORIZON = 258`, so `BLOCK_TIME ≥ 4.651 s`, with
18 blocks of margin at 5 s (§10). Enforce the bound; do not enforce a value.

---

## 7. Acceptance

The same bar `StakeRegistry` met, because that bar is what makes this reviewable:

1. **`forge test` green**, with tests that name the invariant or section they check.
2. **I18 tested directly** — a case cannot satisfy two transition guards at once.
3. **I19 tested directly** — after each transition, every §4.1 field is written or
   demonstrably unchanged.
4. **Mutation testing.** Apply mutations to the verdict arithmetic, the guards, and
   the settlement obligations table; report applied and killed. `StakeRegistry` was
   25/25 with 0 survivors. A survivor is a missing test, not an acceptable result —
   report it rather than tuning the mutation set.
5. **EIP-170.** Report runtime size against 24,576 B, with the solc invocation used:
   `--via-ir --optimize --optimize-runs 200 --evm-version cancun`. If `Moderation`
   does not fit, **stop and report** — do not split it on your own judgement, because
   where the seam goes is an architectural decision and there are already four
   contracts in the standing constraint.
6. **Gas.** Add measured figures to `GAS_BUDGETS.md` for `submit`, `commit`,
   `reveal`, each phase close, the draw, and `claim`.
7. **`DEVIATIONS.md`.** One entry per place the implementation departs from,
   refines, or pins something §4 left open — what, why, threat-model impact.

**Report findings rather than fixing them.** The last two work orders each produced
spec defects that reading had not found (`844bf52` — "two findings the
implementation produced that reading did not"). That is the most valuable thing this
exercise yields. If §4 contradicts itself, is unimplementable, or is silent where you
need an answer, **write it down and ask** — do not resolve it in Solidity and move
on.

---

## 8. Deliverables

- `contracts/src/v3/Moderation.sol`
- `contracts/test/v3/Moderation.t.sol`
- `GAS_BUDGETS.md` and `DEVIATIONS.md` updated
- a report covering: tests, mutation results, runtime size, and **every question §4
  could not answer**

on branch **`claude/determined-curie-nkf71s`**.
