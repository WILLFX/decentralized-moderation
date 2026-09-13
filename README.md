# Decentralized Moderation

A staking-based moderation market and safe-search index for
[Swarm](https://www.ethswarm.org/), governed entirely by a smart contract.

Publishers pay a fee to have content judged. Staked moderators judge it, hidden from
each other, in a Schelling game against published guidelines. Content that passes is
recorded in an on-chain, topic-indexed registry that any search application can build
on.

[`specs/protocol.md`](specs/protocol.md) is normative. Where this document disagrees
with it, the specification governs.

**Status.** Milestones M1 and M2 are complete; M3 is next (§8). The three contracts
implement the protocol, with 123 tests, a mutation score of 97.0%, and independent
differentials on both the verdict draw and eligibility. Several parameters have no
value yet; §7 lists them.

---

## 1. Purpose

Swarm feeds make permissionless publishing straightforward: anyone who knows a string
can derive the same feed key, so anyone can write and anyone can read. This supports
commenting, blogging and annotation on any subject with no user registry, no server
and no operator.

It also means anyone can write anything. Centralized platforms address this by
employing moderators from a corporate budget. A decentralized system has neither a
corporation nor a budget, and unmoderated feeds are unsuitable for general-purpose
applications.

This project supplies the missing mechanism: publishers pay an open group to certify
that content is safe and honestly described. Moderation becomes paid work that
requires nothing but a contract, and the resulting registry provides safe search for
the decentralized web.

## 2. Moderators

A moderator stakes a fixed amount. Every stake is the same size; influence is acquired
by running additional identities, each paying its own stake, and never by staking more
against one identity.

Concurrency is unlimited. Nothing is reserved per case and nothing is locked, so a
moderator may vote in as many cases at once as they choose.

The only penalty is a freeze. A vote incoherent with the outcome adds a fixed duration
to the moderator's total frozen time. Durations are additive to a running total, so a
given set of losses costs the same regardless of the order in which they settle. A
frozen moderator is eligible for nothing until the total elapses.

The stake itself is never taken — not slashed, not redistributed, not transferred to
another moderator. Time is the only currency of penalty, and a frozen stake is idle
rather than forfeit.

## 3. Eligibility

For each case and each committee, a moderator is eligible when

```
hash( case , moderator , R )   has at least   N − 5   leading zero bits
```

with `N` set so the registry size lies in `[2^N, 2^(N+1))`. Committee size therefore
follows from the rule rather than being chosen, and falls between 32 and 64 by
construction.

Eligibility creates no obligation. A moderator who is eligible and does nothing
suffers nothing; there is no no-show penalty. Eligibility is publicly computable: any
party can determine their own eligible identities once `R` exists.

## 4. Case lifecycle

```
submit
  │  R_A = a future block, fixed at submission
  ├── committee A commits          closes 15 min after the 3rd commit
  │  R_B armed only when A closes
  ├── committee B commits          closes 15 min after the 3rd commit
  ├── A and B reveal together      30 min
  │      each committee must finish with at least MIN_REVEALS revealed votes
  ├── 3 tickets drawn on the combined tally → preliminary outcome, published
  └── 1 hour challenge window
        if challenged: committees C and D on the same pattern, with tickets
        drawn afresh over the whole pool. At most two challenges.
```

Three properties carry the design.

*Committee B is not knowable while A commits.* Its seed is a block height armed only
when A's commit phase closes, so a moderator deciding whether to commit in A cannot
see who else will review the case.

*Neither committee sees the other's votes.* Both reveal in one phase, so B commits
without a tally to follow. Payment is for coherence with the outcome, so a visible
tally would make following it more profitable than judging.

*Each committee must produce evidence, not merely attendance.* A round draws no
outcome unless both committees finish with at least `MIN_REVEALS` revealed votes. The
threshold counts reveals rather than commits: a commit threshold can be cleared by
committing the required number and then revealing only what helps, and withholding
would otherwise be free. It applies per committee rather than in combination, since 40
reveals in A and one in B do not constitute two committees.

A first round that misses the threshold is unresolved and the fee is refunded, the
publisher having paid for a judgment that did not take place. A challenge round that
misses it allows the standing outcome to finalize instead; voiding the case at that
point would allow a challenger to destroy a decided case by challenging and then
bringing nobody.

Three commitments start a clock. They are not a quorum; sufficiency is determined by
the threshold above.

## 5. Outcome determination

Three tickets are drawn against the combined tally of every committee that revealed,
and the outcome is the majority of the three. Tickets are drawn afresh at each
preliminary outcome, so retry is bounded by the challenge cap rather than by reuse of a
single draw.

A challenge is a public vote opposite the published outcome; an Approve cannot be
challenged by approving. It counts once and carries the ordinary liability.

The estimator supplied to the tickets is the raw share `A/N`. The Laplace form
`(A+1)/(N+2)` was evaluated and not adopted. Against a clique holding a unanimous
tally of three it reduces capture probability by an amount worth approximately 1.12
fees, which is not a deterrent to an attacker whose prize lies outside the protocol,
while producing an outcome contradicting every vote in 10.4% of honest unanimous
tallies of the same size. The estimator is a function of `(A, N)` alone and cannot
distinguish a thin attacker tally from a thin honest one; in a low-turnout registry
both are thin.

No funds move before finalization. At finalization each moderator coherent with the
outcome may claim a share of the fee, and each incoherent one is frozen. A moderator
who committed and never revealed is frozen for the same duration, so withholding is
never cheaper than being wrong.

## 6. Index

A finalized Approve writes the content hash, the metadata hash, the declared topics
and the tally. Two further facts are recorded rather than compressed into a label:
whether the draw was unanimous, and whether the entry was ever challenged.

The second warrants a precise reading. A challenge is the only act in the protocol in
which an identity volunteers a position against a published outcome; every other vote
is the discharge of a commitment made blind. A challenged entry therefore carries a
named, deliberate objection on record. A challenge also carries the ordinary freeze
liability, so the absence of one reflects in part an absence of appetite for that
liability rather than an absence of doubt.

There is no `SUPER_SAFE` flag. A client wanting a cautious filter reads the recorded
facts and applies its own rule. The protocol does not determine what "safe enough"
means on a reader's behalf, and a client wanting a different threshold does not
require a protocol change.

A removal targets a listed entry and runs through the same engine: the same
committees, the same staging, the same tickets. On a removal case, Approve means
remove. The fee is paid whichever way the case resolves, so a speculative removal
costs its submitter in every instance.

## 7. Open parameters

`specs/protocol.md` §11 is the authoritative list. Four items are summarized here
because they bear on whether the system can be deployed.

**`prior` is unmeasured.** `prior` is the probability that a moderator's judgment
matches the truth. `simulation/FINDINGS-floor.md` derives the governing condition:
safe and unsafe content are distinguishable only when

```
prior  >  ( 1 + q/(1−q) ) / 2
```

At a 30% attacker share this requires `prior > 0.714`. Below that threshold a revealed
vote is more likely to be Approve on unsafe content than on safe content. The tally is
then anti-correlated with the truth, and no rule over it separates the two cases —
neither the lottery, nor a threshold, nor unanimity, at any cohort size. A testnet is
the measurement instrument; see `measurement/prior/`.

**`MIN_REVEALS` is set conditionally.** Each committee must finish a round with at
least 3 revealed votes or no outcome is drawn (spec §4.4).
`simulation/FINDINGS-floor-price.md` prices this at 0.9% of cases unresolvable given
20% turnout and a 75% reveal rate, against approximately 96 identities an attacker
must hold in place of 3. Below roughly 10% turnout no value satisfies both
requirements: a threshold of 3 leaves 28% of cases unresolvable there. Turnout is
unmeasured, so the current value is defensible at the participation level the design
requires in any case, and unsuitable below it.

**The threshold reduces the cost of capture rather than preventing it.** A clique
fielding 3 revealing identities in each committee still takes a unanimous case with
certainty, because the estimator is the raw share.
`contracts/test/ThreeVote.t.sol` covers both halves: the original three-identity
attack no longer succeeds, and the more expensive form still does.

**The guidelines binding is settled; the process around a revision is not.**
`Moderation` carries the guidelines version and the keccak-256 hash of
`MODERATION_GUIDELINES.md` as immutables, and the deploy script rejects a stack whose
hash is not that document. Every case in a deployment is therefore judged under one
text by construction. The binding is immutable rather than governed because a settable
pointer would allow a party to change the meaning of every open case. The consequence
is that a guidelines revision requires a new deployment, and index continuity across
one is a client concern, consistent with §6.

## 8. Roadmap

**M1 — Specification and simulation. Complete.** The normative specification, the
metadata schema, the guidelines document, and the measurements behind the working
values: `simulation/FINDINGS-floor.md` (the separability bound),
`FINDINGS-staged.md` (staging is neutral with respect to capture), and
`FINDINGS-floor-price.md` (the per-committee threshold priced).

**M2 — Contracts. Complete.** `Moderation`, `StakeRegistry` and `IndexRegistry`, with
a deploy script that verifies its own links. 123 tests across thirteen suites, a
mutation score of 97.0% with each surviving mutant accounted for in the source, and
two independent differentials — on the draw and on eligibility — each of which
verifies that a deliberately broken derivation would be detected.

**M3 — Interfaces. Not started.** In dependency order: the moderator interface, since
without moderators no case is judged; then the submit interface, so publishers can
supply cases; then the search application, which realizes the value of the index.
Delivered through [weeb-3](https://github.com/lat-murmeldjur/weeb-3) rather than as
three standalone applications.

**M4 — Launch.**deployment to Chiado (the Gnosis testnet), then a guarded mainnet launch with
conservative caps.

### Dependency order

The remaining open parameters are measurements rather than decisions. `prior`, turnout
and the reveal rate can only be obtained from a running testnet
(`measurement/prior/`), a testnet requires moderators, and moderators require an
interface:

```
M3 (moderator interface) → testnet → prior, turnout, reveal rate
                                   → MIN_REVEALS, STAKE, FREEZE_PER_LOSS, the fee
                                   → M4 mainnet
```

An independent review is a gate within M4 rather than a separate milestone. It
assesses the contracts and cannot supply a measurement, so nothing downstream of it
proceeds until the measured values exist. Conducting it earlier yields an earlier
answer on the code without shortening the sequence above.

## 9. Repository layout

| | |
|---|---|
| `specs/protocol.md` | normative, and the only design document |
| `contracts/` | the three contracts, tests, and mutation harness |
| `simulation/` | the measurements, each with its findings |
| `measurement/prior/` | how `prior` is measured, and why a testnet is the instrument |
| `MODERATION_GUIDELINES.md` | the standard moderators apply |

## 10. Standing constraint

**No deployment with material funds, and the index is not presented as reliable
safe-search certification, until `prior` is measured and an independent review of
the contracts passes against a named commit.**
