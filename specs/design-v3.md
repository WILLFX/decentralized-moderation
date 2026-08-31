# Design v3 — One-Hour Plurality, One Challenge Round

**Status:** Design. Specified normatively in `specs/state-machine-v3.md`; not
implemented. Where the two disagree, the state machine is normative and this
document should be corrected.
**Supersedes:** the challenge architecture of `design-v2.md` §2.4 and §4.6, and the
risk units of revision v2.1. `design-v2.md` §4.2's neutrality theorem is
**no longer a design requirement** (§5); it remains correct and is now the
statement of what this design gives up.
**Revision:** v3.4 — the schedule is denominated in block heights, with the one
wall-clock conversion pinned per case at submission (§7); the previous form
compared a wall-clock deadline against a block-indexed `blockhash` horizon and
drifted apart at 2.7% of block time. v3.3 took the draw against `â = (A+1)/(N+2)`
rather than the sample proportion (§3), which moved every figure in §4 and §8; `CHALLENGE_BOND` is
unconditional and the challenge reserve activates in proportion to round-1 turnout
(§2.1, §5). v3.2 reinstated a 12-hour challenge round (§2.1) so the architecture is
no longer challenge-free, and **the one-hour result is a plurality — a fact about
the votes — not a provisional verdict**; `state-machine-v3` §4.2 withdrew the
provisional draw, because publishing it published `u` and with it the exact cost of
flipping the case. v3.1 replaced two tickets and a terminal `CONTESTED` with three
tickets and a 2-of-3 majority, and deliberately abandoned exact cash neutrality
(§5).
**Provenance:** the confirmation rule and the lifecycle are the senior reviewer's
proposal. The costs in §4 and §5, and the decisions in §7 and §8,
are this project's. §11 attributes each.

---

## 1. What changes

The four-day challenge window was **negative assurance**: a case became final
because nobody objected. Silence is weak evidence. It may mean nobody noticed, the
eligible moderators were offline, the interface never surfaced the case, or the
content was expensive to inspect.

The replacement is **positive assurance**: a case finalizes because enough
independently sampled reviewers explicitly reviewed it, committed before seeing any
tally, and the sample was then interrogated three times.

The four days were never cryptographic. They were a notification budget, and
notification is cheaper bought directly.

```
was:  commit 24h -> reveal 24h -> challenge 4d (-> more rounds)      ~6 days
now:  commit -> reveal -> TALLY, plurality published                ~1 hour
      -> 12h challenge window -> (one challenge round) -> ONE draw   ~12-13 h
```

Every duration above is the human-facing **intent**. The contract schedules in
block heights — 240 / 240 / 8,640 blocks at a 5 s `BLOCK_TIME` — so these figures
track the chain rather than binding it (§7, `state-machine-v3` §0).

**The result is not challenge-free.** An earlier revision of this document was, and
§2.1 records why the window came back: a 2-of-3 majority certifies bad content
22.3% of the time at a hostile 30% of reveals, and a single sealed round has no
mechanism to correct that. The challenge round is the correction, and §2.1 states
exactly what it costs.

What is bought is **speed of decision**, not speed of correction: a usable
interim answer in an hour where the old design gave nothing for six days.

## 2. Mechanism

One notified cohort. One commit–reveal round. One hard quorum. One fixed outcome
seed. **Three ballot-side draws from the revealed tally, with replacement; the
side on two of three is the verdict.**

```
SUBMIT -> COMMIT -> REVEAL -> TALLY -> (§2.1) -> DRAW -> one of:

    two or three tickets Approve  ->  APPROVED
    two or three tickets Reject   ->  REJECTED
    commits < MIN_COMMITS         ->  UNRESOLVED(NO_TURNOUT)
    no reveals at all             ->  UNRESOLVED(NO_REVEALS)
```

**There is no `MIN_REVEALS`.** state-machine-v3 §4.8 removed it rather than
relocating it: a reveal-stage gate selects between terminal classes on state every
revealer can watch, which was the only thing that ever made withholding attractive.
The quorum gate is on *commits*, which are blind. What stops a thin tally from
deciding a case outright is not a floor but the estimator of §3.

There is no `CONTESTED` state and no post-draw appeal. **The first round produces
no verdict at all** — it produces a *plurality*, a fact about the votes, which may
be challenged exactly once (§2.1). The single draw comes after the challenge window
and after round 1 if there is one.

