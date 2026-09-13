# Decentralized Moderation

*A staking-based moderation market and safe-search index for
[Swarm](https://www.ethswarm.org/), governed entirely by a smart contract.*

Publishers pay a fee to have content judged. Staked moderators judge it, hidden
from each other, in a Schelling game against published guidelines. Content that
passes is recorded in an on-chain, topic-indexed registry that anyone can build a
search application over — with no company in the middle.

**Normative:** [`specs/protocol.md`](specs/protocol.md). Where anything here
disagrees with it, the spec wins.

> **Status.** The three contracts implement the protocol. 81 tests, mutation
> testing, a two-implementation differential on the verdict draw. **Nothing is
> deployed, nothing has been externally reviewed, and §11 of the spec lists
> parameters that have no value yet** — including `prior`, which decides whether
> any of this works at all.

---

## 1. Why this exists

Swarm feeds make permissionless publishing trivial: anyone who knows a string can
derive the same feed key, so anyone can write and anyone can read. Commenting,
blogging and annotation on top of any subject, with no user registry, no server,
no operator.

The flip side is that anyone can write anything. Centralized platforms answer
this by employing moderators out of a corporate budget. A decentralized system
has no corporation and no budget, and unmoderated feeds are unusable for ordinary
applications.

What is missing is a mechanism where **the people who want to publish pay a group
anyone can join** to certify that content is safe and honestly described. That
turns moderation from a cost centre into open, paid work requiring nothing but a
contract — and its by-product is something the decentralized web lacks entirely:
**safe search**.

## 2. Moderators

A moderator stakes a **fixed amount**. Every stake is the same size; influence is
bought by running more identities, each paying its own stake, never by staking
more.

**Concurrency is unlimited.** Nothing is reserved per case and nothing is locked.
A moderator may be voting in as many cases at once as they choose.

**The only penalty is a freeze.** A vote incoherent with the outcome adds a fixed
duration to the moderator's total frozen time. Durations are *additive to a
running total*, so the same losses cost the same whatever order they settle in. A
frozen moderator is eligible for nothing until it elapses.

**The stake is never taken.** Not slashed, not redistributed, not transferred to
another moderator. Time is the only currency of penalty, and a frozen stake is
idle rather than gone.

## 3. Eligibility

For each case and each committee, a moderator is eligible when

```
hash( case , moderator , R )   has at least   N − 5   leading zero bits
```

with `N` set so the registry lies in `[2^N, 2^(N+1))`. So the committee falls out
of the rule rather than being chosen — between 32 and 64 by construction.

Eligibility creates **no obligation**. A moderator who is eligible and does
nothing suffers nothing; there is no no-show penalty anywhere. It is publicly
computable: anyone can find their own eligible identities once `R` exists.

## 4. A case

```
submit
  │  R_A = a FUTURE block at submission
  ├── committee A commits          closes 15 min after the 3rd commit
  │  R_B armed only when A closes
  ├── committee B commits          closes 15 min after the 3rd commit
  ├── A and B reveal together      30 min
  ├── 3 tickets on the COMBINED tally → preliminary outcome, published
  └── 1 hour challenge window
        challenged? → committees C and D on the same pattern, tickets drawn
        AFRESH over the whole pool. At most two challenges.
```

Two properties carry the design.

**Committee B is unknowable while A commits.** Its seed is a block height armed
only when A's commit phase closes, so nobody deciding whether to commit in A can
see who else will review the case.

**Neither committee sees the other's votes.** Both reveal in one phase, so B
commits with no tally to follow. Payment is for coherence with the outcome, so a
visible tally would make following it more profitable than judging.

Three commitments **start a clock**. They are not a quorum and do not by
themselves make a tally sufficient — see §7.

## 5. The outcome

Three tickets are drawn against the combined tally of every committee that
revealed; the outcome is the majority of the three. Tickets are drawn **fresh at
each preliminary outcome**, so retry is bounded by the challenge cap rather than
by reusing one draw.

A challenge is a **public vote opposite** the published outcome — you cannot
challenge an Approve by approving. It counts once and carries the ordinary
liability.

**No money moves before finalization.** At it, every moderator coherent with the
outcome claims a share of the fee; every incoherent one is frozen.

## 6. The index

A finalized Approve writes the content hash, the metadata hash, the topics and
the tally. Two facts are recorded beside it rather than compressed into a label:
whether the draw was **unanimous**, and whether the entry was ever
**challenged**.

**There is no `SUPER_SAFE` flag.** A client wanting a cautious filter reads those
and applies its own rule. The protocol does not decide what "safe enough" means
on a reader's behalf, and a client wanting a different bar does not need the
protocol changed.

A removal targets a listed entry and runs through the same engine — same
committees, same staging, same tickets. **Approve means remove.** The fee is paid
whichever way it goes, so a speculative removal costs its submitter every time.

## 7. What is open, and what it means

`specs/protocol.md` §11 is the list. Three items are worth stating here because
they are not cosmetic.

**`prior` — how often a moderator's judgment matches the truth — is unmeasured,
and it decides everything.** `simulation/FINDINGS-floor.md` derives the condition
exactly: safe and unsafe content are distinguishable only when

```
prior  >  ( 1 + q/(1−q) ) / 2
```

At a 30% attacker share that is `prior > 0.714`. Below it, a revealed vote is
*more* likely to be Approve on unsafe content than on safe content — the tally is
anti-correlated with the truth, and **no rule over it separates them**: not the
lottery, not a threshold, not unanimity, at any cohort size. A testnet is the
instrument (`measurement/prior/`).

**Three identities can take a case with certainty.** `A/N` makes a unanimous
tally certain, three commits are explicitly not a quorum, and nothing requires
committee B to hold anybody. `contracts/test/ThreeVote.t.sol` pins it at 40 of
40. The fix is §11's per-committee minimum, priced in
`simulation/FINDINGS-floor-price.md`: it works, and it costs most in exactly the
low-turnout conditions that make the attack possible.

**A non-reveal costs nothing.** Reveals are public transactions in a shared
phase, so a moderator can watch the tally form and withhold if they would be
incoherent. §11 says this needs a price; there is no mechanism yet.

## 8. Layout

| | |
|---|---|
| `specs/protocol.md` | normative, and the only design document |
| `contracts/` | the three contracts, tests, mutation harness |
| `simulation/` | the measurements, each with its findings |
| `measurement/prior/` | how `prior` gets measured, and why a testnet is the instrument |
| `MODERATION_GUIDELINES.md` | what moderators are actually judging |

Earlier architectures and the full design history are on the
**`archive/v1-v2-and-design-history`** branch. They are not here because a reader
cannot tell which of three state machines is the system.

## 9. Standing constraint

**No deployment with material funds, and the index is not presented as reliable
safe-search certification, until `prior` is measured and an independent review of
the contracts passes against a named commit.**
