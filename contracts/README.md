# Moderation contract (M2)

Solidity implementation of `specs/state-machine.md`, built and tested with
Foundry. Work order: `specs/m2-work-order.md`.

> Status: **M2.6 complete** (all P0 remediation items closed; re-audit target: the `m2.6-close` tag), **plus a post-close regression pass** — that tag was
> independently verified and eight blocking regressions were found in items marked
> closed, plus three fixes that no test discriminated. They are fixed on top of it,
> as are the post-close items 2b, 4, 5, 8, 9, 10, 11, P1-3's residual, K-5 and the
> external-audit findings; the tag is not moved, because it is the
> commit the audit ran against. See the "Regressions found after the close" table
> in `specs/m2_6-work-order.md`. The state machine (staking, sortition, case
> lifecycle, appeals, settlement, index, governance) is implemented across four
> contracts — the replaceable game and its governor, plus two permanent
> registries — with **272 passing tests** (188 at the tag) including a
> handler-driven invariant campaign, a 52-vector differential regression test
> against a Python integer reference (a port of the Solidity, not an independent
> derivation — see `Differential.t.sol`'s header for what that does and does not
> prove), and a live logic-migration test.
>
> See `specs/m2_6-work-order.md` (Resolution record) and
> `specs/m2_6-state-of-play.md` for what landed, the four documented deviations
> from the prescription, and the open residuals.
>
> Builds with `via_ir = true` (EIP-170: `Moderation` does not fit the 24,576-byte
> limit without it). The suite runs on the same pipeline that ships. One
> consequence for contributors: **test code must use `vm.getBlockTimestamp()` /
> `vm.getBlockNumber()`, never `block.timestamp` / `block.number`** — the IR
> optimizer hoists those across `vm.warp`/`vm.roll` and the test silently reads a
> stale clock. See `GAS_BUDGETS.md`.

## Module map

