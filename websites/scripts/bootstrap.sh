#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$root"
command -v rustup >/dev/null || { echo 'Install Rust with rustup first, then run this script again.' >&2; exit 1; }
rustup toolchain install 1.96.0 --profile minimal --component rustfmt --target wasm32-unknown-unknown
cargo +1.96.0 install wasm-bindgen-cli --version 0.2.118 --locked --root "$root/.tools/wasm-bindgen"
# Commit the generated lockfile with the migration after reviewing it.
if [[ ! -f Cargo.lock ]]; then cargo +1.96.0 generate-lockfile; fi
echo 'Build tools are ready. Run: bash scripts/build.sh'
