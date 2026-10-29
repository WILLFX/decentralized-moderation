# Implementation status

Three separate Rust/Wasm websites implement discovery, publishing and moderation.
The contracts implement committee scheduling, N-4 eligibility, execution-bound
challenges and recovery of the original outcome hash. This is a release candidate;
it has not completed an independent security audit or uncoached human acceptance.

## Implemented journeys

- Readers search normalized topics, authenticate metadata and historical LIST
  provenance, recheck current membership and open content separately. Slow results
  preserve typing focus. Source times distinguish blocks from wall-clock time.
- Publishers review deployment identity, prepare content and metadata, review an
  exact fee, approve only when needed, and submit explicitly. Drafts survive reload;
  public history supports publication follow-up, refunds and interrupted requests.
  Setup links and local profiles are supported. Personal Bee settings remain
  separate from deployment pins and exported drafts.
- Moderators use a work list, selected-case review and follow-up actions. Timing,
  stake eligibility, challenge consequences and transaction context appear near
  the action. Encrypted private votes support recovery and correction only when
  the old choice is provably unsent. Both reveal guards remain mandatory.

Wallet discovery supports compatible browser wallets without assuming one brand.
Layout and orientation follow the available viewport. Recovery routes preserve
private data and uncertain sends instead of treating a missing response as failure.

## Protocol recovery and settlement

A challenge binds the reviewed round and outcome; the old unbound call is blocked.
Outcome recovery caches only the original target hash, with no replacement draw.
A cached original remains drawable. Terminal expiry requires the on-chain recovery
boundary, not an RPC failure. Initial expiry is unresolved and refundable, with no
outcome-based punishment or reward for revealers. Challenge expiry preserves the
last completed outcome and applies ordinary settlement, including the challenger.
Non-reveal penalties remain. Ordinary fallback settlement does not prove wrongdoing.
Phase and expiry events report the actual transition. LIST, REMOVE and both
challenge rounds have boundary, fee, per-vote and removal-slot regressions.

Publisher and moderator views use pinned recovery capability reads. An unavailable
read cannot establish expiry, a refund or finality. Existing immutable deployments
do not gain this protocol behavior from a website update.

## Verification and limits

The repository gate runs Solidity lifecycle, invariant and audit regressions;
Python eligibility/draw comparisons and browser-observer tests; Rust workspace
checks; rebuilt Wasm recovery tests; wallet-provider and package/tool tests; and
all three website builds. See [build and test](BUILD_AND_TEST.md).
Controlled built-browser checks cover the three journeys, fault recovery, narrow
and enlarged-text layouts. Each package has seven checked public assets.

An earlier live Chiado run completed submission, both committees, reveals,
finalization and six controlled settlements, followed by a Rust search check.
That demonstrates controlled integration, not independent moderation judgment,
turnout incentives, human comprehension or accessibility across real devices.
Synthetic browser checks do not establish extension-wallet behavior on every device.
The replacement deployment and matching full-journey acceptance remain required
for this protocol revision. Source tests are not a substitute for those checks.

Deployment operators supply their own network, contracts and service configuration.
Participants retain control of wallets, drafts and private recovery files. Public
setup tooling does not create a Bee environment automatically. See
[publisher setup](PUBLISHER_SETUP.md), [publisher history](PUBLISHER_HISTORY.md)
and [security and operating basis](SECURITY_AND_OPERATING_BASIS.md).

Persistent registries across upgrades, separate reward withdrawals and reputation
policy remain post-MVP work. Ontology/runtime integration is outside current scope.