> **Revision note.** An earlier draft of this document used *two* tickets without
> replacement, with disagreement producing a terminal `CONTESTED`. That is
> withdrawn. §5 explains why: the contested branch could not carry a penalty
> without breaking payout neutrality, which made forcing disagreement a censor's
> cheapest attack. Three tickets remove the branch by always producing a verdict.
> The cost is recorded in §4 and §5 rather than absorbed silently.

**Sampling is with replacement, and that is load-bearing.** Drawn without
replacement, a side holding one revealed vote can never occupy two tickets, so a
31–1 tally would decide with *certainty* — violating the rule that no stake
majority buys a risk-free outcome. With replacement the one-vote side still wins
1.0% of the time. Tickets carry no payout entitlement of their own (§5), so
sampling the same ballot twice creates no windfall.

**Replacement is necessary and was mistaken for sufficient.** It removes certainty
from the *sampling*; it leaves it in the *tally*, because a unanimous `A/N` is 1
and `f(1) = 1` whatever the draw does. §3's estimator is what closes that, and a
one-vote case is precisely the tally where the difference is largest.

Eligibility is unchanged from v2: passive, hash-based, `H(m, c, r, seed) <
threshold`, evaluated off-chain by each moderator. **Submitting a case still
reserves no moderator, locks no stake, and creates no obligation on anyone**
(design-v2 §1, invariant I12). That property is the reason the first architecture
was abandoned and it is not negotiable here.

### 2.1 The challenge round

```
hour 0-1    commit, reveal, tally
            -> index writes PLURALITY_APPROVE / PLURALITY_REJECT — which side
               LEADS, a fact about the votes. No randomness has been realized.
            -> NOTHING is paid, nobody is penalised, the pot stays escrowed

hour 1-13   challenge window

  no challenge
            -> at the window's scheduled close the case waits for its outcome
               block and is drawn ONCE (state-machine-v3 §7.2)

  challenge registered (any ACTIVE moderator + CHALLENGE_BOND; no eligibility
  test - state-machine-v3 §3.5)
            -> at the window's SCHEDULED close, not when the challenge landed,
               a second commit-reveal round opens, admitting only eligible
               moderators who did not vote in round 0
            -> tallies POOL: A = A0 + A1, R = R0 + R1
            -> the SAME three tickets are drawn once, from the pooled tally,
               after round 1 closes
            -> one pot to every voter from either round matching the verdict;
               everyone against it is penalised
```

**Both paths reach the same block.** The outcome seed sits after all four windows
whether or not round 1 runs, so an unchallenged case finalizes no earlier than a
challenged one and the observable timing of a case leaks nothing about whether it
was contested (`state-machine-v3` §7.2).

**Exactly one challenge round, and nothing is discarded when it opens.** There is
no round-0 draw to throw away: `state-machine-v3` §4.5 realizes the randomness once,
after all voting. Round-0 votes pool forward; the challenge adds evidence to the
tally the single draw will read.

**A challenge must earn its round — and the floor that was meant to enforce this
is withdrawn.** `MIN_CHALLENGE_REVEALS` is removed (state-machine-v3 §4.6). It was
unsatisfiable exactly when it mattered, judged voters against a tally they were
excluded from, and was a coordination trap. The job is done structurally instead:
**one randomness per claim, realized once after all voting closes**
(`state-machine-v3` §4.5). An unchanged tally yields an identical verdict, so there is no second draw
to buy, and the verdict is monotone in the tally — adding votes can move it only
toward the side that was added. An attacker who lost round 0 at `a₀ = 0.3125` needs
a median of **21** Approve votes to flip it, against **zero** for a 23.2% chance
under a fresh draw.

**Funding: a prefunded, refundable challenge reserve.**

```
submission payment = initial pot + challenge reserve + finalization bounty
                   + nonrecoverable maintenance component

reserve activates in proportion to round-1 turnout, at settlement:
    activated = min( reserve , floor(pot · reveals1 / reveals0) )
    the rest is refunded to the submitter
```

**Not a boolean on "was there a challenge".** `state-machine-v3` §5.3 replaced that:
registering a challenge moved the whole reserve into the pot before anyone had
voted, so a round-0 winner could register purely to enlarge a pot they would share
in, and an empty round paid out a reserve nobody had earned. The reserve exists to
offset the dilution round-1 voters cause, so it pays for the dilution that actually
occurred.

