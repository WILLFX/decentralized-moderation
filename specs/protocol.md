# Moderation Protocol — Specification

**Status: under development.** This document records the baseline and explicitly
adopted revisions, not completion of the whole paired-committee milestone.
Production code now contains vote-carried B scheduling and the approved smaller
eligibility rule. Remaining progress economics and operational requirements are
not settled by those implementations. See the
[implementation status](../docs/STATUS.md).

The baseline rules below remain the reference until explicitly revised. Code and
passing tests are evidence of current behavior, not proof that all agreed
requirements are implemented. §10 records known differences and unfinished work;
it is not an exhaustive correctness claim.

**17 October eligibility revision:** the user approved N-4 with the existing
staked-count snapshot, three reveals per committee, membership and all other
rules unchanged. The agreed user-run WSL verification passes 231 distinct
Solidity tests, three Python tests, fresh vector comparison and both existing
harness-based local integrations. See implementation status for evidence and
scope. The 228-test result below is the earlier scheduling checkpoint.

**17 October scheduling revision:** the user approved fallback scheduling with
one third-commit revision and the Gnosis/Chiado history/timing basis. The rules
in §4.1 below record that bounded change. Its production source and tests are
written and the agreed regression sequence passed in user-run WSL output on
17 October: 228 distinct Solidity tests and two existing harness-based local
integrations. See implementation status for scope. Other experimental policies
are not adopted by this revision.

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
hash( c , m , R_k )   has at least   max(N − 4, 0)   leading zero bits
```

where `N = floor(log2(max(S,1)))` and S is the total staked-address count at case
opening. The threshold is pinned for the whole case, including both challenges;
new stakes, withdrawals and freeze changes do not recalculate it. A commitment
still requires its sender to be staked and non-frozen at that time. `R_k` is the
randomness for that committee (§4). No new admission cutoff is introduced.

For S at least 16, expected raw eligibility is 16 to fewer than 32 addresses per
committee before freezes, participation and used-address exclusions. Below 32,
every address passes the lottery; the clamp prevents negative bit counts. At
1,000 staked addresses the expected raw count is 31.25 rather than the previous
62.5. These are expectations, not fixed committee sizes or guaranteed reveals.

Eligibility creates **no obligation**. A moderator who is eligible and does
nothing suffers nothing. There is no no-show penalty anywhere in this design.

Eligibility is publicly computable: anyone can determine their own eligible
identities as soon as `R_k` exists.

## 4. The case lifecycle

### 4.1 First outcome

```
submit
  │   R₁ = future execution block hash scheduled at submission
  ├── committee 1 eligible, commits
  │     closes 15 minutes after the 3rd commit
  │
  │   R₂ = scheduled future hash, cached by the first valid committee 2 vote
  ├── committee 2 eligible, commits
  │     closes 15 minutes after the 3rd commit
  │
  ├── committees 1 and 2 reveal together — 30 minutes
  │
  └── 3 tickets drawn against the combined tally
      → PRELIMINARY OUTCOME
