# Design v3 — Challenge-Free Moderation

**Status:** Design. Not specified in `state-machine-*`, not implemented.
**Supersedes:** the challenge architecture of `design-v2.md` §2.4 and §4.6, and the
risk units of revision v2.1. Everything in `design-v2.md` §4 (the payout
derivation) survives and is load-bearing here.
**Provenance:** the confirmation rule and the challenge-free lifecycle are the
senior reviewer's proposal. The costs in §4 and §6, and the decisions in §7 and §8,
are this project's. §10 attributes each.

---

## 1. What changes

The four-day challenge window was **negative assurance**: a case became final
because nobody objected. Silence is weak evidence. It may mean nobody noticed, the
eligible moderators were offline, the interface never surfaced the case, or the
content was expensive to inspect.

The replacement is **positive assurance**: a case finalizes because enough
independently sampled reviewers explicitly reviewed it, committed before seeing any
tally, and the sample was then asked twice.

The four days were never cryptographic. They were a notification budget, and
notification is cheaper bought directly.

```
was:  commit 24h -> reveal 24h -> challenge 4d (-> more rounds)  ~6 days
now:  commit    -> reveal    -> one draw at a fixed block        ~1 hour
```

Nothing here makes the system faster to **correct** — only faster to **decide**.
Correction moves to §8.

## 2. Mechanism

One notified cohort. One commit–reveal round. One hard quorum. One fixed outcome
seed. **Two ballots drawn from the revealed tally, without replacement.**

```
SUBMIT -> COMMIT -> REVEAL -> FINALIZABLE -> one of:

    both tickets Approve   ->  APPROVED
    both tickets Reject    ->  REJECTED
    tickets disagree       ->  CONTESTED
    reveals < MIN_REVEALS  ->  NO_QUORUM
```

All four are terminal. There is no challenge state, no round counter, no
provisional verdict, and no post-draw appeal of the same claim.

Eligibility is unchanged from v2: passive, hash-based, `H(m, c, r, seed) <
threshold`, evaluated off-chain by each moderator. **Submitting a case still
reserves no moderator, locks no stake, and creates no obligation on anyone**
(design-v2 §1, invariant I12). That property is the reason the first architecture
was abandoned and it is not negotiable here.

## 3. The confirmation rule

Let `A` be revealed Approve votes, `R` revealed Reject, `N = A + R`. Two distinct
ballots are sampled uniformly without replacement:

```
P(APPROVED)  = A(A-1) / (N(N-1))
P(REJECTED)  = R(R-1) / (N(N-1))
P(CONTESTED) = 2AR    / (N(N-1))
```

These sum to 1: `A² − A + R² − R + 2AR = (A+R)² − (A+R) = N(N−1)`.

For large `N` with `a = A/N`, they approach `a²`, `(1−a)²` and `2a(1−a)`.

**Implementation needs only the counts**, not the ballots:

```
firstApprove  = H(outcomeSeed, 0) mod N < approve
secondApprove = firstApprove ? H(outcomeSeed, 1) mod (N-1) < (approve - 1)
                             : H(outcomeSeed, 1) mod (N-1) <  approve
```

`MIN_REVEALS ≥ 12` guarantees `N ≥ 2`; the `mod (N−1)` divisor must still be
guarded explicitly, because a revert here leaves a case permanently unfinalizable.

**Why two and not three.** Three-ticket unanimity gives `x³`, but the contested
rate rises to `1 − a³ − (1−a)³`: at `a = 0.95` that is 14.3%, and at `a = 0.70`
it is 63%. The third ticket buys safety the design does not need at a liveness
price it cannot pay.

**Why disagreement must be terminal.** Every way of resolving it destroys the gain:

| Resolution | Hostile result probability |
|---|---|
| Fair coin | `x² + x(1−x) = x` — the entire improvement is gone |
| Another proportional draw | `3x² − 2x³` — majority-of-three; amplifies coalitions |
| Deterministic tally majority | restores the majority control the lottery exists to prevent |

A terminal non-binary outcome is the resource that lets the system cut both false
approval and false rejection without handing certainty to either side.

## 4. What the rule costs, stated with the benefit

The headline gain is real: a hostile share `x` of the revealed tally certifies a
wrong result with probability `x²` instead of `x`.

**The same rule roughly doubles the censorship attack**, because an attacker who
only wants to keep content *out* is served equally well by CONTESTED. Their success
probability is `1 − (1−x)²`:

| hostile share of reveals | one ticket | two tickets |
|---|---|---|
| 5% | 5% | **9.75%** |
| 10% | 10% | **19%** |
| 30% | 30% | **51%** |

