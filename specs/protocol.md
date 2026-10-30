# Moderation protocol

This reference describes the implemented protocol used by the [testnet MVP](../docs/releases/TESTNET_MVP.md).
Deployment parameters are constructor values. The release entry gives the Chiado
values; another deployment can choose different values. Browser procedures are in
the [participant guide](../docs/PARTICIPANTS.md).

## 1. Cases and content

A **listing case** requests inclusion of a content/metadata pair under one to five
topics. A **removal case** requests removal of an existing approved listing. Swarm
stores the content and metadata. `Moderation` stores their references and the
review state; it does not fetch content or parse metadata JSON. Clients apply the
[metadata format](../docs/METADATA.md), and moderators judge content, descriptions
and topic fit against the deployment's guidelines.

## 2. Moderators and stakes

An address stakes a fixed token amount in `StakeRegistry`. Stake size does not
weight votes. A staked, unfrozen address may commit when selected for the current
group, or challenge when permitted. It may participate in multiple cases, but
**may record only one vote in a particular case**, across all groups and rounds.
A public challenge also uses that case-wide vote slot.

A commitment increases the address's outstanding-vote count. Settlement decreases
it once. Withdrawal requires no outstanding votes and no current freeze; it returns
the fixed stake. The protocol does not take or redistribute the stake as a penalty.
A freeze prevents new commitments and challenges, not revelation of an existing
commitment. Merely being selected and not committing creates no obligation.

The guidelines version and Keccak-256 hash are immutable contract values. The root
[guidelines document](../MODERATION_GUIDELINES.md) is the exact text for this release.
Changing its bytes creates a different guidelines identity and requires a new
deployment to govern future cases.

## 3. Selecting voting groups

Each round has a **first group (A)** and a **second group (B)**. They commit in
sequence and reveal together. A selection seed is the block hash used to calculate
group eligibility. The groups use separate seeds. A round is the initial review or
one of at most two challenge reviews.
The contract numbers them 0, 1 and 2 and reuses the A/B phases in each round.

Let `S` be the number of staked addresses when a case opens. Define:

```text
N = floor(log2(max(S, 1)))
bits = max(N - 4, 0)
selection probability = 1 / 2^bits
```

`floor` means round down, and `log2` is the base-2 logarithm.
An address passes selection when its eligibility hash starts with at least `bits`
zero bits. The hash is Keccak-256 of ABI-encoded fields (Ethereum's structured contract
encoding):

```text
keccak256("eligibility"), chain ID, moderation address,
case ID, group number (1 or 2), group seed, moderator address
```

The staked count includes frozen addresses and remains fixed for the case, including
challenges. It does not create a fixed roster: an address must be currently staked
and unfrozen when committing, and new addresses can stake after case opening.
Previously used addresses cannot vote again in the case.

For example, 64 staked addresses produce `bits = 2`, a one-in-four selection chance
and an expected 16 passing addresses before participation and other exclusions.
At 1,000, the expectation is 31.25. Below 32, all addresses pass the lottery.
These are selection expectations, not fixed group sizes or guaranteed attendance.
`isEligible` reports the current selection/time result; the committing call also
checks stake, freeze, the unused vote slot and the commitment.

## 4. Case lifecycle

A case opens a pair of voting groups. Their commitments close in sequence, their
reveals share one period, and a sufficient round proceeds to an outcome draw.
The contract uses `NONE`, `COMMIT_A`, `COMMIT_B`, `REVEAL`, `CHALLENGE`, `FINALIZED`
and `UNRESOLVED` as stored phase names. Approve and Reject are outcome values 1
and 2; 0 means no outcome.

### 4.1 Scheduling, commitment and revelation

Use `M = maxWaitForThird`, `W = commitWindow` and `g = seedLag`. At opening block
`b0` and timestamp `t0`, the first group's seed target is `b0 + g`. The pair schedule
starts with:

