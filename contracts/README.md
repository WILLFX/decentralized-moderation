# Moderation contracts

Solidity implementation of **`specs/protocol.md`**, which is normative.

| File | Runtime | Role |
|---|---:|---|
| `src/Moderation.sol` | 13,451 B | the case state machine — §3 through §8 |
| `src/StakeRegistry.sol` | 2,778 B | stake custody and frozen time — §2 |
| `src/IndexRegistry.sol` | 2,899 B | the topic → entry index — §7 |

`script/Deploy.s.sol` deploys and links all three. **`verify()` is the
deliverable there, not `run()`**: both registries hold a one-shot `moderation`
address and `Moderation` holds theirs as immutables, so an unlinked stack
deploys, accepts submissions, and fails at the *first commit* — long after anyone
is watching. Every link is asserted in both directions, and a test proves
`verify()` actually catches an unlinked stack rather than trusting it to.

---

## Tests

80 tests across nine suites.

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

Two of those carry more weight than their size suggests.

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

`specs/protocol.md` §11 lists what has no value yet: the estimator, the cost of
non-reveal, per-committee minimums, what "anonymous" means, and identity
rotation — the sharpest, since a frozen moderator can leave the stake idle and
stake a fresh address. `StakeRegistry`'s closing comment states that one where
someone reading the contract will hit it.

Two deliberate deviations from the spec are marked in the code rather than
hidden: eligibility bits are pinned from the *staked* count rather than the
non-frozen count §3 names, because a freeze expires on a clock with no
transaction to observe; and the estimator is `A/N`, isolated in `_estimator` so
the alternative is a one-line change.
