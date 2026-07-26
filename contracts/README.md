# Moderation contract (M2)

Solidity implementation of `specs/state-machine.md`, built and tested with
Foundry. Work order: `specs/m2-work-order.md`.

> Status: **M2.6 complete** (all P0 remediation items closed; re-audit target `a1671e5`). The state machine (staking, sortition, case
> lifecycle, appeals, settlement, index, governance) is implemented across four
> contracts — the replaceable game and its governor, plus two permanent
> registries — with **188 passing tests** including a handler-driven invariant
> campaign, a differential test against an independent Python reference, and a
> live logic-migration test.
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

## Tests

| Suite | Covers |
|---|---|
| `Staking.t.sol` | free/committed/frozen partition, activation, exit floor, freeze exclusion (§3, §9.3, §9.5) |
| `SortitionTree.t.sol` | draw correctness + distribution + gas |
| `CaseLifecycle.t.sol` | submit → draw → commit → reveal → tally, widen, VOID, two-seed ordering (§5) |
| `Appeals.t.sol` | flip-bond aggregation, floor cap, reclaim, self-appeal, MAX_DEPTH (§5.4) |
| `Settlement.t.sol` + `FreezeMath.t.sol` | WO-1 payout order, flip-flop conservation, freeze, track (§6) |
| `Index.t.sol` | write-at-settlement, uncontested, removal, supersafe (§8) |
| `Registries.t.sol` | the storage/logic split: no re-staking across an upgrade, approvals survive, timelocked repoint, exit independent of logic, governance cannot touch funds |
| `Migration.t.sol` | a live logic migration: case settled under A, registries repointed, stake + index intact, new case settles under B |
| `Governance.t.sol` | timelocked params via `RulesetGovernor`, append-only guidelines, no pause (§9.9), the apply boundary, the drawable-panel cap, and the M2.6-P0-8 freeze bounds |
| `Invariant.t.sol` | handler campaign: conservation, partition, no-principal-lost (§9.1/2/3/11) |
| `StakeBenefit.t.sol` | single-stake-benefit statistical property (§9.10) |
| `Differential.t.sol` | 52 vectors vs. `simulation/vectors/reference_int.py`, bit-exact |
| `GasBounds.t.sol` | worst-case `claim()` under the 8M ceiling; §10 failure modes |

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