And the same doubling appears with no attacker at all. At `a = 0.95` — ordinary
content, one reviewer in twenty dissenting:

```
one ticket:   APPROVED 95%      REJECTED 5%
two tickets:  APPROVED 90.25%   REJECTED 0.25%   CONTESTED 9.5%
```

False rejections fall twentyfold. **Non-certification rises from 5% to 9.75%**, and
for a search index "not certified" and "rejected" are the same outcome to a reader.

> **The honest statement of the mechanism: it converts wrong answers into no
> answer, at roughly two for one.** That is a good trade only if abstention is
> cheap, which is why §8 makes CONTESTED retryable and REJECTED not.

Both numbers belong together wherever either is quoted. `x²` alone overstates the
result.

**At the quorum sizes actually proposed, one dissenter is expensive.** The `a²`
approximation assumes large `N`; `MIN_REVEALS` is 12–16. Exactly:

```
turnout   a single dissenting reveal -> CONTESTED
   N=12                         16.7%
   N=16                         12.5%
   N=20                         10.0%
   N=32                          6.2%
```

So a case that scrapes quorum and draws one dissenter is contested one time in six.
This argues for setting the **expected cohort** well above `MIN_REVEALS` — not for
the safety reasons in §9, but because the contested rate is a function of realized
turnout, and thin turnout makes abstention likely rather than merely possible.

**The cost is a function of the disagreement distribution, which nobody has
measured.** `2a(1−a)` is 9.5% at `a = 0.95` and 2% at `a = 0.99`. The realized
distribution of `a` on ordinary content is the single most valuable measurement a
testnet can produce, and it decides whether this rule is cheap or expensive.

## 5. Payout neutrality survives, exactly

Split the pot into two equal ticket pots, `P/2` each. Each ticket's pot is divided
among the voters coherent with *that ticket*.

The subtlety is that the second ticket is drawn without replacement, so its
direction is not obviously independent of the first. It is, marginally:

```
P(ticket 2 = Approve) = (A/N)·(A-1)/(N-1) + (R/N)·A/(N-1)
                      = A(A-1+R) / (N(N-1))
                      = A(N-1)   / (N(N-1))
                      = A/N
```

So each ticket independently pays an Approve voter `(A/N)·(P/2)/A = P/(2N)`, and a
Reject voter `(R/N)·(P/2)/R = P/(2N)`. Across both tickets every revealer expects
`P/N` whichever way they voted. **The neutrality theorem of design-v2 §4.2 carries
over unchanged**, and with it the linearity corollary of §4.3.

**A consequence that is forced, not chosen.** On CONTESTED, both sides are paid and
neither is penalised — there is no coherent side to penalise. Every alternative
breaks neutrality: withholding pay from the minority makes an Approve voter expect
`AP/N²` and a Reject voter `RP/N²`, which differ unless `A = R`.

Now combine that with §4. A censor voting Reject on good content at `a = 0.95`:

```
APPROVED   90.25%  ->  loses, penalised
REJECTED    0.25%  ->  wins, paid
CONTESTED   9.50%  ->  wins, paid, NOT penalised
```

**97% of a censor's successes arrive through the penalty-free branch.** Censorship
is structurally cheaper than false approval, and the asymmetry is created by
payout neutrality rather than by an oversight. This is the same shape as the
trilemma in design-v2 §4.6: *payout neutrality and a penalty-bearing abstention
state cannot coexist.* §8's retry rule is the mitigation, and it is a mitigation,
not a closure.

## 6. Penalties must commute

Risk units are withdrawn (`v2-audit-checklist.md` §10.1). Removing them reopened
P0-1, P0-4, P0-6 and §4.10 — everything v2.1 closed with per-unit freezing. This
section states what any replacement must satisfy, as properties.

**P1 — penalties commute.** Applying the penalties from a set of settled cases must
give the same result in any order. Per-unit expiry gave this for free; summing
freeze intervals on an identity does not (P0-6: three losses cost 24 days or 19
depending on settlement order).

**P2 — the cost of one loss must not scale with concurrency.** Under identity-wide
freezing the ratio is `freeze_days × cases_currently_open`, which is unbounded when
concurrency is. It was 70 at the pre-v2.1 values, requiring 98.6% confidence
against a 66.5% prior, and it produced **zero honest turnout at every fee from 3 to
300**. It also runs backwards: the more a moderator participates, the more
confidence they need to vote.

