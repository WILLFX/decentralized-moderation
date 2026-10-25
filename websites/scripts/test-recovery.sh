#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$root"
wasm_bindgen="${WASM_BINDGEN:-$root/.tools/wasm-bindgen/bin/wasm-bindgen}"
build_target_dir="${CARGO_TARGET_DIR:-$root/target}"
cargo +1.96.0 build --locked --release --target wasm32-unknown-unknown -p swarm-vault-interop
mkdir -p "$build_target_dir/vault-interop"
"$wasm_bindgen" --target web --no-typescript --out-dir "$build_target_dir/vault-interop" --out-name vault_interop "$build_target_dir/wasm32-unknown-unknown/release/swarm_vault_interop.wasm"
node test/recovery-v1.mjs "$build_target_dir/vault-interop"