The activated reserve goes to *all* final-verdict voters from both rounds, not to
challenge voters as a class. Without it, opening a challenge raises turnout while
shrinking the per-winner share, which taxes exactly the honest participation the
round exists to attract. The challenger's bond is retained as maintenance funding
and is **never** transferred to the winners — that is punishment farming, forbidden
since design-v2 §5.5. It is debited unconditionally rather than on a "did the
challenge succeed" test: `state-machine-v3` §4.6 records why, and the short version
is that every such test is one the challenger can evaluate before registering, so
it prices the dissenter who cannot predict turnout and exempts the identity-holder
who supplies it.

**Payment for round-1 voters does not depend on which round they voted in**, on
whether their ballot was sampled, or on whether the challenge reversed the result.
A round-1 Reject voter who is vindicated by a reversal is paid identically to a
challenge-round Reject voter.

#### What the challenge round costs

It reintroduces optional stopping, which the challenge-free revision existed to
remove. The party trailing the published plurality is the party who challenges, so a
motivated attacker always buys the second round while an honest side buys it only
when someone notices and pays.

The table below is from the revision in which round 0 *drew* a provisional verdict;
its row labels are that draw, and it is kept because the note under it is the
argument for the rule that replaced it. With 32 round-0 reveals at 30% hostile
(`a = 0.3125`, provisional APPROVED 23.2%), and `h` the probability the honest side
challenges a loss:

```
fresh challenge cohort      pooled a    p₂       h=1.0    h=0.5     h=0
  same composition            0.3125   0.2319   0.2319   0.3210   0.4101
  attacker identity-limited   0.2500   0.1562   0.1562   0.2541   0.3519
  attacker exhausted          0.2083   0.1121   0.0260   0.1290   0.2319
```

> **Superseded by state-machine-v3 §4.5.** The table above assumes a *fresh* draw
> in round 1. Under the adopted single-randomness rule the `h`-dependence largely
> disappears — simulated at 30% hostile, `TARGET_COHORT` 40, honest turnout 0.8:
> false approval runs 0.316 / 0.309 / 0.300 / 0.284 at `h` = 0 / 0.25 / 0.5 / 1.0,
> against 0.483 / 0.434 / 0.383 / 0.285 with a fresh draw. A fresh draw makes the
> challenge round a 20-point gift to an attacker when the honest side is
> unreliable; the same-`u` rule flattens that to 3 points. **O10 is substantially
> defused** — the design no longer hinges on a quantity outside the contract.

**Under a fresh round-1 draw, the round answered §4's false-approval number only
under two conditions**: the honest side challenges reliably (`h → 1`), *and* the
attacker cannot refill the challenge cohort with fresh identities. When both hold, false approval falls from
23.2% to **2.6%** — the best number this design has produced. When neither holds it
rises to **41%**, nearly double the single-round figure.

**So the challenge round widens the range rather than lowering the number**, and
where it lands is decided by honest challenge reliability — which is the *negative
assurance* dependence §1 set out to eliminate. That is not an argument against the
round; it is the statement of what the round is buying with, and it makes `h` a
first-class quantity that the client, the notification path and the fee must all be
designed to raise.

## 3. The confirmation rule

Let `A` be revealed Approve votes, `R` revealed Reject, `N = A + R`. Three ticket
sides are drawn independently, each Approve with probability `â`, and the side
appearing on at least two becomes the verdict:

```
â    = (A + 1) / (N + 2)                            -- NOT A/N; see below
f(â) = P(APPROVED) = 3â² − 2â³      P(REJECTED) = 1 − f(â)
```

**Implementation needs only the counts:**

```
for i in 0..2:  ticket[i] = u[i] · (N + 2)  <  (A + 1) · 2^128
verdict = (ticket[0] + ticket[1] + ticket[2] >= 2) ? Approve : Reject
```

Three hashes and a comparison. No ballot array, no without-replacement bookkeeping,
and no division by `N−1` — the divide-by-zero guard the two-ticket rule needed is
gone with it. **Not `mod (N+2)`**: only the multiplicative form is monotone in the
tally, which is what makes a challenge that adds no votes return an identical
verdict (`state-machine-v3` §4.5, I22).

**Why `â` and not `A/N`.** `f` consumes a *population* Approve rate. `A/N` is a
*sample* proportion of `N` votes, and handing one to the other claims certainty
from `N` observations — at a unanimous tally, exactly: `f(1) = 1`, and one revealed
vote is a unanimous tally. `â` is the posterior mean under a uniform prior, it is
symmetric and parameter-free, and it lies strictly inside `(0,1)` for every finite
`N`.

