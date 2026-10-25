# Implementation status

Three separate Rust/Wasm websites implement moderator, publisher and search flows.
The contracts implement the adopted scheduling and N-4 eligibility rules. This is
an in-progress system, not a public deployment or completed security audit.

The organized repository passed the combined Ubuntu check on 25 October 2026:
150 Solidity tests plus four audit regressions, Python eligibility/draw comparisons,
109 Rust workspace tests, the rebuilt Wasm recovery and production vault lifecycle
harness, and 60 Node package/tool tests. No failures or skips were reported.
All three release website packages contain seven verified public assets. These
source and synthetic checks do not complete the browser acceptance work below.

The full successful human Rust reveal → outcome draw → finalization → reward
settlement flow remains an integration requirement. Keep existing finality,
wall-clock, inclusion-budget and freeze rules unchanged. Settlement/refund of an
unresolved case does not pass that requirement.

The current Rust search release passed a controlled browser matrix on 25 October 2026:
exact and empty queries, normalization, pagination, metadata tampering/retry,
current membership after removal/relisting, separate content opening, category
expansion/intersection/union with deduplication, RPC failure recovery, source-block
replacement rejection, bounded provenance continuation, cancellation and reload
reset. These checks used synthetic RPC/history and metadata faults, with zero
wallet calls. They do not establish real-network consensus or wallet voting.

Fresh operator startup/profile generation and the reviewed Chiado rollout remain
separate delivery work. The local upload tool requires an already running owned
Bee environment and its current configuration; it does not deploy contracts or
create that environment automatically.

Persistent registries across business-logic upgrades, separate reward credits /
withdrawal, reputation policy and further removal work remain post-MVP work.
Ontology/runtime integration is outside the current implementation scope.

See [security and operating basis](SECURITY_AND_OPERATING_BASIS.md) for the
current trust assumptions, disclosure risks and outcome-seed expiry failure.
