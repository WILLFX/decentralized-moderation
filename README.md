# Decentralized Moderation

*A staking-based moderation market and safe-search index for
[Swarm](https://www.ethswarm.org/), governed entirely by a smart contract.*

Publishers pay a fee to have content judged. Staked moderators judge it, hidden
from each other, in a Schelling game against published guidelines. Content that
passes is recorded in an on-chain, topic-indexed registry that anyone can build a
search application over — with no company in the middle.

**Normative:** [`specs/protocol.md`](specs/protocol.md). Where anything here
disagrees with it, the spec wins.

> **Status.** The three contracts implement the protocol. 91 tests, mutation
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
  │      each committee must finish with >= 3 REVEALED votes, or no outcome
  ├── 3 tickets on the COMBINED tally → preliminary outcome, published
  └── 1 hour challenge window
        challenged? → committees C and D on the same pattern, tickets drawn
        AFRESH over the whole pool. At most two challenges.
```

Three properties carry the design.

**Committee B is unknowable while A commits.** Its seed is a block height armed
only when A's commit phase closes, so nobody deciding whether to commit in A can
see who else will review the case.

**Neither committee sees the other's votes.** Both reveal in one phase, so B
commits with no tally to follow. Payment is for coherence with the outcome, so a
visible tally would make following it more profitable than judging.

**Each committee must produce evidence, not just attendance.** A round draws no
outcome unless both committees finish with at least `MIN_REVEALS` *revealed* votes.
Counted on reveals rather than commits on purpose: a commit floor is cleared by
committing the required number and then revealing only what helps, and withholding
would otherwise be free. Per committee rather than combined, because 40 reveals in
A and one in B is not two committees.

A first round that misses the floor is **unresolved and the fee refunded** — the
publisher paid for a judgment that never happened. A *challenge* round that misses
it lets the standing outcome **finalize** instead, because voiding the case there
would let any challenger destroy a decided case by challenging and bringing nobody.

Three commitments **start a clock**. They are not a quorum; what makes a tally
sufficient is the floor above.

## 5. The outcome

Three tickets are drawn against the combined tally of every committee that
revealed; the outcome is the majority of the three. Tickets are drawn **fresh at
each preliminary outcome**, so retry is bounded by the challenge cap rather than
by reusing one draw.

A challenge is a **public vote opposite** the published outcome — you cannot
challenge an Approve by approving. It counts once and carries the ordinary
liability.

The estimator fed to the tickets is the **raw share `A/N`**. The Laplace form
`(A+1)/(N+2)` was considered and rejected on measurement: against a clique holding a
unanimous tally of 3 it buys about 1.12 fees, which is nothing to an attacker whose
prize is external, while inflicting a wrong outcome on 10.4% of honest unanimous
tallies of the same size. It sees only `(A, N)`, so it cannot tell a thin attacker
tally from a thin honest one — and in a quiet registry both are thin.

**No money moves before finalization.** At it, every moderator coherent with the
outcome claims a share of the fee; every incoherent one is frozen — **and so is
anyone who committed and never revealed**, for the same duration, so withholding is
never cheaper than being wrong.

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

`specs/protocol.md` §11 is the list. Two items are worth stating here because
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

**`MIN_REVEALS` is set, but conditionally.** Each committee must finish a round
with at least 3 *revealed* votes or no outcome is drawn (spec §4.4). Counted on
reveals rather than commits, because a commit floor is cleared by committing and
then withholding. `simulation/FINDINGS-floor-price.md` prices it: 0.9% of cases
unresolvable at 20% turnout, against roughly 96 identities an attacker must hold
instead of 3. **Below about 10% turnout no value works** — a floor of 3 leaves 28%
of cases unresolvable there. Turnout is unmeasured, so the number is defensible at
the participation this design needs anyway and bad below it.

**The floor did not make capture impossible, and the tests say so.** A clique that
fields 3 revealing identities in *each* committee still takes a unanimous case with
certainty, because the estimator is the raw share.
`contracts/test/ThreeVote.t.sol` pins both halves: the old three-identity attack is
dead, and the priced-up version still works. What changed is the cost, not the
possibility.

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
