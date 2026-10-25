# Build and test

Use Linux or Ubuntu WSL with Foundry/Anvil 1.7.1, Solidity 0.8.28, Python 3,
Node 18 or later, and Rust 1.96.0. Solidity is configured for offline compilation;
provision 0.8.28 first. Node is used for packaging, Wasm crypto tests and local Bee
tooling. Browser application logic is Rust/Wasm.

From the repository root:

```bash
git submodule update --init --recursive
(cd websites && bash scripts/bootstrap.sh)
bash scripts/check.sh
```

Bootstrap is only needed when the pinned Rust/Wasm tools are absent. WASM_BINDGEN
can select an existing wasm-bindgen 0.2.118 executable. CARGO_HOME and an absolute
CARGO_TARGET_DIR can reuse an existing cache. No Windows drive is required.
The Node tools use built-in modules; this build has no npm install step.

The check script runs normal Solidity tests, named audit regressions, Python
eligibility and outcome-draw comparisons, native Rust tests/build, the Rust
workspace and release Wasm builds, encrypted-recovery format checks, and packaging/local-tool tests. Generated
outputs are ignored. It does not start a live chain, sign a wallet request or
publish a website.

The encrypted-recovery check exercises the Rust WebCrypto implementation against
synthetic format-v1 data, round trips, fresh encryption randomness and rejection
of wrong passwords, modified ciphertext and weakened KDF parameters. The same
harness drives the production Rust vault with synthetic local storage:
persistence, exact backup coverage, import conflicts, write failure, cross-tab
changes and locking during encryption. Test exports are built separately and
cannot enter a public website collection.

Public website collections are websites/dist/{moderator,publisher,search}. Each has
seven allowlisted assets with hashes. Native checkpoint processing is separate;
its binary must not enter a website collection.

See STATUS.md for the current validation limits. The organized checkout passed this
combined Ubuntu gate on 25 October 2026; browser acceptance remains separate.