```text
A deadline = t0 + M
B deadline = t0 + 2*M
B seed target = b0 + ceil(M/5) + g
```

The first group's third valid commitment at block `b3`, timestamp `t3`, revises
that schedule once:

```text
A deadline = t3 + W
B deadline = t3 + W + M
B seed target = b3 + ceil(W/5) + g
```

The third commitment is refused if the old/new target cannot remain valid and
future. Later commitments cannot revise the pair. This scheduling uses a minimum
five-second block timestamp step. The target height is known before its block
hash exists; seed lag is not a finality rule.

A uses the execution block hash only after its target and through target + 250.
Unavailable seed evidence can prevent a commitment before the time deadline.
B's first valid commitment reads its exact target from the EIP-2935 history service
and caches that hash with the vote. Unavailable, malformed, zero or out-of-window
history refuses entry. Invalid votes cannot activate or cache B. Subsequent B
commitments use the cached seed. The third B commitment sets B's deadline to
its timestamp plus `W`; subsequent commitments cannot extend it.

A commitment must execute strictly before the relevant deadline. After A's
deadline, `commit` can route directly to B without a separate closing call.
Stored `COMMIT_A` may therefore coexist with B's effective admission interval.
Clients read `pairScheduleOf` for effective deadlines, not only the stored phase.

#### Private votes and advancement calls

A private vote is Approve or Reject plus a random 32-byte salt. The commitment is
Keccak-256 of ABI-encoded fields:

```text
keccak256("commit"), chain ID, moderation address,
case ID, round, moderator address, vote, salt
```

`commit(caseId, commitment)` records a nonzero hash. `reveal(caseId, vote, salt)`
checks it against the saved vote and current round. Both groups reveal in the same
period, so the second group commits before the first group's choices are public.
Reveals must execute strictly before the reveal deadline. Only the original
committer can reveal that private vote.

Phase changes need transactions:

| Call | Effect |
| --- | --- |
| `closeCommitA` | Synchronizes stored phase after A's deadline; an initial round with zero A commitments becomes unresolved |
| `closeCommitB` | After B's deadline, opens a full reveal period at the caller's timestamp; initial zero-A cases become unresolved |
| `closeReveal` | After the reveal deadline, checks both groups' reveal counts and either ends the round or arms an outcome draw |
| `closeChallenge` | Finalizes after an unchallenged challenge period |

### 4.2 Challenges

`challenge(caseId, expectedRound, expectedPreliminary)` requires an open challenge
period, an active/unfrozen caller and an unused case-wide vote slot. Challenge
admission uses these conditions, not a group-selection lottery. It binds the round
and outcome the caller reviewed; either mismatch reverts the whole operation.
The one-argument `challenge(caseId)` call always refuses execution.

A challenge records an already-public vote opposite the standing outcome. It has
no salt, later reveal, extra review fee or separate bond. It increases the caller's
outstanding-vote count and shares the ordinary reward/freeze consequences.
The vote's stored round is the reviewed round, before the case increments its
challenge counter and opens a new pair of groups.

A new round resets the group counts, schedule and outcome target; pooled votes
remain. At most two challenges are allowed. With a three-reveal minimum and
case-wide address exclusion, a successful initial round needs six distinct
revealing addresses; two further successful rounds and their challengers use
at least twenty distinct addresses.

### 4.3 Finalization

An initial or first-challenge draw opens a challenge period. If it expires without
a challenge, `closeChallenge` finalizes the standing outcome. A sufficient second
challenge draw finalizes immediately. A failed challenge round also finalizes the
previous completed outcome, using the same settlement rule.

Finalization makes listing/removal membership changes effective. Per-vote claims
and refunds remain separate calls; finalization itself does not pay all voters.

### 4.3.1 Original-hash recovery and expiry

