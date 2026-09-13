# Moderation Protocol — Specification

**Status:** Normative. This is the design. Where anything else in the repository
disagrees with it, this file wins.

**Implemented.** `contracts/src/` implements this document. §10 lists every place
it does not: what is specified here and not built, what deviates deliberately, and
what the code requires that this document does not state.

---

## 1. What the system is

Publishers pay a fee to have content judged. Staked moderators judge it. Content
that passes is recorded in an on-chain, topic-indexed registry that anyone can
build a search application over.

A moderator's judgment is a vote. Votes are hidden until everyone has voted. The
outcome is drawn probabilistically from the tally, so no participant can force a
result. Anyone who disagrees with an outcome can challenge it, which buys another
round of voters whose votes are added to the pool.

## 2. Moderators

**Stake.** A moderator stakes a fixed amount to become active. Every stake is the
same size — there is no weighting by capital. Influence is bought by running more
identities, each costing its own stake.

**Concurrency is unlimited.** A staked moderator may vote in as many cases at the
same time as they choose. Nothing is reserved per case and nothing is locked.

**The only penalty is a freeze.** A vote incoherent with the final outcome adds a
fixed duration to the moderator's total frozen time. Freeze durations are
**additive to a running total**, not extensions from the present moment, so the
same set of losses costs the same regardless of the order they settle in.

A frozen moderator is not eligible for any case until the total elapses.

**The stake is never taken.** It is not slashed, not redistributed, not
transferred to another moderator. Time is the only currency of penalty.

**What they judge against is fixed for the life of the deployment.** A moderator is
paid for coherence with the outcome, and the outcome is other moderators' reading of
`MODERATION_GUIDELINES.md` — so which text is in force is part of what a case means.
The contract carries the guidelines **version and the document's keccak-256 hash as
immutables**: every case in a deployment was judged under exactly one text, by
construction, and anyone can check which.

Immutable rather than governed. A settable pointer means somebody can change what
every open case means, which is a trusted party in a design that has none. The cost
is that **a guidelines revision is a new deployment**; index continuity across one is
a client concern, by the same principle §7 already uses for what an entry means.

| parameter | value |
|---|---|
| `STAKE` | *(open)* |
| `FREEZE_PER_LOSS` | *(open — §11)* |
| `guidelinesVersion`, `guidelinesHash` | immutable, per deployment |

## 3. Eligibility

For a case `c`, moderator `m` is eligible for committee `k` when

```
hash( c , m , R_k )   has at least   N − 5   leading zero bits
```

where `N` is chosen such that the count of non-frozen moderators lies between
`2^N` and `2^(N+1)`, and `R_k` is the randomness for that committee (§4).

Eligibility creates **no obligation**. A moderator who is eligible and does
nothing suffers nothing. There is no no-show penalty anywhere in this design.

Eligibility is publicly computable: anyone can determine their own eligible
identities as soon as `R_k` exists.

## 4. The case lifecycle

### 4.1 First outcome

```
submit
  │   R₁ = randao at submission
  ├── committee 1 eligible, commits
  │     closes 15 minutes after the 3rd commit
  │
  │   R₂ = randomness available after committee 1's last commit
  ├── committee 2 eligible, commits
  │     closes 15 minutes after the 3rd commit
  │
  ├── committees 1 and 2 reveal together — 30 minutes
  │
  └── 3 tickets drawn against the combined tally
      → PRELIMINARY OUTCOME
```

**Committee 2 is not knowable when committee 1 commits.** Its randomness does not
exist until committee 1's commit phase has closed. So a moderator committing in
committee 1 accepts exposure without knowing who else will review the case.

**Neither committee sees the other's votes.** Both reveal in the same phase, so
committee 2 commits without a tally to follow. This is what the staging is for:
payment is for coherence with the outcome, so a visible tally would make following
it more profitable than judging (`simulation/FINDINGS-staged.md` §B).

**The commit clock starts at the third commit, not the first.** Three commitments
start the timer; they are not a quorum and do not by themselves make a tally
sufficient. What makes a tally sufficient is §4.4.

### 4.2 Challenge

The preliminary outcome is published. A **one hour** challenge window follows.

**A challenge is a vote opposite the published outcome.** It is public and it
discloses its direction — you cannot challenge an Approve by approving. The
challenger's vote counts once and carries the ordinary vote liability.

If a challenge is registered:

```
  ├── committee 3 eligible, commits      (15 min from 3rd commit)
  │   R₄ = randomness after committee 3's last commit
  ├── committee 4 eligible, commits      (15 min from 3rd commit)
  ├── committees 3 and 4 reveal together — 30 minutes
  │
  └── 3 tickets drawn afresh against the combined tally of
      committees 1, 2, 3 and 4
      → PRELIMINARY OUTCOME
```