**`f(â)` is an approximation and this document does not pretend otherwise.** `f` is
non-linear, so `f(E[θ]) ≠ E[f(θ)]`; the exact posterior predictive is
`(A+1)(A+2)(3N−2A+6)/((N+2)(N+3)(N+4))`, and `f(â)` sits above it everywhere but
the tie — 4.1 points at `N = 1`, 0.15 at `N = 34`. The plug-in is what three
independent ticket comparisons compute, which is the rule §11 attributes and the
shape §7's argument is written in, so it is kept and the residual is recorded
rather than absorbed. `state-machine-v3` §4.5 has the table and §10 the decision. **This paragraph replaces a claim that ran the other way**: an earlier revision
said the finite-`N` correction "does not apply, because the tickets are drawn with
replacement." The *sampling* is exact at every `N`. The *tally* is not, and that is
the quantity the sampling is parameterised by.

**`f` is a majority amplifier, and that is the whole of what it buys and costs.**
At a cohort of `N = 34`:

```
tally share A/N   0.51    0.60    0.70    0.80    0.90    0.95
â                0.500   0.583   0.694   0.778   0.889   0.917
f(â)             0.500   0.624   0.777   0.874   0.966   0.980
```

A 51% side wins half the time; a 90% side wins 96.6%. **No outcome is certain, and
now that is true at every tally rather than every tally with votes on both sides**
— but a large coalition still approaches certainty faster than under a linear
lottery. That weakening of "no outcome can be engineered with certainty" is
accepted deliberately (§5). A 31–1 tally leaves the one-vote side 1.0%.

**Why three and not two, and not five.** Two tickets require a rule for
disagreement, and §5 shows every such rule either destroys the safety gain or
creates a penalty-free branch. Five tickets amplify harder — `f₅(0.90) = 99.1%` —
for a marginal gain over three, and each extra ticket steepens the minority
penalty §5 already flags as this design's main risk. Three is the smallest odd
number that always decides.

## 4. What the rule costs, stated with the benefit

Two attacks matter and they pull in opposite directions. `x` is the hostile share
**of revealed votes**.

| | false approval, `x = 0.30` | censorship of good content, `a = 0.95` |
|---|---|---|
| one ticket (linear, v2) | 30% | 5% |
| two tickets + `CONTESTED` (withdrawn) | 9% | 9.75% |
| **three tickets, 2-of-3** | **22.3%** | **1.97%** |

Both figures are at `N = 34`, and both are computed as `f(â)` — the plug-in
estimator of §3, not the exact posterior predictive. **That is part of their
source, not a footnote** (`state-machine-v3` I33): under `E[f(θ)]` the same tallies
give **22.95%** and **2.47%**. The plug-in is kept deliberately and
`state-machine-v3` §4.5 and §10 record why; what must not happen is a later
revision quoting these as exact.

Both also moved when the draw moved to `â` at all: they were 21.6% and 0.725%
against `A/N`. **The censorship number nearly tripled**, and it is the one §8 leans
on hardest — 3.4× under the exact rule.

**Against censorship this is still the strongest rule available** — 1.97% where the
withdrawn two-ticket rule gave 9.75% and a linear draw gave 5%. Amplification
works for the honest majority whenever the honest side *is* the majority.

**Against false approval it is the weakest of the three**, at 22.3% versus 9%. A
hostile 30% of reveals certifies bad content roughly one time in five. That is the
price of removing the abstention branch, and it must be quoted wherever the
censorship number is quoted. **This is the number the challenge round of §2.1
exists to correct**, and it moves to anywhere between 2.6% and 41% depending on how
reliably the honest side challenges.

> **The honest statement of the mechanism: it suppresses minorities in both
> directions.** Good when the minority is an attacker, bad when the minority is
> right. It is one property seen twice, not two properties.

**Everything above is a function of turnout, not of registered stake.** A 30%
registered attacker who is 50% of reveals gets `f(0.5) = 50%`, not 22.3%. §9.

**What is no longer a cost.** The withdrawn rule contested 9.5% of ordinary content
at `a = 0.95`, rising to 16.7% at a bare quorum of 12 — one case in six failing to
certify on a single dissenting reveal. That is gone: false rejection of ordinary
content at `N = 34` is 1.97%.

