# Moderation contracts

Solidity implementation of **`specs/protocol.md`**, which is normative.

| File | Runtime (shipped, `via_ir`) | legacy | Role |
|---|---:|---:|---|
| `src/Moderation.sol` | 11,544 B | 13,550 B | the case state machine — §3 through §8 |
| `src/StakeRegistry.sol` | 2,396 B | 2,778 B | stake custody and frozen time — §2 |
| `src/IndexRegistry.sol` | 2,504 B | 2,899 B | the topic → entry index — §7 |

Both columns clear EIP-170's 24,576 B with wide margin, so `via_ir` is a choice
rather than a necessity — it stays on because the shipped profile and the test
profile should be the same bytecode. (It was once a necessity: the contract these
replaced was 25,986 B legacy and undeployable.)

`script/Deploy.s.sol` deploys and links all three. **`verify()` is the
deliverable there, not `run()`**: both registries hold a one-shot `moderation`
address and `Moderation` holds theirs as immutables, so an unlinked stack
deploys, accepts submissions, and fails at the *first commit* — long after anyone
is watching. Every link is asserted in both directions, and a test proves
`verify()` actually catches an unlinked stack rather than trusting it to.

---

## Tests

91 tests across eleven suites.

| suite | what it is for |
|---|---|
| `Lifecycle.t.sol` | one case end to end, and the staging properties |
| `ChallengeRound.t.sol` | the second round, end to end |
| `Removal.t.sol` | §8 — Approve means remove |
| `Guards.t.sol` | the guards, and the state a reader is shown |
| `Stakes.t.sol` | §2 — additive freezes, and the stake never taken |
| `Index.t.sol` | §7 — two facts recorded, and the swap-remove |
| `Draw.t.sol` | §5 — the ticket rule, and vector emission |
| `Integration.t.sol` | the three real contracts, no mocks |
| `Invariant.t.sol` | nine properties under fuzzed orderings |
| `ThreeVote.t.sol` | what §4.4's floor bought, and what it did not |
| `RevealFloor.t.sol` | §4.4 — the floor, and its two asymmetric failure paths |

Three of those carry more weight than their size suggests.

**`Integration.t.sol` uses no mocks.** Every other suite substitutes a mock
registry or index, and `Moderation` calls both through interfaces declared
locally — so a signature drifting from the real contract compiles and reverts at
runtime. It also runs at 64 staked moderators rather than 8, which is the only
place `eligBits` is non-zero and the narrowing hash of §3 is exercised at all.

**`Invariant.t.sol` guards itself against vacuity.** A handler whose calls all
revert satisfies every invariant by doing nothing, and three attempts at this
suite passed that way before the coverage check caught them. It cannot be an
`invariant_*` function (Foundry evaluates those once before fuzzing, when nothing
has happened) nor `afterInvariant` (Foundry calls that with handler state reset,
so every counter reads zero, and a `view` one silently aborts the run). It is an
ordinary test that drives the handler by hand and proves each interesting state
is reachable through it.

**`ThreeVote.t.sol` is a pair of tests that disagree with each other on purpose.**
It used to be a tripwire pinning an open gap — three identities that were the only
committers took a case 40 times out of 40. §4.4's floor landed and the test changed,
which is what it was there for. What replaced it says both halves: the old attack is
dead at even the weakest floor, because it needed committee B to hold nobody; and a
clique fielding `k` revealing identities in *each* committee still takes a unanimous
case with certainty, because `A/N` is still `A/N`. **The floor priced capture; it did
not remove it.** If anyone later reads it as having removed it, the second test is
the correction.

## The draw differential

`Draw.t.sol` constrains the *rate* — that the outcome tracks `3a² − 2a³`. It says
nothing about the ticket derivation, and a domain-separation mistake keeps `u`
uniform, keeps the rate exactly right, passes every statistical test, and
silently makes two draws identical.

So `simulation/check_draw_vectors.py` re-derives every `u[i]` from a pure-Python
keccak that refuses to load unless it reproduces published KATs. 48 swept vectors
agree. It also **sabotages its own derivation** — dropping the round from the
preimage — and fails loudly if the comparison does not notice, because a
differential that agrees is only evidence if it would have disagreed.

```
cd contracts && forge test --match-test test_emitDrawVectors
python3 simulation/check_draw_vectors.py
```

## Mutation testing

```
python3 tools/mutate.py --all
```

Three outcomes, **two** scored:

| | |
|---|---|
| `KILLED` | compiles, a test fails — the suite caught it |
| `SURVIVED` | compiles, everything passes — a hole |
| `INVALID` | does not compile — proves nothing, **never scored** |

An earlier generation of harnesses here counted INVALID as killed, which inflates
the rate with mutants no test could have caught. The rate is
`killed / (killed + survived)` and INVALID is printed beside it.

Latest full sweep — 240 mutants, no sampling:

| | killed | survived | INVALID | rate |
|---|---:|---:|---:|---:|
| `Moderation` | 147 | 36 | 4 | **80.3%** |
| `IndexRegistry` | 34 | 2 | 1 | **94.4%** |
| `StakeRegistry` | 15 | 1 | 0 | **93.8%** |

**The remaining survivors are not a to-do list.** Most are equivalent mutants —
`x > t ? x : t` against `>=`, `n > limit` against `>=` when they are equal,
`offset >= length` against `>` when both yield an empty page — which cannot be
killed because they do not change behaviour. The rest are event arguments and one
struct field (`committee` on a challenge record) that nothing reads. Writing
assertions for those would raise the number while constraining nothing.

Campaigns mutate a **scratch copy** of the project, never the working tree. That
is not tidiness: a `git add -A` landing mid-campaign once committed two live
mutants to `main`, one of them a `vt.settled = false` that makes a vote claimable
repeatedly. They also compile through the legacy pipeline, which is 4.6s against
30s, because a campaign measures the test suite rather than the deployed
bytecode — while the shipped profile and ordinary `forge test` keep `via_ir`, so
what ships is still what is tested.

## Open

`specs/protocol.md` §11 is the list. Two things about it are worth stating here.

**`minRevealsPerCommittee = 3` is conditional, not settled.** It is a constructor
argument precisely so a testnet can move it. `simulation/FINDINGS-floor-price.md`
prices it at 0.9% of cases unresolvable given 20% turnout and a 75% reveal rate —
and at 28% given 10% turnout. Below roughly 10% turnout no value both stops a small
clique and leaves ordinary cases resolvable. Turnout is unmeasured.

**Identity rotation is the sharpest open item and nothing here touches it.** A
frozen moderator can leave the frozen stake idle and stake a fresh address, so
escaping a freeze costs one stake tied up for the freeze duration — exactly what
serving it costs. `StakeRegistry`'s closing comment states that where someone
reading the contract will hit it.

Two deliberate deviations from the spec are marked in the code rather than hidden:
eligibility bits are pinned from the *staked* count rather than the non-frozen count
§3 names, because a freeze expires on a clock with no transaction to observe; and a
moderator votes once per case rather than once per committee, which §3 does not
decide either way.
