#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$root"
if [[ -n "${CARGO_TARGET_DIR:-}" && "$CARGO_TARGET_DIR" != /* ]]; then
  export CARGO_TARGET_DIR="$root/$CARGO_TARGET_DIR"
fi
(cd contracts && forge test --use 0.8.28 && FOUNDRY_TEST=audit FOUNDRY_OUT=out-audit FOUNDRY_CACHE_PATH=cache-audit forge test --use 0.8.28 --match-contract 'TakeoverProbes|ChallengeIntentProbe|CompletionReviewProbes|OutcomeRecoveryTest' --match-test test_regression)
python3 -m unittest discover -s simulation -p test_eligibility.py -v
python3 simulation/check_eligibility_vectors.py
python3 simulation/check_draw_vectors.py
python3 -m unittest discover -s websites/test/browser -p 'test_*.py' -v
python3 -m unittest discover -s tools -p 'test_publisher_setup.py' -v
node --test websites/test/browser/provider.test.mjs
bash websites/scripts/build-checkpoint.sh
bash websites/scripts/build.sh
node --test tools/test/*.test.mjs tools/local-bee/*.test.mjs