**But the finite-`N` correction does apply, and this section used to deny it.** The
claim was that `f(a)` is exact at every `N` because the tickets are drawn with
replacement. Replacement makes the *sampling* exact; it says nothing about `a`,
which is a sample proportion standing in for a population rate. So the rule is
still `N`-sensitive, just in the estimator rather than in the draw: at `N = 12` a
0.95 tally gives `â = 12/14 = 0.857` and `f(â) = 0.945`, so 5.5% false rejection
against 1.97% at `N = 34`. **Small cohorts are still worse; they are worse for a
different reason than the two-ticket rule was, and the direction of the effect is
the one that makes it safe to be wrong** — a thin tally now under-claims instead of
over-claiming.

## 5. Payout: exact cash neutrality is deliberately abandoned

**The rule.** The whole pot goes to voters coherent with the **final** verdict,
divided equally, pooled across both rounds. Tickets select the truth; they do not
select who is paid.

```
P = initial pot + activated challenge reserve      (§2.1)
W = votes matching the final verdict, from either round
rewardPerWinner = floor(P / W)
remainder = P − rewardPerWinner · W     -> maintenance reserve, never to moderators
```

Voters against the final verdict receive nothing and take the incoherence penalty
(§6). Four things are irrelevant to both payment and penalty: which round a
moderator voted in, whether their ballot was sampled as a ticket, whether their
side led the round-0 plurality, and whether the challenge reversed it.

**Nothing is paid and nobody is penalised before a terminal state.** The pot stays
escrowed through the challenge window (§2.1), so no coherence is credited against a
verdict that a challenge may replace.

### 5.1 What this costs

`design-v2.md` §4.2 proves that for a fixed tally, equal division among the
coherent side gives every voter `P/N` in expectation **iff** `P(verdict = Approve)
= a`. With `f(a) = 3a² − 2a³ ≠ a`, that fails:

```
E[majority voter] = (P/N)·f(a)/a          E[minority voter] = (P/N)·(1−f(a))/(1−a)

  a      majority pay     minority pay
 0.51      1.010            0.990
 0.60      1.080            0.880
 0.70      1.120            0.720
 0.80      1.120            0.520
 0.90      1.080            0.280
 0.95      1.045            0.145
```

The majority premium peaks at **1.125 × P/N** at `a = 0.75`. The minority's fall is
far steeper than the majority's rise.

**Four properties, at most three.** A three-ticket majority verdict; the whole
constant pot distributed every time; only coherent voters paid; exact
direction-neutral expected cash. `f(a) = a` is required by the fourth and denied by
the first. This design relaxes the fourth.

*A recorded alternative, not adopted.* Relaxing the **third** instead also works:
three ticket pots of `P/3`, each paid to the side its own ticket selected, gives
`E = a·(P/3)/A = P/(3N)` per ticket for an Approve voter and `(1−a)·(P/3)/R =
P/(3N)` for a Reject voter — exact neutrality under an unchanged 2-of-3 verdict,
verified by simulation at 400k trials. It was rejected on the grounds that tickets
should not determine payment, and because the majority premium below is *wanted*.
It is recorded because it is the only known construction combining a majority
verdict with exact neutrality, and because the choice between them was a judgement
about incentives rather than a forced move.

### 5.2 Why the trade is judged worth it

**It makes reading pay.** Under exact neutrality an always-approve bot earned the
same cash as a moderator who read the content; only the penalty separated them.
With a base rate of 90% legitimate submissions:

```
always-approve bot :  0.955 × P/N,  penalised on 9.9% of cases
honest reader      :  1.045 × P/N,  penalised on 0.7% of cases
edge to reading    :  +9.4%          (under exact neutrality: 0.0%)
```

**It removes the safe minority.** Under the withdrawn rule a censor forcing
disagreement was paid half the pot and penalised not at all, because there was no
verdict to be incoherent with — 97% of a censor's successes arrived through that
branch. With a verdict always produced, there is always a penalised side.

**It sharpens the Schelling point.** A moderator is paid for reporting what other
competent moderators converge on, not merely for avoiding obvious error.

### 5.3 The risk this creates, recorded

**The mechanism cannot distinguish deliberate dissent from correct dissent against
a correlated majority.** At `a = 0.95` a dissenter earns `0.145 × P/N` against a
majority voter's `1.045` — 7.2× — *on top of* the incoherence penalty. Where 32
addresses run one model on similar prompts, they are one opinion sampled 32 times,
and the reviewer who spots that model's blind spot is the one paying 7.2×. This
converts O4 from a statistical concern into an economic one. Mitigations already in
this design: the random full-audit floor (§9) and cohort diversity. Neither is
measured. **This is the largest known cost of the payout decision and it should be
the first thing a testnet looks at.**