Another one hour challenge window follows. **At most two challenges.**

Committee 4 is unknowable when committee 3 commits, for the same reason committee
2 is unknowable when committee 1 commits.

### 4.3 Finalization

A case finalizes when the last challenge window closes with no challenge, or when
the second challenge has resolved.

**No payout happens before finalization.** Preliminary outcomes move no money.

### 4.4 The per-committee floor

**Each committee of a round must finish with at least `MIN_REVEALS` revealed
votes, or no outcome is drawn for that round.**

It is counted on **reveals**, not on commits, and the distinction is the whole
mechanism. A commit floor can be cleared by committing `k` identities per committee
and then revealing only the ones that help — the withheld commitments would cost
nothing, so the floor would be satisfied without any evidence being produced. A
reveal floor cannot be cleared that way: the `k` votes per committee have to be
exposed, and each one carries the ordinary liability of §6.

It is **per committee and not combined**, for the reason §4.1 already gives: a
combined threshold is cleared by 40 reveals in committee 1 and one in committee 2,
which is not two committees. A healthy committee may not cover for an empty one.

Failing the floor means different things depending on whether anything was decided
yet, and the two are deliberately not symmetric:

- **First round.** No outcome exists, so the case is **unresolved** and the fee is
  refunded. The publisher paid for a judgment that did not happen.
- **Challenge round.** A preliminary outcome already stands, and it **finalizes**.
  Voiding the case here would hand any challenger a way to destroy a decided case
  by challenging and then bringing nobody. The challenge bought two committees, they
  did not materialise, and the challenge failed to produce evidence — so the outcome
  it was challenging stands, and the challenger is frozen under §6 for a vote that
  changed nothing.

**What the floor does and does not buy.** It does not make capture impossible. A
clique that fields `MIN_REVEALS` revealing identities in *each* committee still
decides a unanimous case with certainty, because §5's estimator is the raw share.
What the floor changes is the price: from a handful of identities to roughly
`2 · MIN_REVEALS / P(eligible)` held, all exposed and all liable.
`contracts/test/ThreeVote.t.sol` pins both halves of that, and
`simulation/FINDINGS-floor-price.md` prices it — including the part that is
uncomfortable, which is that the cost falls hardest in exactly the low-turnout
conditions that make capture possible in the first place.

| parameter | value |
|---|---|
| `MIN_REVEALS` | 3 *(conditional — see §11)* |

## 5. The draw

Three tickets are drawn against the combined tally of every committee that has
revealed. The outcome is the majority of the three.

Tickets are drawn **fresh at each preliminary outcome**, over the pool as it
stands. Retry is bounded by the challenge cap rather than by reusing a single
draw.

**The estimator is the raw share `A/N`.** The alternative considered was the
Laplace form `â = (A+1)/(N+2)`, which never returns certainty on a unanimous tally
and so was expected to blunt a thin-tally capture. It was rejected on measurement,
not taste. Against a clique holding a unanimous tally of 3 it lowers capture to
89.6%, worth about 1.12 fees — and against a pay-insensitive attacker whose prize
is external to the protocol, a resubmission fee is not a barrier. On an honest
unanimous tally of the same size it produces an outcome contradicting *every* vote
10.4% of the time. The estimator sees only `(A, N)`; it cannot tell a thin attacker
tally from a thin honest one, and in a quiet registry both are thin. So it charges
the wrong party, and the thin-tally problem is solved structurally by §4.4's floor
instead.

| parameter | value |
|---|---|
| ticket rule | majority of 3 |
| estimator fed to the tickets | raw share `A/N` |

## 6. Settlement

At finalization:

- every moderator whose revealed vote is coherent with the final outcome is paid
  a share of the fee;
- every moderator whose revealed vote is incoherent has `FREEZE_PER_LOSS` added
  to their total frozen time;
- **a moderator who committed and did not reveal has the same `FREEZE_PER_LOSS`
  added.** The amount is forced rather than chosen. Reveals are public
  transactions in a shared phase, so a moderator can watch the tally form and
  withhold if they would be incoherent; if withholding cost less than being wrong,
  anyone expecting to lose would withhold and revealing would be the dominated
  move. Equal makes revealing weakly better, because it keeps the chance of being
  paid.

**A non-revealer is frozen even on a case that reached no outcome** (§4.4). That
is not symmetry for its own sake: an unresolved case is one where a committee
finished below §4.4's floor, so a moderator whose reveal was needed to reach it
could otherwise withhold, have the fee refunded, list nothing, and repeat — which
is censorship at zero cost. A moderator who *did* reveal on an unresolved case is
not frozen and is not paid; there is no outcome to be coherent with.

Settlement is **pull**: each moderator claims their own. No transaction has to
process an unbounded set of participants.

## 7. The index

