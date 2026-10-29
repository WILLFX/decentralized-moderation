# Security and operating basis

This document states current source assumptions and unresolved failure modes.
It is not a security audit or a claim that a public network meets these assumptions.
The protocol specification remains normative.

## Timing, entropy and availability

Scheduling assumes the approved minimum five-second timestamp step. B needs exact
historical block hashes from the EIP-2935 service at the selected target. Missing
blocks, unavailable history and delayed calls can prevent progress. A positive
seed lag gives lookahead; it does not establish finality. Validate timestamp,
history and RPC behavior on the intended network before public deployment.

A retains the 250-block eligibility horizon. An armed outcome target cannot be
replaced. Outcome recovery uses its round-scoped cache, BLOCKHASH through age 256,
or the original target's EIP-2935 hash through age 8,191 inclusive. A cached original
remains drawable after that window. The boundary is based on chain height, not a
failed RPC/history read. The source follows the [EIP-2935 history window](https://eips.ethereum.org/EIPS/eip-2935).

Beyond target + 8,191, an uncached armed draw can terminate: initial expiry is
unresolved/refundable; either challenge expiry finalizes the last completed outcome
with ordinary pooled settlement. Non-reveal penalties remain. Outcome-based freezes
against a preserved fallback do not prove wrongdoing or responsibility for draw
failure. Permissionless recovery still needs a caller, gas and inclusion; the new
terminal exit releases fee/refund and vote settlement paths, not automatic payments.
Cached state survives only on the canonical chain. Older immutable deployments
still have their original stranded-case risk; client updates cannot repair them.

## Eligibility and participation

The pinned staked-address count determines N-4 eligibility difficulty. Membership
is checked when committing; there is no case-opening admission cutoff. Once a seed
is known, an actor can search for passing addresses and then fund and stake them.
The pinned denominator does not prevent that attack. Raw block hashes also retain
block-producer influence. These mechanisms do not establish secure Sybil-resistant
sampling by themselves.

Floor three is a development parameter, not measured turnout assurance. Case-wide
address exclusion reduces the population available to later committees. At least
six distinct participants are necessary for an initial successful round; thirteen
and twenty are necessary for one and two successful challenges respectively.
These counts are not sufficient population recommendations. Older N-5 simulation
rates do not apply to the adopted N-4 rule. Turnout, capture cost, stake, fees and
freeze periods need current calibration.

## Reorganisation and secret disclosure

An entropy cache and vote lock persist only on the surviving chain branch. A
reorganisation can remove both. A reveal exposes information even if its
transaction is later removed. Successful transaction inclusion alone does not
make disclosure safe against a replacement branch that still accepts commitments.

The Rust reveal guard requires finalized and latest state, with the finalized
execution timestamp at or after the effective pair close. Reads must identify the
same intended deployment, case, round, vote and schedule, using canonical hash
pinning. The guard also checks real wall time, request duration, head freshness
and remaining inclusion budget before disclosure, including a second check after
wallet reads. Missing evidence fails closed. These checks depend on a trustworthy
finality source and correct local time; an RPC finalized label or two endpoints
owned by one provider do not independently authenticate consensus.

Delayed finality, RPC outages or a stale local clock can prevent an otherwise valid
reveal. The guard cannot guarantee inclusion before the reveal deadline. Do not
weaken it or extend deadlines to make an acceptance test pass.

## Advancement and incentives

Third-A commitment scheduling and first-B activation place extra work and gas on
those voters without separate payment. Other phase advancement remains permissionless
and unpaid. Permissionless availability does not guarantee a timely caller. No
keeper funding policy is implemented. An initial full publisher refund and an
unconditional bounty from the same fee would double-allocate that fee.

## Verification and deployment limits

Successful source checks do not establish these economic or network assumptions.
The full human Rust guarded reveal, outcome draw, finalization and reward settlement
acceptance flow still needs completion. Unresolved-case settlement and refund do
not pass it. Fresh target-network validation, operational recovery policy and
independent security review remain required before public use with material funds.
See [implementation status](STATUS.md) for other outstanding acceptance work.