**P3 — nothing is reserved at commit.** Capacity may be *priced*; it may not be
*rationed*. This is the constraint the senior reviewer set, and their own analysis
concedes the other half of it: unlimited simultaneous votes and bounded per-case
consequence cannot coexist without some per-case price.

**The proposal that satisfies all three: balance debits against a posted bond.**

```
commit:     require(bond >= MIN + λ · openVoteCount);  openVoteCount++
lost vote:  bond -= d
non-reveal: bond -= d
settle:     openVoteCount--
withdraw:   require(openVoteCount == 0)
```

- **P1** holds because subtraction commutes. Order-independence stops being
  something the design engineers and becomes something arithmetic supplies.
- **P2** holds because a loss costs `d` and a win pays `P/N`, both per case. The
  ratio `d / (P/N)` is a chosen constant. Setting `d = 1.4·P/N` reproduces the
  58.3% confidence threshold that made v2.1 viable — now as a parameter rather
  than as the accidental product of two unrelated quantities.
- **P3** holds because nothing is locked. A moderator with more bond has more
  capacity and there is no ceiling.

**`λ` has a derivation.** Require that *no moderator can ever owe more than they
have posted*. Every open vote can lose at once, so the bond must cover
`d · openVoteCount`, giving **`λ = d`**. The parameter falls out of the property
instead of being guessed.

**Capacity is earned, not bought.** Bond grows from winnings, so honest throughput
compounds while an attacker's collapses as losses debit it.

Open: whether `d` is flat or scales with reputation (that is `v2-audit-triage.md`
D4, unchanged), and how the debited value is disposed of. It must not reach the
opposing voters — that creates punishment farming, and design-v2 §5.5 already
forbids it.

## 7. Every window is fixed at submission

```
outcomeBlock = submissionBlock + FIXED_OFFSET
```

Fixed at submission, and independent of when the last reveal lands, whether the
case was contested, who called the transition, and whether everyone revealed early.
This closes selective realization (P1-2, §4.11) and the last-revealer timing issue
(M2.5-F10). **Lazy re-arming is removed**: if the fixed seed is missed, the case is
VOID. It is never replaced with a fresh future block, which would let a party
inspect a seed and discard it.

The one-hour lifecycle makes this comfortable where the multi-day one did not:
`blockhash` is available for 256 blocks (~51 minutes), and the outcome block sits
well inside that.

**Adaptive windows are rejected, and the reasons are findings.**

*Starting the commit window at the first commit* lets that committer choose the
hour. They can fire the instant the case opens, while honest reviewers are still
fetching content and running inference, or wait for the hour of lowest honest
availability. §9's `x` is the hostile share **of reveals**, so this is not an
attack on the votes — it is an attack on which population votes.

*Ending a phase when everyone has acted* hands the last actor the entropy. The
reveal set is known on chain, so whoever holds the last reveal chooses between
closing now and letting the deadline close it — a free binary choice over seeds:

```
x = 0.30   single fixed seed:  x²          =  9.0%
           choice of two:      1 − (1−x²)² = 17.2%
```

*Detecting that every eligible moderator has voted* is not computable under passive
eligibility. Eligibility is a per-identity hash test over the whole registry, so
completeness requires enumerating the registry. A hash proves membership cheaply;
proving that nobody eligible was omitted means touching the complement.

**The general result: early termination is either useless or unsafe.** Keep the
outcome block fixed and closing early buys nothing, because the draw still waits
for that block. Let the outcome block move with the early close and the last actor
selects the entropy. There is no third option, and an external beacon does not
change it.

**Speed comes from measurement, not adaptivity.** If a testnet shows moderators
commit in 5 minutes and reveal in 2, that is evidence for 5-minute *fixed* windows
— a ~12-minute lifecycle with every property above intact. Adaptivity does not
create speed; it moves the schedule under an attacker's control.

Worth keeping from the adaptive sketch: **permissionless immediate finalization**.
Once the fixed outcome block exists, anyone may finalize in that block, which
removes the finalization grace from the common path without touching a deadline.

## 8. Claims, retry, and correction

Every case carries a permanent claim key:

```
claimKey = H(actionType, contentHash, metadataHash, canonicalTopics, policyVersion)
```

**Terminal states and what they reserve:**

| Result | Claim reservation | Retry |
|---|---|---|
| `APPROVED` | reserved while listed | — |
| `REJECTED` | **permanently reserved** | none under this policy version |
| `CONTESTED` | **not reserved** | after a cooldown, at an escalating nonrecoverable fee |
| `NO_QUORUM` | not reserved | freely — no probabilistic result occurred |

