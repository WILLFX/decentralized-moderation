# Transaction and trust model

This reference explains the operating assumptions behind the contracts and clients.
Participant actions are in the [participant guide](PARTICIPANTS.md); infrastructure
configuration is in the [operator guide](OPERATORS.md).

## Deployment identity and chain reads

A public profile identifies the chain, four contracts, their runtime code hashes
and the immutable guidelines identity. During deployment verification, clients
compare runtime code, contract links and the contract's guidelines version/hash
with the profile pins. This does not fetch or authenticate the guidelines document.
Moderator checks document bytes when loading review material; Publisher checks
them when loading guidelines. Reader checks the contract pins without loading
the document. A profile must come from a source the participant chooses to trust;
its fingerprint identifies bytes, not the person who distributed them.

Contract reads and receipts are pinned to canonical block hashes and rechecked
when an operation completes. The selected RPC supplies that chain evidence.
Canonical/finalized labels are observations from that provider, not an independent
consensus implementation inside the browser. A wallet must use the same intended
account and network as the reviewed operation.

## Private choices and disclosure

A commitment hides a choice using a random salt. The encrypted vault and recovery
file preserve both. Public request history is not a replacement for that private
backup. After reveal, the vote and salt are public on chain. A transaction removed
by reorganization cannot make already disclosed information private again.

Before disclosure the client requires finalized and latest case/schedule evidence,
wallet context, a fresh head and enough real time for inclusion. It repeats the
final disclosure check after wallet reads. Clock allowance and inclusion budget
are profile parameters, not extensions to contract deadlines. An inaccurate local
clock, stale head or delayed finality can block a reveal. Deadline inclusion still
requires timely submission and network processing.

## Interrupted signing

The clients retain the original account, deployment and operation when a wallet
request begins. A missing response is not proof that no transaction was sent.
Receipt reconciliation checks the actual sender, destination, nonce, input and
mined block. An imported history file supplies hints, not trusted confirmations.

Private choices may be changed only under the implemented proof-of-no-send rules.
Retained secrets remain available for matching a mined commitment. A replacement
or cancellation must satisfy the original request's reconciliation rules; a page
reload or unavailable receipt cannot authorize an unsafe retry.

## Timing and original hashes

Group scheduling assumes a minimum five-second timestamp step. The first group
uses the native block-hash window; the second uses the exact EIP-2935 target and
caches it with its first valid vote. Outcome draws use their originally armed hash,
with native history, extended history or a round-specific cache. A cached original
has no draw-age limit. Missing history does not permit a replacement sample.

An uncached outcome can expire only beyond the precise on-chain history boundary.
Initial expiry refunds the fee; challenge expiry uses the last completed outcome
and ordinary settlement. See the [protocol](../specs/protocol.md#431-original-hash-recovery-and-expiry)
for exact conditions. These rules need callers and gas; elapsed time alone performs
no recovery, settlement or payment.

## Participation and incentives

Selection uses the staked-address count fixed at case opening. It is not a fixed
admission roster: new identities can stake after a selection seed becomes known.
One stake per address and frozen time impose costs; they do not identify a unique
person. Block-derived randomness can also be influenced by block production.

Rewards follow agreement with the final outcome. They are not a contract assessment
of a participant's honesty or correctness. Frozen-time penalties tie up stake
rather than confiscating it. Phase advancement has no separate funded keeper
reward, so someone must choose to pay its gas. Each group still needs the configured
minimum number of reveals to produce a new outcome.

## Content and storage

Metadata and guideline hash checks identify exact documents. Moderators apply the
content rules; an authenticated description is not automatically a truthful one.
Submitted content opens on another origin so it does not share the application's
browser storage. A different URL path on the same origin is insufficient.

Swarm storage depends on postage and service availability. An approved listing
neither renews storage nor removes dangerous bytes from the network. Readers check
current index membership before opening content; that is a time-specific observation.
