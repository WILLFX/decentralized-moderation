# Architecture

The publisher creates and verifies metadata, then submits content references and
a review fee. Staked moderators review against pinned guidelines using commit /
reveal voting. Finalized approvals update the topic index. Search reads approved
entries, verifies metadata and rechecks membership before opening content separately.

| Path | Responsibility |
| --- | --- |
| contracts/src, specs | Protocol, custody and approved topic index |
| MODERATION_GUIDELINES.md | Exact text bound by the deployment |
| websites/apps/moderator | Rust moderator website |
| websites/apps/publisher | Rust publisher website |
| websites/apps/search | Rust search website |
| websites/crates/swarm-core | Shared profiles, ABI, validation and protocol decisions |
| websites/crates/swarm-browser | Browser I/O, encrypted storage and wallet workflows |
| websites/apps/checkpoint | Native processing of local-chain checkpoint files |
| websites/test | Format vectors, Wasm crypto tests and package checks |
| tools | Build, upload and local infrastructure support |
| simulation, measurement | Existing derivations and measurement tools |

The three websites are separate static Swarm collections. Generated JavaScript
loads the Wasm bindings. Node scripts handle build/test operations and explicit
local Bee access; they do not implement the browser application workflows.

Runtime hashes and canonical block checks verify identity and consistency through
the selected RPC, not independent consensus. Reveal requires finalized/latest
state and the real-wall-clock inclusion guard before disclosure. Passwords and
real recovery files remain under user control. An indexed listing does not certify
content safety.

Current claim, freeze, timing, eligibility and challenge rules remain in the
protocol specification. Public testnet configuration, measurements and independent
review are required before considering deployment with material funds.

See [security and operating basis](SECURITY_AND_OPERATING_BASIS.md) for the
current trust assumptions, disclosure risks, original-hash recovery and fallback
settlement, including expiry risks in older immutable deployments.