### 5.4 Consequences elsewhere

- **README principle 4 must be rewritten, not deleted.** Its letter — "a moderator
  is paid the same whichever way the case goes" — is now false. Its *purpose*
  survives: the premium attaches to the **majority**, not to Approve, so no
  rule-level bias toward listing exists. What is new is a **conformity premium**,
  which via base rates leans approve-ward in practice because most submissions are
  legitimate.
- **`design-v2.md` §4.3 stops constraining the design.** Its corollary — that the
  lottery must be linear, `α = 1` being the unique exponent admitting neutrality
  with a constant pot — was binding only while neutrality was required. The design
  is now free to choose any `f`; `3a² − 2a³` is one point in a space that used to
  contain exactly one. Nobody should treat 2-of-3 as forced.
- **The trilemma of `design-v2` §4.6 changes shape.** Neutral payouts forced
  `f(W) = c/W` and a constant total paid. Without neutrality that constraint lifts,
  which reopens challenger-funded rounds as an option (triage D2).

## 6. Penalties must commute

Risk units are withdrawn (`v2-audit-checklist.md` §10.1). Removing them reopened
P0-1, P0-4, P0-6 and `v2-audit-checklist.md` §4.10 — everything v2.1 closed with per-unit freezing. This
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
commit:     require(bond >= MIN + liabilities(m) + λ);  openVoteCount++
            // liabilities(m) covers EVERY claim on bond, not just open votes
            // — state-machine-v3 §2.4, I23
lost vote:  bond -= d
non-reveal: bond -= REVEAL_BOND        // not d — state-machine-v3 §5.2
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

**`FIXED_OFFSET` is a block count, and so is every phase deadline it is compared
against** (`state-machine-v3` §0, I31). This line was always right; the normative
elaboration was not. `state-machine-v3` §7.2 spelled the offset out as
`blockAt(submitTime + windows)` — a wall-clock schedule feeding a block-indexed
`blockhash` — and the two sides then drifted apart at 2.7% of block time, killing
every challenged case. The offset is now derived from the window lengths converted
to blocks **once, at submission**, from a pinned `BLOCK_TIME`.

Worth noting which document was wrong, because the front matter says the state
machine wins where they disagree: here the state machine was the one that broke a
property this document had stated correctly, and it broke it in the act of making
it precise.
This closes selective realization (P1-2, `v2-audit-checklist.md` §4.11) and the last-revealer timing issue
(M2.5-F10). **Lazy re-arming is removed**: if the fixed seed is missed, the case is
VOID. It is never replaced with a fresh future block, which would let a party
inspect a seed and discard it.

**Each round carries its own outcome block**, both fixed when the round opens and
neither dependent on when its last reveal lands. The challenge window's close is
likewise a fixed timestamp, not a function of when the challenge arrived.

The short round lifecycle makes this comfortable where the multi-day one did not:
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
x = 0.30   single fixed seed:  f(â)          = 22.3%
           choice of two:      1 − (1−f(â))² = 39.6%
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
| `REJECTED` | **permanently reserved** | none; only an explicit re-review case reopens it |
| `UNRESOLVED(NO_TURNOUT)` | not reserved | freely — no tally existed and nobody could have caused it |
| `UNRESOLVED(NO_REVEALS)` | reserved for a cooldown | pot carried forward; steerable only by a party holding every commit |
| `UNRESOLVED(NO_RANDOMNESS)` | `REJECTED`'s reservation, by reference | none — the case *was* tallied, and I26 attaches to that |

`state-machine-v3` §4.8 and §8.4 are normative here. This table read `NO_QUORUM`,
one row, "free retry"; the reason code turned out to decide both the debits and the
retry rule, so it is three rows with three treatments. The last one is the
counter-intuitive member: a case whose seed expired has a *complete* tally and is
missing only the coin, so releasing its key would hand a submitter facing rejection
a free second attempt.

**Retry is closed by construction here, not priced.** The two-ticket rule needed a
priced retry because it abstained on 9.5% of ordinary content and permanently
excluding that content would have been wrong. Three tickets reject ordinary content
2.0% of the time at `N = 34`, so a permanent reservation is defensible without an
escape hatch, and the optional-stopping surface closes with it.

**The margin this argument runs on is much thinner than it was written to be**, and
it is the weakest load-bearing claim in this document. Three things have moved
under it since:

- The figure was **0.725%** and is **1.97%**, because the draw is taken against `â`
  rather than `A/N` (§3). Nearly a factor of three, from arithmetic alone.
