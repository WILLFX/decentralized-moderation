# Moderation contracts

Solidity implementation of [`specs/protocol.md`](../specs/protocol.md), which is
normative.

| File | Runtime (shipped, `via_ir`) | legacy | Role |
|---|---:|---:|---|
| `src/Moderation.sol` | 11,753 B | 13,730 B | the case state machine — §3 through §8 |
| `src/StakeRegistry.sol` | 2,396 B | 2,778 B | stake custody and frozen time — §2 |
| `src/IndexRegistry.sol` | 2,504 B | 2,899 B | the topic → entry index — §7 |

## Compiler pipelines

Both columns clear EIP-170's 24,576 B limit with wide margin, so `via_ir` is not
required for size. It remains enabled so that the shipped profile and the test profile
produce the same bytecode.

The legacy pipeline must nonetheless keep working, because `tools/mutate.py` compiles
through it for speed: 4.6 s per mutant against 30 s. A contract that only `via_ir` can
compile would cause every mutant to be classified INVALID, and INVALID is never
scored, so a campaign would report a clean sweep of nothing. `forge build` under
`FOUNDRY_VIA_IR=false` is the check for that condition.

`Moderation`'s constructor takes a `Config` struct for this reason among others.
Thirteen positional arguments overflow the stack during ABI decoding on the legacy
pipeline ("Variable dataEnd is 1 slot too deep"); a `memory` struct occupies one slot.

## Deployment

`script/Deploy.s.sol` deploys and links all three contracts. `verify()` is the
significant entry point rather than `run()`: both registries hold a one-shot
`moderation` address and `Moderation` holds theirs as immutables, so an unlinked stack
deploys successfully, accepts submissions, and fails at the first commit. Every link
is asserted in both directions, and a test confirms that `verify()` detects an
unlinked stack.

The guidelines are pinned rather than governed. `Moderation` carries
`guidelinesVersion` and `guidelinesHash` as immutables, so every case in a deployment
is judged under one text by construction, and `Deploy` rejects a stack whose hash is
not the keccak-256 of `MODERATION_GUIDELINES.md`. The script is the only place that
check can be made, since the contract has no filesystem access. An immutable binding
prevents any party from altering the meaning of an open case; the cost is that a
guidelines revision requires a new deployment.

---

## Tests

123 tests across thirteen suites.

| suite | scope |
|---|---|
| `Lifecycle.t.sol` | one case end to end, and the staging properties |
| `ChallengeRound.t.sol` | the second round, end to end |
| `Removal.t.sol` | §8 — Approve means remove |
| `Guards.t.sol` | the guards, and the state a reader is shown |
| `Stakes.t.sol` | §2 — additive freezes, and the stake never taken |
| `Index.t.sol` | §7 — the two recorded facts, and the swap-remove |
| `Draw.t.sol` | §5 — the ticket rule, and vector emission |
| `Integration.t.sol` | the three real contracts, no mocks |
| `Invariant.t.sol` | nine properties under fuzzed orderings |
| `ThreeVote.t.sol` | the cost of capture before and after §4.4's threshold |
| `RevealFloor.t.sol` | §4.4 — the threshold and its two failure paths |
| `Settlement.t.sol` | settlement safety, actor guards, and stated boundaries |
| `Eligibility.t.sol` | §3 — the threshold, the seed window, and the vector emitters |

Four of these require explanation.

`Integration.t.sol` uses no mocks. Every other suite substitutes a mock registry or
index, and `Moderation` calls both through locally declared interfaces, so a signature
that drifts from the real contract compiles and fails only at runtime. It also runs at
64 staked moderators rather than 8, which is the only configuration where `eligBits`
is non-zero and §3's narrowing hash executes.

`Invariant.t.sol` guards against vacuity. A handler whose calls all revert satisfies
every invariant by doing nothing. The coverage check cannot be an `invariant_*`
function, since Foundry evaluates those once before fuzzing begins, nor
`afterInvariant`, which Foundry calls with handler state reset so that every counter
reads zero — and a `view` implementation of it aborts the run silently. It is
therefore an ordinary test that drives the handler directly and confirms each state of
interest is reachable.

