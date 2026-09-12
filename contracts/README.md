# Moderation contracts

**These contracts implement a different protocol from `specs/protocol.md`.**

They are a complete, tested implementation — 266 tests, stateful invariants,
a two-implementation differential on the draw, mutation campaigns — of a design
that has since been replaced. This file is the audit of how far they are from the
one that is now normative.

| File | Runtime | Verdict against the spec |
|---|---|---|
| `src/Moderation.sol` | 21,786 B | **Rewrite.** §A |
| `src/StakeRegistry.sol` | 10,338 B | **Rewrite.** §B |
| `src/IndexRegistry.sol` | 4,285 B | Partly reusable. §C |
| `src/RulesetGovernor.sol` | 6,386 B | Unspecified — see spec §10.3 |

The audit below is read from the code against the spec, not from anyone's list of
objections.

---

## §A `Moderation.sol` — the case state cannot represent the design

Not "needs changes." The storage layout cannot hold the lifecycle in spec §4.

### Hard blocks

**`uint8 round; // 0 or 1`.** The contract hard-codes exactly two rounds. Line 846
is the only increment (`c.round = 1`) and line 804 treats round 1 as terminal.
Spec §4.2 allows **two challenges**, so three rounds. Not a constant to bump —
the round is a field with two meanings and every guard reads it as a boolean.

**One `eligSeedBlock` per round.** Spec §4.1 needs **two committees per round**,
the second seeded from randomness that does not exist until the first committee's
commit phase has closed. There is one seed field and eligibility mixes `c.round`
into the hash, so a second committee inside a round is not addressable.

**`commitsThisRound` / `revealsThisRound` are per round, not per committee.**
Spec §11 requires a minimum per committee, explicitly because 40 commits in
committee 1 and one in committee 2 is not two committees. That distinction cannot
be computed from this state.

**The phase machine has the wrong shape.**

```
implemented   COMMIT → REVEAL → TALLY → DRAW → FINALIZED
spec §4       C1 COMMIT → C2 COMMIT → JOINT REVEAL → DRAW
                        → CHALLENGE WINDOW → (up to 2 more pairs) → FINALIZED
```

`TALLY` exists only to publish the plurality, which spec §4.2 replaces with a
published preliminary outcome. There is no phase for a second committee
committing.

### Fields serving features the design does not have

Of 32 fields in `Case`, **18 exist for mechanisms the spec no longer contains**:

`terminal`, `unresolvedReason` (the UNRESOLVED rows) · `paramsVersion`,
`guidelinesVersion` (governance pinning) · `plurality` (the withheld verdict) ·
`challengeReserve` (bonds) · `drawBounty`, `claimBounty` (bounties) ·
`commitBlocks`, `revealBlocks`, `challengeBlocks` (fixed windows, replaced by a
clock anchored to the third commit) · `reveals0` (`SUPER_SAFE`) · `challenger`
(a bonded role; in the spec a challenger is a voter) · `outcomeEntropy`,
`outcomeSeedBlock` (one draw reused; the spec draws fresh each round) ·
`claimKey`, `actionType` (reservation machinery).

### Fields the design needs and the struct lacks

A second committee seed per round · per-committee commit and reveal counts · a
challenge counter over `{0,1,2}` · whether all three tickets were Approve
(spec §7) · whether the entry is anonymous (spec §7).

**Conclusion.** Ten of 32 fields survive roughly as they are. More than half serve
deleted mechanisms, five are missing, and three of the survivors need splitting.
Editing this into shape is more work than writing it, and leaves dead state behind.

## §B `StakeRegistry.sol` — the same, for the same reason

The `Moderator` record is:

```
stake · bond · openVoteCount · openChallenges · liabilities
      · maturesAt · exitRequestedAt · track
```

Spec §2 needs **`stake`** and **a total frozen time**. That is all.

- `bond`, `openVoteCount`, `openChallenges`, `liabilities` are the bond system.
  The spec has no bond. And this is the direct answer to "why did you reintroduce
  non-infinite concurrency" — we did not add a limit, we added **a second capital
  system whose solvency check is a concurrency limit as a side effect.**
- `track` is never read to weight or scale anything. Storage with no consumer.
- `maturesAt`, `exitRequestedAt` are unspecified (spec §10.3).
- **There is no freeze.** `FreezeMath` was deleted when penalties became balance
  debits. The spec's only penalty does not exist in the code.

Roughly half the contract is `createVoteClaim` / `createChallengeClaim` /
`debit` / `discharge` / `dischargeCondemned` / `mayCommit` / `mayChallenge` and
the claim ledger behind them — all of it the bond system.

## §C `IndexRegistry.sol` — partly reusable

The entry model (claim key, topic key, status, counts) survives. What does not:

- `strict` and the open-question counter existed to serve `SUPER_SAFE`, which
  spec §7 drops. Likely orphaned.
- Spec §7 wants two facts recorded per entry — anonymity, and whether all three
  tickets were Approve. Neither field exists.

## §D What is worth keeping regardless of the rewrite

Not everything here is tied to the old design.

- **The draw.** `decideAt` and its cross-checks — the Foundry property tests, the
  Python differential, the KAT-gated keccak — test the ticket rule itself, which
  spec §5 keeps. The estimator fed to it is open (spec §11); the machinery around
  it is not wasted.
- **The test harness shape.** `SystemHandler`, the invariant suite and the
  mutation campaigns are built against behaviour, not storage layout, and most of
  that structure transfers.
- **`script/Deploy.s.sol`'s `verify()`.** Every link in a four-contract stack
  fails silently and late; the deployment check is worth keeping whatever the
  contracts become.

## §E Status of the numbers in this file

Sizes and the 266-test count are real and current. **They measure the old
protocol.** Nothing here should be read as evidence that the spec's design works,
because none of it implements the spec's design.

`DEVIATIONS.md` documents deviations from `specs/state-machine.md`, a document
that is no longer in the repository. It is archaeology and describes neither the
current code nor the current spec.
