# Mutation campaigns

One harness per v3 contract. Each removes a single invariant's enforcement from
the source, runs the suite, and records which tests fail. A mutation that kills
nothing is a finding about the *test suite*, not a passing grade.

```
cd contracts
FORGE=forge python3 tools/mutation/stake_registry.py
FORGE=forge python3 tools/mutation/moderation.py
FORGE=forge python3 tools/mutation/index_registry.py
```

Run them **one at a time**. All three mutate files in the same working tree and
invoke `forge` in the same directory, so concurrent runs contaminate each other.
Each harness restores the original source after every mutation and again on exit.

## Scoring

Three outcomes, and the distinction matters:

- `KILLED` — the mutant compiled, the suite ran, at least one test failed.
- `SURVIVED` — the mutant compiled, the suite ran, **every test passed**. This is
  a gap in the tests, or an equivalent mutant that has to be argued unreachable.
- `INVALID` — the mutant **did not compile**. The mutation never executed, so it
  says nothing about the tests. Never counted as a kill.

`INVALID` exists because it was once missing. Both `stake_registry.py` and
`index_registry.py` returned a truthy `["<compile error>"]` from `run()` on a
compile failure, which the caller read as "a test failed" and scored `KILLED`.
Any mutation that failed to compile was silently inflating the score. The class
of bug is easy to reintroduce: `run()` must distinguish *no failures* from *no
run*, so it returns `None` for a compile failure and a (possibly empty) list
otherwise.

A mutation whose anchor text is not found exactly once is reported
(`PATTERN-MISS` / `ANCHOR`) rather than applied — a silently un-applied mutation
would also score as a free kill.

## Reading a campaign

Survivors are reported, not tuned away. Each one is either a missing test (write
it) or an equivalent mutant (prove the mutated branch is unreachable, and say
why in the report). Do not edit a mutation to make it die.