`ThreeVote.t.sol` contains two tests that assert opposing outcomes, which is
deliberate. The first confirms that the original three-identity capture no longer
succeeds: it required committee B to hold nobody, and any non-zero threshold prevents
it. The second confirms that a clique fielding `MIN_REVEALS` revealing identities in
each committee still takes a unanimous case with certainty, because the estimator
remains the raw share. The threshold changed the cost of capture, not its
possibility.

`Settlement.t.sol` covers classes of defect that the rest of the suite left open, each
identified by mutation testing and listed under [Mutation testing](#mutation-testing)
below.

## Differentials

Both differentials exist because a check on an aggregate is blind to which inputs
produced it.

**The draw.** `Draw.t.sol` constrains the rate — that outcomes track `3a² − 2a³`. It
says nothing about the ticket derivation. A domain-separation error keeps `u` uniform,
keeps the rate correct, passes every statistical test, and makes two distinct draws
identical. `simulation/check_draw_vectors.py` re-derives every `u[i]` in Python; 48
vectors agree.

**Eligibility.** `Integration.t.sol` establishes that eligibility narrows to roughly
half at 64 staked, which constrains the count alone. Inverting the predicate —
`h >> (256 - eligBits) == 0` to `!= 0` — produces a different set of the same size, so
it passes every count-based assertion; every test commits whichever identities are
eligible rather than a set fixed in advance.
`simulation/check_eligibility_vectors.py` therefore re-derives the predicate identity
by identity: 128 vectors from both committees of a real case, and 512 from a planted
sweep across bit widths 1–4, since a real registry pins `eligBits` at 1 for every size
from 64 to 127 and the shift would otherwise be compared at a single width. It also
re-derives the threshold from the registry size, and requires the two committees to be
distinct draws.

Each Python implementation loads a keccak that refuses to run unless it reproduces
published KATs, and each deliberately breaks its own derivation — the draw omits the
round from the preimage, eligibility omits the committee — failing if the comparison
does not detect the change. Agreement is evidence only if disagreement were possible.
Each also rejects vacuous input: the eligibility checker refuses vectors emitted at
`eligBits == 0`, where the contract short-circuits, and refuses any width whose
eligible set is uniform, since an all-false set cannot distinguish the predicate from
a constant.

```
cd contracts && forge test --match-test "test_emit.*Vectors"
python3 simulation/check_draw_vectors.py
python3 simulation/check_eligibility_vectors.py
```

Both are Python scripts, so neither `forge test` nor a mutation campaign runs them. A
mutant that changes the draw or the eligibility hash also regenerates the vectors, so
the Python side agrees with the mutant and the campaign records a survivor. The
differentials are evidence about the contracts but contribute nothing to the mutation
score, and any property that must appear in that score requires an assertion in
Solidity. `test_thePhaseDerivedCommitteeMatchesTheExplicitOne` serves that purpose for
the committee number.

## Mutation testing

```
python3 tools/mutate.py --all
```

Three outcomes, of which two are scored:

| | |
|---|---|
| `KILLED` | compiles, a test fails — the suite detected it |
| `SURVIVED` | compiles, all tests pass — a gap in coverage |
| `INVALID` | does not compile — no information either way, never scored |

Counting INVALID as killed inflates the rate with mutants no test could detect. The
rate is `killed / (killed + survived)`, and INVALID is reported alongside it.

Campaigns mutate a scratch copy of the project rather than the working tree, so that a
concurrent commit cannot capture a live mutant. They compile through the legacy
pipeline, because a campaign measures the test suite rather than the deployed
bytecode; the shipped profile and ordinary `forge test` retain `via_ir`.

Latest full sweep — 243 mutants, no sampling:

| | killed | survived | INVALID | rate |
|---|---:|---:|---:|---:|
| `Moderation` | 180 | 4 | 6 | 97.8% |
| `IndexRegistry` | 34 | 2 | 1 | 94.4% |
| `StakeRegistry` | 15 | 1 | 0 | 93.8% |
| **combined** | **229** | **7** | **7** | **97.0%** |

### The seven survivors

Each is annotated at its location in the source. None is outstanding work.

Two are unreachable by construction and retained as defence in depth:

- `challenge`'s `c.challenges >= MAX_CHALLENGES`. `draw` finalizes at the cap, so no
  state reaches `Phase.CHALLENGE` carrying two challenges.
- `_eligible`'s `sb == 0`. Both callers ask only about the current phase, whose seed is
  armed before that phase can be reached.

Five are equivalent mutants, which change no observable behaviour:

- `bits > 5` against `>=` in `_eligBits` — both yield 0 at `bits == 5`.
- the draw's `u * den < num << 128` — the two forms differ only on an equality of
  probability 2⁻¹²⁸.
- `StakeRegistry`'s freeze-base ternary at the boundary.
- `IndexRegistry`'s two pagination bounds, which return the same empty page either way.

### What `Settlement.t.sol` covers, and why

The suite contains 21 tests, each written against a specific surviving mutant and each
verified to fail on that mutant and pass on unmodified code. Five of those mutants
represented defects with material consequences:

| mutant | consequence |
|---|---|
| `vt.settled = true` → `false` | a coherent voter re-enters `claim` and is paid on each call, draining the pot |
| `claim`'s `\|\|` → `&&` | `claim(caseId, m)` is permissionless in `m`, so a non-voter passes the guard and reaches `settle(m, true, …)`; any address can be frozen by any caller |
| `challenge`'s stake guard `\|\|` → `&&` | an address holding no stake can purchase two further committees for a case |
| `challenge`'s seed `+` → `-` | the challenge round's committee A seed becomes a past block, so the challenger can compute that committee when they challenge, defeating the staging property |
| `draw`'s cap `>=` → `>` | the challenge cap becomes three rather than two |

Three further tests address mutants that a first pass had misclassified as
equivalent. The most significant concerns `submitRemoval`, which has its own
`nextCaseId++`: existing tests submitted listings and removals in separate groups, so
none confirmed that a removal leaves the counter where the next listing can use it.
Under the mutant a removal assigns the next submission an identifier already in use
and overwrites a live case. The other two are guard shapes covered on one function and
not on another: `reveal` at exactly its deadline, and `draw`'s own blockhash horizon.

A note on method, since it determines whether a hand check means anything: a probe
must apply exactly the mutation the campaign applies. Replacing both occurrences of
`nextCaseId++` reverts on the second submission and fails loudly, whereas the
single-line mutation in `submitRemoval` is silent. A probe that mutates more than the
campaign does measures a different program.

The code introduced for §4.4 required none of these additions. All eleven mutants on
the reveal threshold, the first-round and challenge-round branches, the non-reveal
freeze and the constructor guard were killed by `RevealFloor.t.sol` and
`ThreeVote.t.sol` on the first campaign.

## Open items

[`specs/protocol.md`](../specs/protocol.md) §11 is the authoritative list. Two items
bear directly on this code.

`minRevealsPerCommittee = 3` is conditional rather than settled, and is a constructor
argument so that a testnet can change it. `simulation/FINDINGS-floor-price.md` prices
it at 0.9% of cases unresolvable given 20% turnout and a 75% reveal rate, and at 28%
given 10% turnout. Below roughly 10% turnout no value both deters a small clique and
leaves ordinary cases resolvable. Turnout is unmeasured.

Identity rotation is untouched by anything here. A frozen moderator can leave the
frozen stake idle and stake a fresh address, so escaping a freeze costs one stake tied
up for the freeze duration — the same cost as serving it. `StakeRegistry`'s closing
comment records this where a reader of the contract will encounter it.

Two deliberate deviations from the specification are marked in the code rather than
left implicit: eligibility bits are derived from the staked count rather than the
non-frozen count §3 names, because a freeze expires on a clock with no transaction to
observe; and a moderator votes once per case rather than once per committee, which §3
does not decide either way.
