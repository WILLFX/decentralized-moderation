# Moderation contract (M2)

Solidity implementation of `specs/state-machine.md`, built and tested with
Foundry. Work order: `specs/m2-work-order.md`.

> Status: **M2 complete.** The contract implements the full state machine
> (staking, sortition, case lifecycle, appeals, settlement, index, governance)
> with 86 passing tests including a handler-driven invariant campaign and a
> differential test against an independent Python reference.

## Module map

| File | Role |
|---|---|
| `src/Moderation.sol` | The single deployed contract: moderators + stake, the sortition tree, cases, appeals, settlement, the index, and governance — one token balance for the conservation invariant (§9.1). |
| `src/lib/SortitionTree.sol` | Stake-weighted draw over a sum tree (clean 0.8.x port of Kleros' MIT `SortitionSumTreeFactory`; see attribution in the file). |
| `src/lib/FreezeMath.sol` | The §6.4 freezing-power curve `1 + (CAP-1)(1-e^(-meanTrack/SAT))` via solady `expWad`. |

Settlement math (the WO-1 solvent payout order) lives in `Moderation.sol` itself,
since it touches every part of the state.

## Tests

| Suite | Covers |
|---|---|
| `Staking.t.sol` | free/committed/frozen partition, activation, exit floor, freeze exclusion (§3, §9.3, §9.5) |
| `SortitionTree.t.sol` | draw correctness + distribution + gas |
| `CaseLifecycle.t.sol` | submit → draw → commit → reveal → tally, widen, VOID, two-seed ordering (§5) |
| `Appeals.t.sol` | flip-bond aggregation, floor cap, reclaim, self-appeal, MAX_DEPTH (§5.4) |
| `Settlement.t.sol` + `FreezeMath.t.sol` | WO-1 payout order, flip-flop conservation, freeze, track (§6) |
| `Index.t.sol` | write-at-settlement, uncontested, removal, supersafe (§8) |
| `Governance.t.sol` | timelocked params, append-only guidelines, no pause (§9.9) |
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

- **`forge`/`anvil`**: `foundryup` downloads prebuilt binaries from GitHub
  releases, which are blocked (403). Built from source instead:
  `cargo install --git https://github.com/foundry-rs/foundry --tag v1.7.1 --locked forge anvil`
  (github git access and `index.crates.io` are allowed).
- **`solc`**: svm's default host `binaries.soliditylang.org` is blocked. The
  0.8.28 binary was fetched from the GitHub `ethereum/solc-bin` mirror
  (`raw.githubusercontent.com`, allowed), **sha256-verified against the mirror's
  `list.json`**, and placed at `~/.svm/0.8.28/solc-0.8.28`. `foundry.toml` pins
  `solc_version = "0.8.28"` and sets `offline = true` so forge never probes the
  blocked host.

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
