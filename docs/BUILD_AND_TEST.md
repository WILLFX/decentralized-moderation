# Build and test

These commands are for contributors and operators building a website package.
Participants can use the [published release](releases/TESTNET_MVP.md) without a
compiler or repository checkout.

## Tools

Use Linux or Ubuntu WSL with Git, Foundry/Anvil 1.7.1, Solidity 0.8.28, Python 3,
Node.js 18 or later, and Rust installed through rustup. The website toolchain is
Rust 1.96.0 with wasm-bindgen 0.2.118. Dependencies are pinned in the repository's
lockfile and Git submodules.

Provision Solidity 0.8.28 locally before building: `contracts/foundry.toml` selects
that compiler and offline operation. The Rust bootstrap installs its specified
toolchain and bindings CLI. Node scripts use built-in modules; there is no npm
install step for this repository's packaging tools.

## First build

From the repository root:

```sh
git submodule update --init --recursive
(cd websites && bash scripts/bootstrap.sh)
bash scripts/check.sh
```

Run bootstrap only when those tools are absent. The repository check compiles
contracts and Rust, runs the configured checks and builds the three websites.
It does not sign transactions, start a public deployment or upload collections.

For a focused website build:

```sh
bash websites/scripts/build.sh publisher
bash websites/scripts/build.sh moderator
bash websites/scripts/build.sh search
```

Omit the role to build all three. Public outputs are under `websites/dist/`.
`WASM_BINDGEN` can select an existing matching bindings CLI. `CARGO_HOME` and an
absolute `CARGO_TARGET_DIR` can reuse a local cache. Neither variable requires a
particular computer or drive.

## Work on individual components

```sh
(cd contracts && forge test --use 0.8.28)
(cd websites && cargo +1.96.0 test --workspace --features swarm-browser/browser-check --locked)
python3 -m unittest discover -s tools -p test_publisher_setup.py -v
node --test websites/test/browser/provider.test.mjs
```

Use [browser fixtures](../websites/test/browser/README.md) for prepared interface
states. They serve built applications with isolated synthetic providers. Use test
accounts and synthetic recovery files in development; do not add personal files
to fixtures.

The native checkpoint processor is built separately:

```sh
bash websites/scripts/build-checkpoint.sh
```

It is installed under ignored `tools/local-session/.tools/` and never belongs in a
public website collection. [Checkpoint documentation](../websites/apps/checkpoint/README.md)
explains its file-processing role.

## Package and publish

The build creates a separate allowlisted collection for each website. Generated
JavaScript loads Wasm; test-only exports and configuration are excluded from these
public packages. Publishing is a separate operator action, described in the
[operator guide](OPERATORS.md#publish-website-collections-and-maintain-storage).
