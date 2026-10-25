#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$root"
cargo +1.96.0 test --locked -p swarm-checkpoint
cargo +1.96.0 build --locked --release -p swarm-checkpoint
build_target="${CARGO_TARGET_DIR:-$root/target}"
install -d -m 700 "$root/../tools/local-session/.tools"
install -m 700 "$build_target/release/swarm-checkpoint" "$root/../tools/local-session/.tools/.tools-tmp-checkpoint"
mv -- "$root/../tools/local-session/.tools/.tools-tmp-checkpoint" "$root/../tools/local-session/.tools/swarm-checkpoint"
printf '%s\n' 'Native checkpoint tool built and tested. No saved session was required or changed.'
