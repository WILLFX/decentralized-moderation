# Design v3 — One-Hour Provisional, One Challenge Round

**Status:** Design. Specified normatively in `specs/state-machine-v3.md`; not
implemented. Where the two disagree, the state machine is normative and this
document should be corrected.
**Supersedes:** the challenge architecture of `design-v2.md` §2.4 and §4.6, and the
risk units of revision v2.1. `design-v2.md` §4.2's neutrality theorem is
**no longer a design requirement** (§5); it remains correct and is now the
statement of what this design gives up.
**Revision:** v3.2 — a 12-hour challenge round is reinstated (§2.1) and the
architecture is no longer challenge-free; the one-hour result becomes
**provisional**. v3.1 replaced two tickets and a terminal `CONTESTED` with three
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
now:  commit -> reveal -> draw -> PROVISIONAL                        ~1 hour
      -> 12h challenge window -> (one challenge round -> final draw) ~12-13 h
```

**The result is not challenge-free.** An earlier revision of this document was, and
§2.1 records why the window came back: a 2-of-3 majority certifies bad content
21.6% of the time at a hostile 30% of reveals, and a single sealed round has no
mechanism to correct that. The challenge round is the correction, and §2.1 states
exactly what it costs.

What is bought is **speed of decision**, not speed of correction: a usable
provisional answer in an hour where the old design gave nothing for six days.

## 2. Mechanism

One notified cohort. One commit–reveal round. One hard quorum. One fixed outcome
seed. **Three ballot-side draws from the revealed tally, with replacement; the
side on two of three is the verdict.**

```
SUBMIT -> COMMIT -> REVEAL -> DRAW -> PROVISIONAL -> (§2.1) -> one of:

    two or three tickets Approve  ->  APPROVED
    two or three tickets Reject   ->  REJECTED
    reveals < MIN_REVEALS         ->  UNRESOLVED
```

There is no `CONTESTED` state and no post-draw appeal of a *final* claim. The
verdict of the first round is **provisional** and may be challenged exactly once
(§2.1).

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
0.287% of the time. Tickets carry no payout entitlement of their own (§5), so
sampling the same ballot twice creates no windfall.

Eligibility is unchanged from v2: passive, hash-based, `H(m, c, r, seed) <
threshold`, evaluated off-chain by each moderator. **Submitting a case still
reserves no moderator, locks no stake, and creates no obligation on anyone**
(design-v2 §1, invariant I12). That property is the reason the first architecture
was abandoned and it is not negotiable here.

### 2.1 The challenge round

```
hour 0-1    commit, reveal, three tickets, draw
            -> index writes PROVISIONAL_APPROVED / PROVISIONAL_REJECTED
            -> NOTHING is paid, nobody is penalised, the pot stays escrowed

hour 1-13   challenge window

  no challenge, or MIN_CHALLENGE_REVEALS not met
            -> provisional verdict becomes final
            -> winners paid, losers penalised

  challenge registered (any ACTIVE moderator + CHALLENGE_BOND; no eligibility
  test - state-machine-v3 §3.5), threshold later met
            -> at the window's SCHEDULED close, not when the challenge landed,
               a second commit-reveal round opens, admitting only eligible
               moderators who did not vote in round 0
            -> tallies POOL: A = A0 + A1, R = R0 + R1
            -> three FINAL tickets drawn from the pooled tally
            -> one pot to every voter from either round matching the final
               verdict; everyone against it is penalised
```

**Exactly one challenge round.** The provisional draw is discarded when a challenge
succeeds in opening; it never binds and never pays.

**A challenge must earn its round — and the floor that was meant to enforce this
is withdrawn.** `MIN_CHALLENGE_REVEALS` is removed (state-machine-v3 §4.6). It was
unsatisfiable exactly when it mattered, judged voters against a tally they were
excluded from, and was a coordination trap. The job is done structurally instead:
**one randomness per claim, evaluated against both tallies** (state-machine-v3
§4.5). An unchanged tally yields an identical verdict, so there is no second draw
to buy, and the verdict is monotone in the tally — adding votes can move it only
toward the side that was added. An attacker who lost round 0 at `a₀ = 0.3125` needs
a median of **21** Approve votes to flip it, against **zero** for a 23.2% chance
under a fresh draw.

**Funding: a prefunded, refundable challenge reserve.**

```
submission payment = initial pot + challenge reserve + finalization bounty
                   + nonrecoverable maintenance component

