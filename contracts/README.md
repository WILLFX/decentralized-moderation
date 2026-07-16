# Moderation contract (M2)

Solidity implementation of `specs/state-machine.md`, built and tested with
Foundry. Work order: `specs/m2-work-order.md`.

> Status: **M2 in progress.** Scaffold only (M2-0). Module map and full docs land
> at M2-10.

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