```

**Committee 2's target is fixed before its hash exists.** Each pair opens with a
fallback future target. Only the third valid committee 1 commitment may revise
it, once, while the fallback and replacement targets are still future and unused.
Under the approved minimum five-second block timestamp-step assumption, the
target hash arrives after committee 1's last admissible commitment. The target
height is public; the hash is not yet available. This does not establish producer
impartiality or finality.

Let M be `maxWaitForThird`, W be `commitWindow`, and g be `seedLag` (positive).
At pair opening `(b0,t0)`, set A's deadline to `t0+M`, B's deadline to `t0+2M`,
and B's fallback target to `b0+ceil(M/5)+g`. The third valid A commitment at
`(b3,t3)` sets these to `t3+W`, `t3+W+M`, and `b3+ceil(W/5)+g`, respectively.
The fourth and later A commitments change none of them.

At A's deadline, `commit` routes to committee B without requiring a separate
`closeCommitA` transaction. The first valid B commitment reads the exact target
from the EIP-2935 history contract and caches it atomically with the vote.
History ages 1 through 8,191 are accepted; absent, malformed, zero or expired
history rejects entry. Invalid or ineligible commits do not cache a hash, record
a vote, or activate B. Eligibility views do not change state. Later B votes use
the cached hash, including after its history entry expires.

The first two B commitments keep its scheduled deadline. Its third valid commit
sets the deadline to that transaction's timestamp plus W, as in the existing
third-commit clock. Later commitments cannot move it. No commitment is accepted
at or after its committee's effective deadline. `pairScheduleOf` exposes both
deadlines, the cached B hash and the revision flag. Stored phase may remain
`COMMIT_A` during B's logical admission interval until an accepted vote or an
optional close call synchronizes it.

`closeCommitA` remains an optional phase synchronization call. It cannot select
a hash or restart B's clock. If nobody activates B, `closeCommitB` is callable
from either stored commit phase after B's deadline. It still opens a full reveal
window at the caller's timestamp. Missing history does not select a replacement
target or extend B's admission window; insufficient B reveals follow §4.4.
Initial zero-A failure remains callable at A's deadline through `closeCommitA`.

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

A challenge must be bound at execution to the round and preliminary outcome the
caller reviewed. `challenge(caseId, expectedRound, expectedPreliminary)` checks
both before recording a vote or changing any tally, liability or phase. The
expected round is the current round before the challenge increments it; the
public opposing vote belongs to that reviewed round. Only Approve or Reject is a
valid expected preliminary outcome. A mismatch rejects the whole transaction.
The old `challenge(caseId)` entry point rejects; it cannot infer intent from the
state at mining time. This interface change applies to new deployments. A client
must authenticate the runtime and check the supported interface; a version marker
alone is not evidence of correct contract code.

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

### 4.3.1 Original outcome-hash recovery and expiry

Closing a sufficient reveal phase arms one future outcome target. It emits
`OutcomeDrawArmed`, not a transition to CHALLENGE: the stored phase remains REVEAL
until the draw succeeds. The target cannot be replaced or rearmed within a round.

`draw` and permissionless `cacheOutcome` use only that original target's hash.
They use an existing round-scoped cache first, then the execution block hash
through age 256, then the fixed EIP-2935 history contract through age 8,191
inclusive. No caller supplies a hash. Caching emits `OutcomeHashCached` and moves
no fee. A cached original hash remains drawable indefinitely, including after the
history window closes. Each challenge has its own cache; an earlier round's hash
cannot supply a later draw. The draw algorithm and pooled tally are unchanged.

The recovery boundary is on chain: `block.number > target + 8191`, with no
original hash in that round's cache. Before that boundary, an absent, zero,
malformed or reverting history read only prevents recovery; it never enables
terminal expiry. `expireOutcome(caseId, expectedRound, expectedTarget)` binds the
reviewed round and original target, and only succeeds in the armed REVEAL phase
beyond the boundary with no cache. No replacement draw, replacement seed or new
challenge window is created by expiry.

- Initial round: UNRESOLVED, full submission fee withdrawable by its submitter.
  Revealed votes receive no reward or outcome-based freeze; non-reveal penalties
  remain. Each vote still needs one permissionless settlement to release its
  open-vote count.
- Either challenge round: FINALIZED against the last completed outcome. Ordinary
  pooled settlement applies to all recorded votes, including the initiating public
  challenger (whose stored round is the reviewed earlier round). Coherent revealers
  share the original fee; contrary votes and non-revealers receive the configured
  freeze. There is no publisher refund. Integer-division dust remains in contract.

**Settlement against the fallback outcome does not prove participant wrongdoing
or responsibility for the failure to draw.** It is the adopted responsibility
rule, not a finding of misconduct. No new challenger bond, slashing rule or fee
is introduced.

Both terminal paths release an open REMOVE slot. An initial unresolved removal
leaves the listing unchanged; challenge expiry applies the standing removal
outcome. `OutcomeDrawExpired` identifies case, round, original target, fallback
outcome and terminal phase. `PhaseChanged` reports actual stored transitions.
Expiry never emits a fabricated new `PreliminaryOutcome`. Monetary claims remain
pull-based, exactly once per vote; refunds are withdrawable exactly once.

Clients authenticate the deployment runtime and read version-1
`outcomeRecoveryOf(caseId)` at the same canonical block as the case. Unknown or
failed capability reads cannot enable expiry. An uncached boundary read is not
an estimate in minutes; transaction inclusion may miss the last recovery block.
After expiry the interface identifies the fallback and its settlement effect.
Legacy immutable deployments do not acquire recovery from a new client build.

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

- **whether all three tickets were Approve** — unanimity of the draw, not of the
  tally;
- **whether the entry was ever challenged.**

**On the second: earlier drafts of this section called an unchallenged entry
"anonymous". That word is retired rather than defined.** Nothing here is anonymous —
every stake, commitment, revealed vote and fee payment is on chain, and a label
suggesting otherwise would mislead a reader about the one thing §7 exists to avoid
deciding for them. What the fact records is narrower and worth stating directly.

A challenge is the only act in this protocol where an identity **volunteers** a
position against a published outcome. Every other vote is the discharge of a
commitment made blind, before the voter could know what they were agreeing or
disagreeing with. So a challenged entry carries a named, deliberate objection on
record forever, and an unchallenged one does not.

Read it with its limit: a challenge carries the ordinary freeze liability (§6), so
the absence of one is partly the absence of appetite for that liability and not
proof that nobody doubted the entry. It is evidence about what somebody was willing
to stake, which is a different and smaller thing than evidence about the content.

There is no `SUPER_SAFE` flag. A client that wants a stricter filter reads these
facts and applies its own rule; the protocol does not decide what "safe enough"
means on a client's behalf.

## 8. Removal

A removal case targets an entry already listed and runs through the same engine,
the same committees, the same tickets. Approve means remove.

For a finalized removal, the fee is spent whether the result removes the
listing or keeps it listed. If the initial round produces no outcome and the
case becomes unresolved, the existing §4.4 refund path also applies to removal.
This describes the current contract behavior; no separate removal-refund rule
is introduced here.

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

The source contains portions of this baseline design. The list below records known
differences; it does not certify the design or implementation as complete.

### 10.1 Specified here, not implemented

The revised C1+C2 milestone remains under development:

- The user-approved smaller eligibility rule is now `max(N - 4, 0)` in source
  and §3. The recorded N-4 regression sequence passes. The per-committee
  three-reveal floor is retained; smaller raw eligibility can increase floor
  failures when participation is low. This is not testnet turnout calibration.
- The 17 October production change moves B scheduling and activation into valid
  voting transactions. No dedicated arm reward is added. First-entry cost,
  willingness to pay and other progress callers remain economic questions;
  implementation of this slice does not establish unconditional progress.
- A challenge must open C3+C4, applying the same revised staging rules. The source
  now resets the fallback schedule, revision flag and B cache for each pair.
  This behavior has passed the recorded regression checks and does not
  complete the revised milestone.

The two entries that stood here — the per-committee minimum and a cost for
non-reveal — are implemented as §4.4 and §6. They were one decision rather than
two: a floor counted on commits is cleared by commitments that are never revealed,
and a free non-reveal lets a moderator kill a case that the floor would otherwise
have resolved. Deciding either alone leaves a hole the other one opens.

### 10.2 Deliberate deviations, marked in the code

| | |
|---|---|
| **staked-count eligibility** | The adopted N-4 rule uses the total STAKED count at case opening, as now stated in §3. Frozen callers are rejected separately. This preserves the existing implementation's denominator and case-wide snapshot; it is not a non-frozen population snapshot. |
| **one vote per case, not per committee** | A moderator eligible for both committees of a round votes in whichever they reach first, and cannot vote twice. §3 does not say which way this should go. At 1,000 staked addresses the adopted N-4 rule uses five bits. Under independent seeds the raw probability of selection in both committees is 1/1024 (about 0.098%) before case-wide vote exclusion. This estimate does not establish participation or reveal-floor success. |
| **entropy and timing basis** | A retains the 250-block eligibility horizon. Outcome targets use their original hash, round-scoped caching and the exact 8,191-block history recovery boundary (section 4.3.1). B uses exact-target EIP-2935 history and caching. Scheduling assumes the approved Gnosis/Chiado minimum five-second timestamp step. The positive seed lag is lookahead, not a finality rule. Unsupported timing/history environments are outside this implementation basis. |

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
- **`MIN_REVEALS` remains 3 per committee for current development.** The approved
  N-4 change does not lower this floor. Real turnout is unmeasured, and smaller
  raw eligibility can increase unresolved initial cases or failed challenges.
  The older 0.9% and 28% failure figures in `simulation/FINDINGS-floor-price.md`
  concern the larger-committee rule and must not be reused as operating rates
  for N-4. The floor remains a constructor argument; testnet calibration and
  deployment parameters are not decided by this source change.
- **Who decides that a guidelines revision is warranted.** The *binding* is settled
  (§2): the version and hash are immutable, a deployment judges against one text, and
  `script/Deploy.s.sol` refuses a stack whose pin is not the document. What is open is
  the process around a revision — a new deployment is something anyone can make, and
  moderators and clients can decline to use, which may or may not be enough.
- **`prior`** — how often a moderator's judgment matches the truth. Unmeasured,
  and `simulation/FINDINGS-floor.md` shows it decides whether any of this works.

The [security and operating basis](../docs/SECURITY_AND_OPERATING_BASIS.md)
records current trust assumptions, original-hash recovery and expiry obligations,
and the stranded-case risk in older immutable deployments. It does not change protocol rules.