**Why CONTESTED is retryable and REJECTED is not.** CONTESTED is not a finding
against the content; it is the protocol declining to decide. Permanently excluding
content on that basis is the wrong default, and §4 shows it happens to 9.5% of
ordinary content at `a = 0.95`. But retry is exactly the optional-stopping risk the
one-draw rule exists to close, so it must be **priced, not permitted**.

The price discriminates by itself, because the two parties have very different
per-attempt odds:

```
honest publisher, a = 0.95:  P(approve) = 0.9025  ->  1.11 attempts expected
attacker,         x = 0.30:  P(approve) = 0.09    ->  11.1 attempts expected
```

With a fee that escalates geometrically per attempt on the same claim, the honest
publisher pays approximately one fee and the attacker pays a geometric series out
to eleven attempts. **No judgement about whether evidence is "materially new" is
required** — which matters, because that judgement is not mechanizable and a
contract cannot distinguish new evidence from a rephrased loss.

**A policy-version bump must not reopen rejections.** Scoping the reservation to
`policyVersion` as written would make every ruleset change a scheduled amnesty that
an attacker can simply wait for. Rejections persist across versions; only an
explicit re-review case reopens one.

**Correction is a separate claim, not an appeal.** An approved entry may face a
removal case that runs the same engine — commit, reveal, two tickets — producing
`REMOVED`, `RETAINED` or `CONTESTED`. This is a new claim about the current index
entry, not a retry of the original draw. Approvals also carry `validUntil`, after
which cautious clients stop treating them as certified unless renewed.

## 9. Turnout is the variable everything is priced on

`x` is the hostile share **of revealed votes**, not of registered stake. A 30%
registered attacker who is 50% of reveals gets `x² = 25%`, not 9%. Every number in
§3 and §4 is a function of honest turnout inside a short window, and the design
must fail closed: **insufficient participation produces `NO_QUORUM`, never
approval.**

`MIN_REVEALS` rises from 5 to **12–16**. Five reveals were thin while a four-day
challenge window backed them; without one they are indefensible.

Larger cohorts do not reduce the expected hostile share — that is the neutrality
result, and it holds here. They reduce sample variance, reduce whole-cohort capture
probability, and supply enough ballots for two distinct tickets.

**Eligibility widening replaces multi-day extension.** Inside the commit window,
on a schedule fixed when the case opens, the threshold widens monotonically
(`T → 1.5T`) using the same seed. Previously eligible moderators stay eligible, no
keeper transaction is needed, and the widening is uniform across honest and hostile
identities, so it preserves the expected composition. It is fixed rather than
conditional on live commitment counts, which would introduce a race.

## 10. What is open

| # | Question | Owner |
|---|---|---|
| O1 | Portfolio attacks — byte-different substitutes defeat exact claim keys | nobody; deepest open finding (D1) |
| O2 | The censorship asymmetry of §5 — mitigated by §8, not closed | this project |
| O3 | The distribution of `a` on ordinary content — decides §4's cost | testnet |
| O4 | Correlated AI error — `x` counts addresses, not independent judgments (P1-4) | open |
| O5 | Selective reveal under batched commitments — a Merkle root hides its leaf count, so withholding is undetectable | open; §6's debit prices it only if the commit is visible |
| O6 | `d` flat or reputation-scaled (D4) | this project |
| O7 | Guidelines as the Schelling point — one line carries the whole mechanism (5.3) | open |

**The standing constraint is unchanged and this design does not relax it.** No
deployment with material funds, and the index is not presented as reliable
safe-search certification, until the P0 set closes and an independent re-audit
passes against a named commit. A new architecture resets what that re-audit
covers; the four-contract audit does not carry over.

## 11. Attribution

- **Negative → positive assurance, the challenge-free lifecycle, two-ticket
  confirmation, terminal CONTESTED, the three refutations in §3, fixed
  `outcomeBlock`, no lazy re-arming, eligibility widening, claim keys, approval
  expiry, `MIN_REVEALS` 12–16** — the senior reviewer.
- **The cost accounting in §4, the neutrality-forces-penalty-free-CONTESTED result
  in §5, the commuting-penalty properties and bond construction in §6, the
  adaptive-window findings in §7, the retry pricing and policy-version amnesty in
  §8** — this project.
- **Per-unit freezing**, which §6 generalizes into P1, and the risk-unit proposal
  it came from — the external v2 review. The mechanism is withdrawn; the insight
  that penalties must be order-independent is what survives it.
- The payout derivation this document depends on is `design-v2.md` §4, unchanged.