`draw` and `cacheOutcome` use only the originally armed target's hash. They first
use a round-specific cache, then the native block hash through age 256, then the
[EIP-2935 history service](https://eips.ethereum.org/EIPS/eip-2935) through age 8,191.
The fixed service address is `0x0000F90827F1C53a10cb7A02335B175320002935`.
A cached original hash remains drawable without an age limit. No caller supplies
a replacement hash; the target cannot be rerolled or rearmed in that round.

`expireOutcome(caseId, expectedRound, expectedTarget)` is permitted only for an
armed `REVEAL`, with matching round/target, no current-round cache, and
`block.number > target + 8191`. A failed RPC or history read is not expiry authority.
At the boundary itself, recovery is still possible and terminal expiry is not.

- **Initial-round expiry:** unresolved, full fee owed to the submitter. Revealers
  receive no reward or outcome-based freeze. Non-reveal penalties remain.
- **Challenge-round expiry:** the last completed outcome becomes final. Ordinary
  pooled settlement applies to every recorded vote, including the challenger
  whose public vote is tagged with the earlier reviewed round. There is no refund.

Fallback settlement follows that outcome; it does not establish wrongdoing or
responsibility for failure to draw. Both terminal paths release an open removal
slot. Expiry creates neither a replacement draw nor another challenge window.

### 4.4 Per-group reveal minimum

Each group must contribute at least `minRevealsPerCommittee` reveals in that round.
The release uses three. A combined total cannot substitute for the minimum in each
group. If either group misses it, the initial case becomes unresolved and refundable;
a challenge round finalizes the last completed outcome instead.

## 5. Drawing an outcome

A sufficient `closeReveal` call fixes a future outcome target at its execution
block plus `seedLag`. Commit/reveal tallies are then closed. The stored phase stays
`REVEAL` while the draw is armed; arming is not a new voting or challenge period.

The draw uses the pooled Approve and Reject counts across all rounds, including
public challenges. If `a` of `n` revealed votes approve, each of three tickets
approves with share `a/n`; the majority of the three tickets is the outcome.
The implementation derives three 128-bit values from the outcome hash with domain,
chain, contract, case, round and ticket-index separation, and uses integer
comparison against that raw share. It does not use a simple majority of voters or
add smoothing votes to the tally.

The initial draw and first challenge draw open `challengeWindow`. A successful
second challenge draw finalizes immediately. The number of Approve tickets and
whether a challenge occurred are recorded separately; three Approve tickets do
not mean all moderators approved.

## 6. Fees, rewards, freezes and refunds

Submission transfers the selected fee from the submitter to `Moderation`, subject
to `feeMin` and the `uint128` fee bound. ERC-20 approval and case submission are
separate calls. The pot stays in the moderation contract until settlement/refund.
There is no separate reward for closing, caching, drawing or other advancement.

After finalization, `claim(caseId, moderator)` settles one vote. Anyone may call it;
any payment goes to that moderator, not to the caller. A vote can settle once.
Revealed votes matching the final outcome each receive:

```text
share = floor(original case fee / pooled matching revealed votes)
```

Integer-division remainder stays in the contract. Contrary votes receive no reward
and add `freezePerLoss`. A missing reveal adds the same freeze. In unresolved
initial cases, revealers receive neither rewards nor outcome-based freezes; only
non-revealers are frozen. Every committed vote still needs settlement to release
its outstanding-vote count.

Frozen time accumulates as `max(now, frozenUntil) + freezePerLoss`. It prevents new
commitments/challenges and withdrawal during that period, without transferring
stake away. The same stake can support concurrent cases; each settled contrary
vote or non-reveal can add another freeze period.

An unresolved case puts its full pot in `refundOwed` and clears the pot.
`withdrawRefund(caseId)` transfers it once to the original submitter. The caller
cannot redirect it. Finalized rejection is not an unresolved case and has no
publisher refund. These rules apply to both listing and removal submissions.

## 7. Index

The claim key is `keccak256(abi.encode(contentHash, metaHash))`. A topic row uses
`keccak256(abi.encode(claimKey, topicKey))`. A finalized listing approval writes
those topic rows with tally, ticket agreement, challenge history and finalization
time. Topic membership has paged reads.

Registry entry facts and current membership are separate: removing a row does not
erase the listing's history. Repeated content/metadata submissions can also share
a claim key. Reader uses original listing-case provenance as well as current
membership; a removal case is not a new listing origin.

## 8. Removal

A removal names a finalized approved listing case. It copies that case's references
and topics. Only one removal can be open against that target at a time. Approve
on a removal means remove membership; Reject means retain it. Initial unresolved
removal leaves membership unchanged and refunds its submitter. A challenge fallback
uses the standing removal outcome. Terminal resolution releases the target's open
removal slot. None of these operations deletes Swarm bytes.

## 9. Client interfaces and events

Public readers include `caseInfo`, `topicsOf`, `voteOf`, `pairScheduleOf`,
`refundOwed`, `shareOf` and the index's membership/page methods.
`challengeIntentVersion()` returns 1. `outcomeRecoveryOf(caseId)` returns
`(uint8 version, bytes32 originalHash, uint256 recoverUntil, bool expired)`.
Version is 1. `originalHash` is the current round's cached hash, or zero if none
is cached. `recoverUntil` is the original target plus 8,191, or zero if no target
exists. `expired` records completed terminal expiry, not merely an old target.
The round (`challenges`) and original target (`outcomeSeedBlock`) come separately
from `caseInfo`.

Moderator and Publisher read both responses with the same canonical block-hash
pin (`blockHash`, `requireCanonical: true`) and recheck that source block before
accepting the evidence. The shared decoder checks the recovery boundary against
the case target and rejects inconsistent expiry/cache state. An unavailable or
invalid response supplies no expiry authority. Clients authenticate the runtime
before using these capability responses; a marker by itself does not identify
a contract.

`PhaseChanged` records the actual previous and new phase. Case opening reports
`NONE → COMMIT_A`; challenge opening reports `CHALLENGE → COMMIT_A`.
`OutcomeDrawArmed`, `OutcomeHashCached` and `OutcomeDrawExpired` describe distinct
operations. Expiry reports the fallback and terminal phase, not a new
`PreliminaryOutcome`. Case, vote, finalization, claim, refund and index events
provide public history for clients.

Wallet requests bind the selected account, chain, deployment and exact operation.
Private-vote recovery and public transaction recovery are separate client duties.
Reveal clients check finalized/latest state and inclusion time twice before
sending the secret. See [architecture](../docs/ARCHITECTURE.md) and the
[transaction/trust model](../docs/SECURITY_AND_OPERATING_BASIS.md).

## 10. Protocol boundaries

### 10.1 Addresses and participation

An address is a voting identity, not proof of a unique person. One person can fund
multiple stakes. The selection threshold uses the count at case opening but does
not forbid later staking or make the eligible set a permanent roster.

### 10.2 Judgment and outcomes

The contract calculates outcomes from votes; it does not observe whether content
is objectively correct or safe. A reward means agreement with the final outcome,
not an independent truth assessment or a guarantee of profitability.

### 10.3 Frozen stakes and identity rotation

A frozen address cannot withdraw its stake during the freeze. Its owner can still
fund a different address with another stake. The cost is additional capital tied
up, not a system-wide ban on that person. Outstanding votes must be settled before
an address can withdraw even after its freeze ends.

## 11. Deployment parameters

Deployments choose their token, fixed stake, commit/reveal/challenge periods,
maximum wait for the third commitment, freeze duration, minimum reveals, positive
seed lag, fee floor and guidelines identity. The contract constants cap topics at
five and challenges at two. The [release entry](../docs/releases/TESTNET_MVP.md)
records the Chiado values; another deployment must publish its own.

The [operator guide](../docs/OPERATORS.md) covers configuration and storage. The
[transaction/trust model](../docs/SECURITY_AND_OPERATING_BASIS.md) explains RPC,
finality, disclosure and progress assumptions.
