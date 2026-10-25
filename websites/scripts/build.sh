#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$root"
wasm_bindgen="${WASM_BINDGEN:-$root/.tools/wasm-bindgen/bin/wasm-bindgen}"
[[ $# -le 1 ]] || { echo 'Use build.sh [all|moderator|publisher|search].' >&2; exit 1; }
case "${1:-all}" in
  all) roles=(moderator publisher search) ;;
  moderator|publisher|search) roles=("$1") ;;
  *) echo 'Unknown website role.' >&2; exit 1 ;;
esac
[[ -f Cargo.lock && -x "$wasm_bindgen" ]] || { echo 'Run bash scripts/bootstrap.sh first.' >&2; exit 1; }
cargo +1.96.0 fmt --all -- --check
cargo +1.96.0 test --workspace --features swarm-browser/browser-check --locked
build_target_dir="${CARGO_TARGET_DIR:-$root/target}"
for role in "${roles[@]}"; do
  cargo +1.96.0 build --locked --release --target wasm32-unknown-unknown -p "swarm-$role"
  bindings="$build_target_dir/web-bindings"
  [[ "$role" == moderator ]] || bindings="$bindings/$role"
  mkdir -p "$bindings"
  "$wasm_bindgen" --target web --no-typescript --out-dir "$bindings" --out-name "swarm_$role" "$build_target_dir/wasm32-unknown-unknown/release/swarm_$role.wasm"
  node scripts/package.mjs "$role"
done
node --test test/package.test.mjs test/publish-local.test.mjs
if [[ " ${roles[*]} " == *' moderator '* ]]; then bash scripts/test-recovery.sh; fi
echo "Rust websites built: ${roles[*]}. Publishing is a separate local step."