no challenge -> reserve refunded
challenge    -> reserve joins the single final pot
```

The activated reserve goes to *all* final-verdict voters from both rounds, not to
challenge voters as a class. Without it, opening a challenge raises turnout while
shrinking the per-winner share, which taxes exactly the honest participation the
round exists to attract. A failed challenger's bond is burned or retained as
maintenance funding and is **never** transferred to the winners — that is
punishment farming, forbidden since design-v2 §5.5.

**Payment for round-1 voters does not depend on which round they voted in**, on
whether their ballot was sampled, or on whether the challenge reversed the result.
A round-1 Reject voter who is vindicated by a reversal is paid identically to a
challenge-round Reject voter.

#### What the challenge round costs

It reintroduces optional stopping, which the challenge-free revision existed to
remove. The loser of the provisional draw is the party who challenges, so a
motivated attacker always buys the second draw while an honest side buys it only
when someone notices, is eligible, and pays.

With 32 round-0 reveals at 30% hostile (`a = 0.3125`, provisional APPROVED 23.2%),
and `h` the probability the honest side challenges a loss:

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

Let `A` be revealed Approve votes, `R` revealed Reject, `N = A + R`, `a = A/N`.
Three ticket sides are drawn independently, each Approve with probability `a`. The
side appearing on at least two becomes the verdict:

```
f(a) = P(APPROVED) = 3a² − 2a³          P(REJECTED) = 1 − f(a)
```

**Implementation needs only the counts:**

```
for i in 0..2:  ticket[i] = H(outcomeSeed, i) mod N < approve
verdict = (ticket[0] + ticket[1] + ticket[2] >= 2) ? Approve : Reject
```

Three hashes and a comparison. No ballot array, no without-replacement bookkeeping,
and no division by `N−1` — the divide-by-zero guard the two-ticket rule needed is
gone with it.

**`f` is a majority amplifier, and that is the whole of what it buys and costs.**

```
tally share a    0.51    0.60    0.70    0.80    0.90    0.95
f(a)            0.515   0.648   0.784   0.896   0.972   0.9928
```

A 51% side wins 51.5% of the time; a 90% side wins 97.2%. **No outcome is certain
— but a large coalition approaches certainty faster than under a linear lottery.**
That is a real weakening of "no outcome can be engineered with certainty," and it
is accepted deliberately (§5). With replacement, even a 31–1 tally leaves the
one-vote side 0.287%.

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
| **three tickets, 2-of-3** | **21.6%** | **0.725%** |

**Against censorship this is the strongest rule available** — 0.725% where the
withdrawn two-ticket rule gave 9.75% and a linear draw gave 5%. Amplification
works for the honest majority whenever the honest side *is* the majority.

**Against false approval it is the weakest of the three**, at 21.6% versus 9%. A
hostile 30% of reveals certifies bad content roughly one time in five. That is the
price of removing the abstention branch, and it must be quoted wherever the
censorship number is quoted. **This is the number the challenge round of §2.1
exists to correct**, and it moves to anywhere between 2.6% and 41% depending on how
reliably the honest side challenges.

> **The honest statement of the mechanism: it suppresses minorities in both
> directions.** Good when the minority is an attacker, bad when the minority is
> right. It is one property seen twice, not two properties.

**Everything above is a function of turnout, not of registered stake.** A 30%
registered attacker who is 50% of reveals gets `f(0.5) = 50%`, not 21.6%. §9.

**What is no longer a cost.** The withdrawn rule contested 9.5% of ordinary content
at `a = 0.95`, rising to 16.7% at a bare quorum of 12 — one case in six failing to
certify on a single dissenting reveal. That is gone. False rejection of ordinary
content is now 0.725%, and the finite-`N` correction that made the two-ticket rule
worse at small cohorts does not apply: `f(a)` is exact at every `N`, because the
tickets are drawn with replacement from the tally shares rather than from distinct
ballots.

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
side won the provisional draw, and whether the challenge reversed the result.

**Nothing is paid and nobody is penalised at the provisional draw.** The pot stays
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
This closes selective realization (P1-2, §4.11) and the last-revealer timing issue
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
x = 0.30   single fixed seed:  f(x)          = 21.6%
           choice of two:      1 − (1−f(x))² = 38.5%
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
| `NO_QUORUM` | not reserved | freely — no probabilistic result occurred |

**Retry is closed by construction here, not priced.** The two-ticket rule needed a
priced retry because it abstained on 9.5% of ordinary content and permanently
excluding that content would have been wrong. Three tickets reject ordinary content
0.725% of the time, so a permanent reservation is defensible without an escape
hatch, and the optional-stopping surface closes with it.

The residual case is the honest publisher unlucky enough to land in that 0.725%.
They are not left without recourse: `REJECTED` is reopened by an explicit re-review
case (below), which is a new claim carrying evidence rather than a repurchase of
the same draw. **`NO_QUORUM` is the only free retry**, and it is free precisely
because no draw occurred.

**A policy-version bump must not reopen rejections.** Scoping the reservation to
`policyVersion` as written would make every ruleset change a scheduled amnesty that
an attacker can simply wait for. Rejections persist across versions; only an
explicit re-review case reopens one.

**A policy-version bump must not reopen rejections.** Scoping the reservation to
`policyVersion` as written would make every ruleset change a scheduled amnesty that
an attacker can simply wait for. Rejections persist across versions; only an
explicit re-review case reopens one.

**Correction is a separate claim, not an appeal.** An approved entry may face a
removal case that runs the same engine — commit, reveal, three tickets — producing
`REMOVED` or `RETAINED`. This is a new claim about the current index
entry, not a retry of the original draw. Approvals also carry `validUntil`, after
which cautious clients stop treating them as certified unless renewed.

## 9. Turnout is the variable everything is priced on

`x` is the hostile share **of revealed votes**, not of registered stake. A 30%
registered attacker who is 50% of reveals gets `f(0.5) = 50%`, not 21.6% — and the
amplifier that protects an honest majority works just as hard for a hostile one.
Every number in §3 and §4 is a function of honest turnout inside a short window,
and the design must fail closed: **insufficient participation produces
`NO_QUORUM`, never approval.**

`MIN_REVEALS` rises from 5 to **12–16**. Five reveals were thin while a four-day
challenge window backed them; without one they are indefensible.

Larger cohorts do not reduce the expected hostile share. They reduce sample
variance and whole-cohort capture probability. Under three tickets they no longer
need to supply *distinct* ballots — sampling is with replacement — so the ballot
-count argument for a large cohort disappears and only the variance argument
remains.

### 9.1 Assurance is a property of the tally, not of the draw

A 3–0 ticket draw is stronger evidence than 2–1, but it is still three samples of
the same tally. `P(3/3 Approve) = a³`:

```
a          0.60    0.70    0.80    0.90    0.95
P(3/3)     21.6%   34.3%   51.2%   72.9%   85.7%
```

A case with 30% Reject votes still draws 3/3 Approve more than a third of the time.
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
| O8 | **Resolved — adopted (§2.1).** The 12-hour challenge round and provisional index write. Decision by the project owner. Finality is 12–13 hours; only the *provisional* answer arrives in one | closed |
| O9 | **Resolved — the answer is O8, conditionally (§2.1).** False approval moves from 23.2% to between 2.6% and 41%, decided by `h`, the probability the honest side challenges a loss | closed as a decision; `h` becomes O10 |
| O10 | **`h` — honest challenge reliability.** The single quantity that decides whether §2.1 halves the false-approval rate or nearly doubles it. Unmeasured, and it depends on notification, client design and fee, not on the contract | this project; testnet |
| O11 | The provisional index write is visible for 12 hours. `PROVISIONAL_REJECTED` is a censorship surface with a guaranteed half-day of effect even when the challenge overturns it | open |

**The standing constraint is unchanged and this design does not relax it.** No
deployment with material funds, and the index is not presented as reliable
safe-search certification, until the P0 set closes and an independent re-audit
passes against a named commit. A new architecture resets what that re-audit
covers; the four-contract audit does not carry over.

## 11. Attribution

- **Negative → positive assurance, ticket confirmation, the three-ticket majority
  rule and its `f(a)` arithmetic, with-replacement sampling, winner-only payout,
  the hybrid provisional/challenge lifecycle and its challenge reserve (§2.1),
  `MIN_CHALLENGE_REVEALS`, the assurance definition in §9.1, fixed `outcomeBlock`,
  no lazy re-arming, eligibility widening, claim keys, approval expiry,
  `MIN_REVEALS` 12–16** — the senior reviewer.
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