- It assumes `a = 0.95` — that ordinary content draws a 95% honest tally.
  `simulation/v3/FINDINGS-v3.md` measures 26–60% false rejection across the
  plausible range of `prior`, and the 0.95 assumption is exactly the unmeasured
  honest-accuracy figure the headline of that document is about.
- It assumes independent error. §F of the same document shows correlated error
  costs the *most* in the clean, no-attacker case — the regime this paragraph
  describes.

The residual case is the honest publisher unlucky enough to land in that band.
They are not left without recourse: `REJECTED` is reopened by an explicit re-review
case (below), which is a new claim carrying evidence rather than a repurchase of
the same draw. **`NO_TURNOUT` is the only free retry**, and it is free precisely
because no tally existed — not merely because no draw occurred, which is also true
of `NO_RANDOMNESS` and does not earn it one. `state-machine-v3` §10 carries the permanence of
`REJECTED` as open work, blocked on the honest-accuracy measurement rather than on
a parameter sweep.

**A policy-version bump must not reopen rejections.** Scoping the reservation to
`policyVersion` as written would make every ruleset change a scheduled amnesty that
an attacker can simply wait for. Rejections persist across versions; only an
explicit re-review case reopens one.

**A policy-version bump must not reopen rejections.** Scoping the reservation to
`policyVersion` as written would make every ruleset change a scheduled amnesty that
an attacker can simply wait for. Rejections persist across versions; only an
explicit re-review case reopens one.

**Correction is a separate claim. Re-review is not.** An approved entry may face a
*removal* case, which asks a different question — is a listed entry still fit to be
listed — and so runs the same engine, produces `REMOVED` or `RETAINED`, and earns
its own claim key. A **re-review** asks the same question again, and
`state-machine-v3` §8.5 specifies it as a *reopening* of the existing claim rather
than a new one: same key, same `u` re-derived from stored entropy, pooled tally
carried forward, prior voters already settled and not re-judged.

That is what makes permanence mean anything. Had a re-review been a new
`actionType` it would have had a different key, the permanent reservation would not
have bound it, and **`REJECTED` would have been worth one byte** — the
scheduled-amnesty defect §8 closes by keeping `policyVersion` out of the key,
returning through the field that stays in it. Reopening in place inherits §4.5's
monotonicity instead: an unchanged tally returns an identical verdict, so
repetition buys nothing, and a failed reopening adds votes to the side that won, so
it makes the next attempt harder rather than easier.

Approvals also carry `validUntil`, after which cautious clients stop treating them
as certified unless renewed.

## 9. Turnout is the variable everything is priced on