A finalized Approve writes an entry: the content hash, the metadata hash, the
declared topics, and the tally.

Two facts are recorded alongside every entry rather than being compressed into a
label:

- **whether the entry was anonymous** — an entry that was challenged can never be
  anonymous;
- **whether all three tickets were Approve.**

There is no `SUPER_SAFE` flag. A client that wants a stricter filter reads these
facts and applies its own rule; the protocol does not decide what "safe enough"
means on a client's behalf.

## 8. Removal

A removal case targets an entry already listed and runs through the same engine,
the same committees, the same tickets. Approve means remove.

The fee is paid whether the removal succeeds or fails, so a speculative removal
costs its submitter every time.

## 9. What is deliberately not here

- **No commit quorum.** Three commits start a clock, nothing more. §4.4's floor is
  a gate, but it sits on *revealed* votes at reveal close, not on commitments at
  commit close — a case with three commits opens and runs exactly as before; what it
  cannot do is produce an outcome without evidence. The two are not
  interchangeable, which is §4.4's entire point.
- **No no-show penalty.** Eligibility is an opportunity: a moderator who is
  eligible and never commits owes nothing. §6's freeze is for a moderator who
  *committed* and then withheld, which is a different act.
- **No stake slashing or redistribution.** §2.
- **No vote weighting.** One identity, one vote.
- **No verdict before all voting closes** within a round. §4.1.

## 10. Distance from the current implementation

`contracts/src/` implements this document. What follows is every place it does
not, read from the code rather than assembled from anyone's objections — an
objection list stops wherever the reader stopped.

### 10.1 Specified here, not implemented

Nothing. Every section above has code behind it.

The two entries that stood here — the per-committee minimum and a cost for
non-reveal — are implemented as §4.4 and §6. They were one decision rather than
two: a floor counted on commits is cleared by commitments that are never revealed,
and a free non-reveal lets a moderator kill a case that the floor would otherwise
have resolved. Deciding either alone leaves a hole the other one opens.

### 10.2 Deliberate deviations, marked in the code

| | |
|---|---|
| **eligibility bits** | §3 derives `N` from the count of NON-FROZEN moderators. That count falls and rises with no transaction to observe — a freeze expires on a clock — so it cannot be maintained on chain. `Moderation._eligBits` pins it from the STAKED count, which is exact, and `commit` rejects a frozen caller separately. The threshold sits slightly wide while part of the registry is frozen. |
| **one vote per case, not per committee** | A moderator eligible for both committees of a round votes in whichever they reach first, and cannot vote twice. §3 does not say which way this should go. At the eligibility rates §3 produces the overlap is small — around 0.4% of the registry at 1,000 — so it is not material to §4.4's floor, but it is a choice the document does not make. |

### 10.3 Required by the code, not by this document

A guard the specification does not state and does require: **a moderator with an
unsettled vote cannot withdraw.** If the only penalty is a freeze, committing and
then withdrawing before settlement escapes every penalty the design has, because
there is nothing else to take.

What that guard does *not* close is identity rotation, and nothing here does. A
frozen moderator can leave the frozen stake idle and stake a fresh address, so
escaping a freeze costs one stake tied up for the freeze duration — which is
exactly what serving it costs. **The freeze deters only to the extent capital is
scarce.** `StakeRegistry`'s closing comment states this where a reader of the
contract will hit it.

## 11. Open parameters

Not decided, and each needs a number before deployment.

- `STAKE`, `FREEZE_PER_LOSS`, fee level and its split, and `MAX_WAIT` — the
  longest a case may sit before a third commit arrives. The mechanism exists; the
  durations are placeholders.
- **`MIN_REVEALS`, and it is conditional rather than merely undecided.** §4.4 sets
  it to 3. `simulation/FINDINGS-floor-price.md` prices that at 0.9% of cases
  unresolvable given 20% turnout and a 75% reveal rate, against roughly 96 identities
  an attacker must hold. **Below about 10% turnout no value both stops a small clique
  and leaves ordinary cases resolvable** — at 10% turnout a floor of 3 leaves 28% of
  cases unresolvable. Turnout is unmeasured, so 3 is a defensible choice at the
  participation the design needs anyway and a bad one below it. It is a constructor
  argument, so the testnet can move it without a rewrite.
- **What "anonymous" means** in §7.
- **Who decides that a guidelines revision is warranted.** The *binding* is settled
  (§2): the version and hash are immutable, a deployment judges against one text, and
  `script/Deploy.s.sol` refuses a stack whose pin is not the document. What is open is
  the process around a revision — a new deployment is something anyone can make, and
  moderators and clients can decline to use, which may or may not be enough.
- **`prior`** — how often a moderator's judgment matches the truth. Unmeasured,
  and `simulation/FINDINGS-floor.md` shows it decides whether any of this works.