| File | Role |
|---|---|
| `src/Moderation.sol` | The **replaceable game**: cases, appeals, settlement. Holds pot money only (fees + appeal bonds). |
| `src/RulesetGovernor.sol` | Governance **authoring**: proposing, validating and timelocking rulesets and guidelines versions. Split out of `Moderation` in M2.6 when it hit EIP-170 — authoring is cold and validation-heavy, enforcement is on every hot path. Ruleset *storage* stays in `Moderation` (`_cp()` reads it per transition); the governor pushes validated results in via `applyRuleset`. |
| `src/lib/Settlement.sol` | The settlement block — init, per-seat disposal, finish, index effects — as a **DELEGATECALLed library**. Split out of `Moderation` in M2.6 when the widen restructure needed EIP-170 room in the round state machine. A library rather than a contract because settlement touches almost all of `Case`/`Round`: the bytes move, the storage does not. |
| `src/lib/ProtocolLimits.sol` | The immutable H-11 caps, shared by the contract that validates a ruleset and the one that enforces it so the two cannot drift. |
| `src/StakeRegistry.sol` | **Permanent** custody + bookkeeping for moderator stake, the sortition tree and the H-07 duty pool. Moderators stake, exit and withdraw here directly — never through the game, so exit is never gated by logic. |
| `src/IndexRegistry.sol` | **Permanent** topic → approved-entries index. The protocol's actual product; it outlives every logic redeployment. |
| `src/lib/SortitionTree.sol` | Stake-weighted draw over a sum tree (clean 0.8.x port of Kleros' MIT `SortitionSumTreeFactory`; see attribution in the file). |
| `src/lib/FreezeMath.sol` | The §6.4 freezing-power curve `1 + (CAP-1)(1-e^(-meanTrack/SAT))` via solady `expWad`. |

Settlement math (the WO-1 solvent payout order) lives in `Moderation.sol` itself,
since it touches every part of the state.

Stake and approvals live in the registries so the game can be improved without
forcing every moderator to withdraw and re-stake and without discarding the
index. Governance repoints the registries at a new logic contract behind a
timelock; both stay authorized during handover so in-flight cases settle. See
`test/Migration.t.sol` for the property exercised end to end.

Conservation therefore spans two balances:

    balanceOf(Moderation)    == openPotsTotal + totalPendingBond
                                + totalPendingPayout + totalSettling
    balanceOf(StakeRegistry) == free + committed + frozen + dutyBonded

`Moderation` is at **20,012 bytes, 4,564 free** against EIP-170, after the second
structural split moved settlement into a delegatecalled library. That margin was
439 before the split, which is why it had to happen before the widen restructure
rather than after. See `specs/m2_6-work-order.md`, "Size position".

## Deployment

`script/Deploy.s.sol`, exercised by `test/Deploy.t.sol`. **The test is the artefact;
the script is what it tests** — a deploy script nothing drives is documentation that
compiles, which is what this repository had until M2.6-item-9.

`Settlement` is a **linked library**: it must be deployed and its address linked into
`Moderation` before `Moderation` can be deployed at all. Foundry does that
automatically for tests, so no suite could catch it being missed and the requirement
lived only in the module map above.

**The order is forced, not conventional.**

| # | step | why here |
|---|---|---|
| 1 | `StakeRegistry(token, timelock, minStake, activationDelay, exitCooldown, riskPerSeat, epochBlocks, minTrackDecay)` | governance is `msg.sender`; `minTrackDecay` is immutable and every ruleset must sit inside it (K-5) |
| 2 | `IndexRegistry(timelock)` | governance is `msg.sender` |
| 3 | `RulesetGovernor(governance, timelock)` | **before** `Moderation` — `Moderation.governor` is immutable |
| 4 | deploy + link `Settlement` | Foundry's job; see the link note below |
| 5 | `Moderation(token, stakeReg, indexReg, governor)` | reverts on a zero governor, and on `token != stakeReg.token()` |
| 6 | `governor.bindModeration(moderation)` | **one-way and unrecoverable**; refuses a `Moderation` that does not name this governor (M2.6-F3), so the order above is enforced rather than merely required |
| 7 | `proposeLogic` on BOTH registries → wait `timelockDelay` → `executeLogic()` on both | authorization |

The circularity — the governor needs the game, the game needs the governor — resolves
only because `RulesetGovernor` is constructed without a `Moderation` reference and
binds afterward. **Step 6 is the one that cannot be undone:** a wrong bind leaves a
governor that governs nothing and a `Moderation` whose immutable `governor` points at
it, with no repair from either side.

**`verify` is the deliverable.** It reverts on anything that would make the stack
unusable, so a broken deployment fails the script rather than the first case: one
token across `Moderation` and the registry; `OPEN_AND_SETTLE` on **both** registries
(desynchronised authorization is its own failure, not half of one); the bind checked
from both sides; `stakeReg.riskPerSeat() >= moderation.getParams().riskPerSeat`;
`moderation.getParams().trackDecay >= stakeReg.minTrackDecay()` (K-5 — below the
floor, every case opens and then reverts in `claim()` forever); a nonzero
`timelockDelay` on the governor and BOTH registries (F4 — the constructors accept
zero deliberately, so this is where the policy lives; `DEVIATIONS.md` D-16); and the
linked library.

**The link is the one thing no in-script check can prove.** The library address is
baked into `Moderation`'s bytecode at link time and Solidity cannot read its own link
table. So it splits: if you linked explicitly (`--libraries
src/lib/Settlement.sol:Settlement:0x...`) pass that address to `verify` and it asserts
the address holds the *right* code, not merely some code; and
`test_a_script_deployed_stack_settles_a_real_case` proves `Moderation` actually
reaches it the only way it can be proven — by settling a case, which delegatecalls
the library. A deployment that does neither is unverified on this point and `verify`
says so instead of returning green.

**Two properties of the process, stated because a single `run()` would hide them.**

- **It is not one transaction.** The registry timelock sits inside step 7, so there is
  a window where every contract exists and none is authorized. `submit` refuses during
  it (`_requireOpen`) — a case opened then would take a fee it could never settle.
  That refusal is asserted, not waited out.
- **Governance is the deploy key until transferred.** Both registries set
  `governance = msg.sender`; the governor takes it as an argument.
  `handOverGovernance` proposes to all three, and the recipient must call
  `acceptGovernance()` on each. If `GOVERNANCE_OWNER` is unset, `verify` warns loudly
  rather than passing quietly — a stack still owned by a deploy key is a finding, not
  a default.

## Tests

| Suite | Covers |
|---|---|
| `Staking.t.sol` | free/committed/frozen partition, activation, exit floor, freeze exclusion (§3, §9.3, §9.5) |
| `SortitionTree.t.sol` | draw correctness + distribution + gas |
| `CaseLifecycle.t.sol` | submit → draw → commit → reveal → tally, widen, VOID, two-seed ordering (§5) |
| `Appeals.t.sol` | flip-bond aggregation, floor cap, reclaim, self-appeal, MAX_DEPTH (§5.4) |
| `Settlement.t.sol` + `FreezeMath.t.sol` | WO-1 payout order, flip-flop conservation, freeze, track (§6) |
| `Index.t.sol` | write-at-settlement, uncontested, removal, supersafe (§8); H-09 quorum counts independent revealers, not seats |
| `Registries.t.sol` | the storage/logic split: no re-staking across an upgrade, approvals survive, timelocked repoint, exit independent of logic, governance cannot touch funds |
| `Migration.t.sol` | a live logic migration: case settled under A, registries repointed, stake + index intact, new case settles under B; the retirement lifecycle, and the drain gate on BOTH registries (M2.6-P0-5b) |
| `Governance.t.sol` | timelocked params via `RulesetGovernor`, append-only guidelines, no pause (§9.9), the apply boundary, the drawable-panel cap, the M2.6-P0-8 freeze bounds, and the two-step governance transfer (M2.6-L-2) |
| `Invariant.t.sol` | handler campaign: conservation, partition, no-principal-lost (§9.1/2/3/11) |
| `StakeBenefit.t.sol` | single-stake-benefit statistical property (§9.10) |
| `Differential.t.sol` | 52 vectors vs. `simulation/vectors/reference_int.py`, bit-exact. A **regression net, not an oracle** — the reference is a port of the Solidity, and two of its assumptions (last round adjudicates; capacity sought == seats seated) are mirrored by the injector, so no vector varies them. See the file header |
| `GasBounds.t.sol` | worst-case `claim()` under the 8M ceiling; the seat-draw and epoch-drain batch bounds; §10 failure modes |
| `StalledDraw.t.sol` | M2.6-P0-6/6b/6c: a draw that cannot complete must still end, and disposal depends on whether a commit window ever opened. Split out of `CaseLifecycle.t.sol` when that outgrew the `via_ir` pipeline |
| `SeatDraw.t.sol` | M2.6-P0-3d / H-03B: the cross-batch upward family, which no registry-level fixture can reach (`DRAW_SEATS_PER_BATCH` returns to the caller mid-panel) |
| `StallRound.t.sol` | M2.6-item-2b: the commit-time widen and the next-depth stall round |
| `RewardScoping.t.sol` | M2.6-item-10: per-depth reward allocation and the depth-dependent divisor, by injection over a specified round shape |
| `Deploy.t.sol` | M2.6-item-9: every deploy phase through the timelock, each invariant `verify` claims, and that `verify` rejects each broken stack |
| `WidenSeats.t.sol` | F2: a widen re-draw adds seats to a voter that already revealed; settlement pays only the seats tallied at reveal |
| `Scaffold.t.sol` | M2-0 smoke: the toolchain runs, and the two load-bearing environment facts (xBZZ has 16 decimals; WAD is not a token base unit) |

Spec departures are catalogued in `DEVIATIONS.md`; gas budgets/actuals in
`GAS_BUDGETS.md`. Regenerate differential vectors with
`python3 ../simulation/vectors/export_vectors.py > test/vectors/settlement_vectors.json`.

## Toolchain (pinned)

| Tool | Version | Notes |
|---|---|---|
| Foundry (`forge`) | v1.7.1 | built from source (see below) |
| solc | 0.8.28 | pre-provisioned under `~/.svm/0.8.28` |
| forge-std | v1.9.7 | submodule `lib/forge-std` |
| solady | v0.1.9 | submodule `lib/solady` (FixedPointMathLib, ERC20 mock) |

## Environment provisioning (this sandbox)

Outbound egress is proxied and several hosts the normal Foundry install relies on
are policy-blocked, so the standard `foundryup` path does not work here. What was
done instead, all through allowed hosts:

- **`solc`**: svm's default host `binaries.soliditylang.org` is blocked. The
  0.8.28 binary is fetched from the GitHub `ethereum/solc-bin` mirror
  (`raw.githubusercontent.com`, allowed), **sha256-verified against the mirror's
  `list.json`**, and placed at `~/.svm/0.8.28/solc-0.8.28`. `foundry.toml` pins
  `solc_version = "0.8.28"` and sets `offline = true` so forge never probes the
  blocked host.

  ```sh
  mkdir -p ~/.svm/0.8.28
  base=https://raw.githubusercontent.com/ethereum/solc-bin/gh-pages/linux-amd64
  curl -sSL -o ~/.svm/0.8.28/solc-0.8.28 \
    "$base/solc-linux-amd64-v0.8.28%2Bcommit.7893614a"
  curl -sSL -o /tmp/list.json "$base/list.json"   # keep: needed for forge, below
  # expect 9a0fb7e0db2c0641dbae1c5cc645dc686820c83af516226abb1c0a2f76636f25
  sha256sum ~/.svm/0.8.28/solc-0.8.28
  chmod +x ~/.svm/0.8.28/solc-0.8.28
  ```

- **`forge`/`anvil`**: `foundryup` downloads prebuilt binaries from GitHub
  releases, which are blocked (403). Build from source instead — but the plain
  `cargo install` **fails**: the `svm-rs-builds` build script fetches
  `binaries.soliditylang.org/linux-amd64/list.json` at compile time and panics
  on the blocked CONNECT. Point it at the mirror copy saved above:

  ```sh
  SVM_RELEASES_LIST_JSON=/tmp/list.json \
    cargo install --git https://github.com/foundry-rs/foundry \
      --tag v1.7.1 --locked forge anvil
  ```

  (github git access and `index.crates.io` are allowed.) The build takes ~30 min
  on 4 cores. If it fails partway, `CARGO_TARGET_DIR` set to the
  `/tmp/cargo-install*` path cargo names in its error message reuses the
  artifacts instead of restarting.

- **Submodules**: `lib/forge-std` and `lib/solady` are git submodules and a fresh
  clone leaves them empty — `forge test` then fails on unresolvable imports.
  `git submodule update --init --recursive` from the repo root.

On an unrestricted machine, `foundryup && forge test` works normally; none of the
above is a project requirement, only a sandbox workaround.

## Environment facts (load-bearing)

- **xBZZ has 16 decimals**, not 18 (Swarm BZZ token). Internal fixed-point math is
  WAD (1e18) and is kept independent of token decimals; token amounts are base
  units. `MockBZZ` reproduces the 16-decimal quirk so a stray "1 token = 1e18"
  assumption fails a test. Re-confirm the deployed Gnosis token at M4.
- **Gnosis block gas limit ~17M** — see `GAS_BUDGETS.md` (could not be confirmed
  live; RPCs blocked here).

## Build & test

```
cd contracts
forge test
forge snapshot        # gas (M2-9)
```