`x` is the hostile share **of revealed votes**, not of registered stake. A 30%
registered attacker who is 50% of reveals gets `f(0.5) = 50%`, not 22.3% — and the
amplifier that protects an honest majority works just as hard for a hostile one.
Every number in §3 and §4 is a function of honest turnout inside a short window,
and the design must fail closed: **insufficient participation produces
`UNRESOLVED`, never approval** (`state-machine-v3` I11; the state is one terminal
with a reason code rather than v2's separate `NO_QUORUM`).

**The quorum is on commits, at 16, and there is no reveal floor.** This paragraph
used to raise `MIN_REVEALS` from 5 to 12–16, on the reasoning that five reveals
were thin once the four-day challenge window went away. `state-machine-v3` §4.8
removed the reveal floor instead of raising it: a gate at the reveal stage selects
between terminal classes on state every revealer can watch, which was the only
thing that ever made withholding attractive. The number moved to the commit gate,
where it is decided blind. What stops a thin tally from deciding a case outright is
not a floor but §3's estimator — at `N = 3` a unanimous cohort is overruled 10.4%
of the time, and the confidence a verdict can express is bounded by the evidence
behind it rather than by a threshold.

Larger cohorts do not reduce the expected hostile share. They reduce sample
variance and whole-cohort capture probability. Under three tickets they no longer
need to supply *distinct* ballots — sampling is with replacement — so the ballot
-count argument for a large cohort disappears and only the variance argument
remains.

### 9.1 Assurance is a property of the tally, not of the draw

A 3–0 ticket draw is stronger evidence than 2–1, but it is still three samples of
the same tally. `P(3/3 Approve) = â³`, at `N = 34`:

```
tally A/N    0.60    0.70    0.80    0.90    0.95    1.00
P(3/3)      19.9%   33.5%   47.1%   70.2%   77.0%   85.0%
```

A case with 30% Reject votes still draws 3/3 Approve a third of the time — and note
the last column, which was 100% under `A/N` and is what made `state-machine-v3`
§8.3's 3/3 conjunct redundant beside its `pooledReject == 0` conjunct.

So `unanimousTicketDraw` is stored as evidence but **must not by itself carry a
high-assurance label.** The strict class requires the tally to participate:

```
SUPER_SAFE  =  final verdict == Approve
           AND no challenge was opened
           AND ticket draw was 3/3 Approve
           AND revealCount >= SUPER_QUORUM
           AND rejectVotes == 0
           AND no removal or re-review case is open
```

This replaces the "unopposed subset" language of the README, which inherited the
same defect from the other direction: **the lottery selects truth; it does not
manufacture certainty.**

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
| O2 | The minority-dissent premium of §5.3 — 7.2× against a correlated majority | this project; the largest cost of the payout decision |
| O3 | The distribution of `a` on ordinary content — decides §4's cost | testnet |
| O4 | Correlated AI error — `x` counts addresses, not independent judgments (P1-4) | open |
| O5 | Selective reveal under batched commitments — a Merkle root hides its leaf count, so withholding is undetectable | open; §6's debit prices it only if the commit is visible |
| O6 | `d` flat or reputation-scaled (D4) | this project |
| O7 | Guidelines as the Schelling point — one line carries the whole mechanism | open; now load-bearing twice, since §5 pays for convergence |
| O8 | **Resolved — adopted (§2.1).** The 12-hour challenge round and the one-hour index write. Decision by the project owner. Finality is 12–13 hours; what arrives in one is the *plurality*, not a verdict | closed |
| O9 | **Resolved — the answer is O8, conditionally (§2.1).** False approval moves from 23.2% to between 2.6% and 41%, decided by `h`, the probability the honest side challenges a loss | closed as a decision; `h` becomes O10 |
| O10 | **`h` — honest challenge reliability.** The single quantity that decides whether §2.1 halves the false-approval rate or nearly doubles it. Unmeasured, and it depends on notification, client design and fee, not on the contract | this project; testnet |
| O11 | The plurality index write is visible for 12 hours. `PLURALITY_REJECT` is a censorship surface with a guaranteed half-day of effect even when the draw later goes the other way. Narrowed but not closed by `state-machine-v3` §4.2's withdrawal of the provisional draw: the plurality carries no randomness, so it leaks nothing about the outcome beyond what the votes already say | open |

**The standing constraint is unchanged and this design does not relax it.** No
deployment with material funds, and the index is not presented as reliable
safe-search certification, until the P0 set closes and an independent re-audit
passes against a named commit. A new architecture resets what that re-audit
covers; the four-contract audit does not carry over.

## 11. Attribution

- **Negative → positive assurance, ticket confirmation, the three-ticket majority
  rule and its `f(a)` arithmetic, with-replacement sampling, winner-only payout,
  the hybrid one-hour/challenge lifecycle and its challenge reserve (§2.1),
  `MIN_CHALLENGE_REVEALS`, the assurance definition in §9.1, fixed `outcomeBlock`,
  no lazy re-arming, eligibility widening, claim keys, approval expiry,
  a raised reveal quorum** — the senior reviewer. The last of these is adopted in
  substance and not in form: the number moved to `MIN_COMMITS` (§9).
- **The cost accounting in §4, the result that neutrality forces a penalty-free
  contested branch (which is what withdrew the two-ticket rule), the ticket-pot
  construction recorded in §5.1, the reading-pays argument and dissent risk in
  §5.2–5.3, the commuting-penalty properties and bond construction in §6, the
  adaptive-window findings in §7, and the policy-version amnesty in §8** — this
  project.
- **The decision to relax exact cash neutrality** rather than the
  only-winners-paid rule — the project owner, deliberately, on the grounds that a
  conformity premium is wanted. §5.1 records the alternative that was available.
- **The decision to reinstate the challenge round** after a revision that removed
  it — the project owner. §2.1 records both what it buys and that it reintroduces
  the optional stopping the removal was for.
- **The `h`-dependence of §2.1**, which shows the round's value ranging from 2.6%
  to 41% on a quantity outside the contract — this project.
- **Per-unit freezing**, which §6 generalizes into P1, and the risk-unit proposal
  it came from — the external v2 review. The mechanism is withdrawn; the insight
  that penalties must be order-independent is what survives it.
- The payout derivation this document depends on is `design-v2.md` §4, unchanged.
