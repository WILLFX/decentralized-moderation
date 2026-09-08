# Decentralized Moderation

*A staking-based moderation market and safe-search index for [Swarm](https://www.ethswarm.org/), governed entirely by a smart contract.*

Content publishers pay a fee to be moderated. Staked moderators (human or AI) judge submissions in a Schelling game: for each case a random subset of moderators becomes eligible to vote, the verdict is drawn as a majority of three tickets against a posterior estimate of the tally, and anyone who disagrees can challenge — posting a bond that buys a second round of voters whose votes pool with the first. Approved content is recorded in an on-chain, topic-indexed registry that powers safe search — with no company in the middle.

This document sums up the aim of the project, the problems we are solving, and how we intend to solve them; section 3.6 documents the attack analysis that shaped it. All concrete numbers (stakes, cohort sizes, periods, fees) are current working values, not final protocol parameters — fixing them is what the simulation milestone is for.

> **Implementation status — v3, and it is built.** Section 3 describes the
> protocol as it now stands. **`specs/state-machine-v3.md` is normative**;
> `specs/design-v3.md` carries the derivations, and where the two disagree the
> state machine wins.
>
> Four contracts implement it in `contracts/src/v3/` — `Moderation`,
> `StakeRegistry`, `RulesetGovernor`, `IndexRegistry` — with 266 tests, stateful
> invariants over the real contracts, a two-implementation differential on the
> verdict draw, and mutation campaigns as the acceptance bar. `contracts/README.md`
> is the map. **It has not yet had an independent external review**, and the
> standing constraint below is unchanged until it does.
>
> `contracts/src/` (unprefixed) is the **first** architecture — drawn panels,
> obligated moderators, bonded appeals. It is complete and audited and it is kept
> because building it produced the finding everything since rests on: assigning
> moderators to cases creates a resource an attacker can exhaust (§3.6).
> `specs/state-machine-v2.md` and `design-v2.md` are the intermediate design, also
> superseded. Neither describes what the code now does.

> **Standing constraint.** No deployment with material funds, and the index is not
> presented as reliable safe-search certification, until `prior` is measured
> (`measurement/prior/`) and an independent re-audit of the four-contract
> architecture passes against a named commit. **`prior` — how often a moderator's
> judgment matches the truth — is unmeasured, and §7 explains why it decides
> whether any of this is deployable at all.**

## 1. Why this exists

Swarm **feeds** make permissionless publishing trivial. A feed is defined by an owner key and a 32-byte topic. In the *anythread* pattern, any URL (or any string) is hashed to derive both a feed owner key and a topic — and because anyone who knows the string can derive the same key, anyone can write to the feed and anyone can read it. The result is commenting, blogging, and annotation on top of any subject, with no user registry, no server, and no operator.

The flip side of "anyone can write" is that anyone can write anything; Centralized platforms (Facebook, YouTube, Meta at large) solve this by employing moderators in large numbers, increasingly assisted by AI — paid out of a corporate budget. A decentralized system has **no corporation and no budget**. Consuming unmoderated feeds means consuming out-of-control filth, which makes the whole publishing layer unusable for ordinary applications.

What is missing is a mechanism where **the people who want to publish pay a group of moderators — a group anyone can join as a form of work** — to certify that content is (1) safe (SFW, in the spirit of common community guidelines or what a safe-search filter would pass) and (2) relevant to the topics it claims. That mechanism turns moderation from a corporate cost center into an open, paid job that requires nothing but a smart contract. And its by-product is something the decentralized web currently lacks entirely: **safe search**.

## 2. The problems we are solving

**Moderation without a corporation.** Anyone can stake and become a moderator; moderators are paid per judged submission out of submission fees. There is no budget and no employer — the fee flow is the payroll. Moderators may be humans clicking through a web interface, but most will probably be AI classifiers. That changes nothing economically: somebody has to *run* each AI moderator, and that somebody is compensated like any moderator, because operating a moderation service is work — this is a job either way.

**Safe search over permissionless content.** Every finalized approval is recorded on-chain under its topics. A search front end can then answer "show me every entry approved in the category *xy*" — the primary example being exactly what Google SafeSearch does, but for content no company controls. Without this filter layer, permissionless publishing drowns and becomes unusable.

**Decentralized SEO.** Approval is exposure: paying the submission fee buys review, and passing review buys a place in the searchable index. This is search-engine optimization with the incentives on the table — the index is public and transparent, and the ranking algorithm is **replaceable**: anyone can build a different search or ranking application over the *same* on-chain data set. No black-box algorithm decides who gets seen.

**Moderation that cannot be flooded.** A moderation queue is a resource, and any system that *assigns* moderators to cases lets an attacker consume that resource by opening cases. Nothing here is assigned: submitting a case reserves no moderator, locks no stake, and creates no obligation on anyone. A thousand junk submissions consume nothing but their own fees, and the cases worth judging are judged first because that is where the money is.

**Attack-resistant judging.** No outcome can be engineered with certainty (every round resolves probabilistically), no attack pays from the inside (the mechanism never transfers stake between moderators — there is nothing to farm), and no attack can be retried into success (votes accumulate across challenge rounds rather than being re-rolled, so a second attempt does not reset the odds).

## 3. The core mechanism

### Design principles

Six principles, made explicit because every rule below follows from them:

1. **Safe for moderators.** Voting never risks the stake. The worst case for an honest moderator on the losing side of a genuinely borderline call is a **fixed debit `d` from their working bond** — a small multiple of what a case pays, bounded and one-off. The 10 xBZZ identity stake is never touched. Hard cases exist; judging them must not be financially ruinous, or nobody sane moderates.
2. **Zero internal attack profit.** Stake is never slashed or redistributed between moderators. A redistribution rule would let a majority attacker farm honest minorities (stake 200 moderators against 100, win, harvest their stakes) — the mechanism itself would mint the attack's reward. Every debit goes to a **maintenance reserve**, never to another moderator. All rewards are *external* money: submission fees. An attacker's only possible prize is the listing itself.
3. **Nobody is conscripted.** No moderator is ever assigned to a case, bound to one, or penalised for ignoring one. Eligibility is an opportunity, never a duty. This is what makes the queue unfloodable, and it is why there is no no-show penalty anywhere in the design: there is no show to fail to make.
4. **No party can steer the *terminal class* of a case.** The earlier form of this principle — *the verdict never moves the cash* — was retired, because v3 pays the whole pot to voters coherent with the verdict, so expected cash is no longer independent of direction. What replaced it is stronger and is enforced rather than hoped for: **the premium attaches to the majority, not to Approve**, so no rule-level bias toward listing exists; and no party can change which *kind* of outcome a case reaches by anything they do or decline to do (`state-machine-v3` I24). A conformity premium remains, and is stated rather than denied.
5. **Penalties are money, never time.** v2 froze identities and stacked the freezes. That made the cost of a vote depend on how many other cases a moderator was in, and made penalties **settlement-order-dependent** — the same three losses cost 24 days or 19 depending on the order they settled in. A debit from a balance commutes; an interval added to a deadline does not. The debit-to-pay ratio is now a chosen constant rather than an emergent one.
6. **Trust is earned, not bought.** A track record of coherent participation accrues per identity and does not transfer, so abandoning an identity abandons its standing. Fresh capital has none.

### 3.1 Moderators and staking

Anyone becomes a moderator by staking **10 xBZZ** — a flat amount, the same for everyone — and posting a **bond**, which is separate working capital. The two do different jobs and this is the change that removed freezes entirely:

- **stake** is the identity floor. It is never debited, and it is withdrawable after an exit cooldown of ~7 days so pending judgments always settle first.
- **bond** is what a vote is backed by. Penalties consume it; rewards replenish it. A moderator may commit while their bond covers their **accrued liabilities** — one `LAMBDA` per open vote — and no further.

Stake is never destroyed or transferred to another moderator; every debit goes to the maintenance reserve (principle 2).

**One stake, one vote, and concurrency is priced rather than capped.** There is no seat, no reservation, and no cap on how many cases a moderator may be voting in at once. What bounds it is solvency: each open vote accrues a liability against the bond, so a moderator can hold as many open votes as they can back. That replaced v2's risk units — a *price* where the earlier design used a *reservation* — and it is what makes the queue unfloodable while keeping per-case consequence bounded.

Staking more than the minimum buys nothing. Voting power is flat per identity, so influence is bought by running more moderator identities, each costing its own 10 xBZZ — which means influence still costs capital linearly, but no single account accumulates a large voice. Identities are cheap to create and, by design, expensive to *replace*: a fresh identity carries no track record (principle 6) and cannot vote until its stake matures, so abandoning a penalised identity for a new one costs both the waiting period and the accumulated standing.

### 3.2 Submissions

A moderation request contains three things:

1. the **CAC hash of the content** — a content-addressed chunk hash, deliberately *not* a single-owner chunk (SOC), because a SOC would allow bait-and-switch: getting something innocuous approved and then rewriting the content behind the same address. CAC hashes are immutable, so what was approved is exactly what stays approved;
2. the **CAC hash of a metadata JSON** — a conventional object describing what the entry is and what it is about (object type, topics, and other fields that aid searchability); and
3. the **submission fee**, transferred to the contract on submission, alongside an explicit **topic string list** (e.g. "biology", "geography") duplicating the topics in the metadata so the contract can index without reading Swarm.

An approval therefore asserts three things at once: the content is **safe**; the content and metadata hashes **match** and the metadata honestly describes the content; and the content is **relevant to the topics** used in the submission.

Submitting reserves no moderator and creates no obligation on anyone. The fee sits in the contract until the case resolves.

### 3.3 Round one — who may vote, and who does

There is no draw. A moderator is eligible to vote in a case if

```
H(moderator, caseId, round, caseSeed) < T
```

which every moderator can check for themselves, off-chain, for free. The contract verifies the same inequality when a vote arrives. Nothing is enumerated, no panel is assembled, and no transaction is needed to decide who may participate — **the selection costs zero contract interactions**, which matters because a call nobody is paid to make is a call nobody makes.

The threshold `T` is **static**, calibrated so the expected eligible set is `TARGET_COHORT` (working value: **40**) at a calibration registry size. It is deliberately *not* read from a live moderator count: maintaining one on chain would require every stake and exit to update a global, and `state-machine-v3` §3.6 rules that out. The cost is that the realized cohort scales with the registry rather than staying fixed, which is a known trade recorded in §10 of that document.

`caseSeed` is a blockhash from a few blocks after the round opens — so the eligible set is unknowable when the case is submitted, and a submitter cannot grind the case id to select a friendly cohort.

**Everyone eligible may vote, within a fixed window.** Voting is not first-come: the window is a fixed **commit-reveal** period (working values: 20 min commit, 20 min reveal), every eligible moderator may participate for its whole duration, and votes are counted regardless of arrival order. This matters more than it looks — if only the first *n* votes counted, an attacker holding a minority of the cohort could decide cases by being fast, and speed is the one advantage a well-resourced attacker always has. A fixed window makes it worthless.

**No phase ever closes early**, and that is a safety property rather than a convenience. Closing on "everyone revealed" would hand the last actor a free choice between two outcome seeds; closing on "everyone eligible has acted" is not computable. Early termination is either useless or unsafe.

Eligible moderators who do not vote are not penalised in any way. They are simply not paid. A moderator who *commits* and then does not reveal is debited `REVEAL_BOND` — that is a different thing, and it exists because withholding a revealed vote would otherwise be a free way to shrink a tally.

**There is no quorum gate.** A round proceeds on whatever turnout it attracts, down to a single commit. An earlier revision required 16 commits and failed 92% of cases at a launch-size registry; measurement showed the gate was inert wherever the registry was large and destructive wherever it was not (`simulation/v3/FINDINGS-adaptive.md`). What stops a thin tally from deciding a case outright is not a floor but the estimator in §3.4.

### 3.4 Probabilistic outcomes and challenges

At about **one hour** the contract publishes the **plurality** — which side has more revealed votes. That is a *fact about the votes*, not a verdict: **no randomness has been drawn yet**, and none exists until every window has closed. Publishing a drawn provisional result instead would hand every party the exact number of votes needed to flip the case, twelve hours before they had to decide whether to challenge.

**The verdict is a majority of three tickets.** When all voting has closed, three uniform values are drawn once and compared against

```
â  = (approve + 1) / (N + 2)          -- NOT approve / N
verdict = Approve if at least two of the three tickets fall below â
```

so `P(Approve) = f(â) = 3â² − 2â³`. Two things follow that a plain proportional lottery does not give:

- **`â` is a posterior, not a sample proportion.** Feeding `f` the raw ratio would claim certainty from however many votes happened to arrive — at one revealed vote, `f(1) = 1` and a single voter decides the case outright. The add-one estimator makes confidence a function of turnout rather than an assumption about it: a unanimous cohort is still overruled 25.9% of the time at one vote, 2.8% at eight, 0.17% at forty. **This is what replaced the quorum gate.**
- **The majority is amplified rather than sampled.** `f` suppresses minorities — which is a benefit exactly while the honest side *is* the majority of revealed votes, and a cost the moment it is not. §3.6 is explicit about where that crossover sits.

The result is not final. A **challenge window** follows (working value: 12 hours). During it, **any active moderator** may register a challenge by posting `CHALLENGE_BOND`. Three properties matter and each replaced a v2 rule:

- **A challenge is not a vote and discloses no direction.** It buys a second commit–reveal round; the challenger commits inside it, hidden, like everyone else. v2 made the challenge itself a public vote and accepted the disclosure as unavoidable — under v3 the constraint dissolves.
- **The bond is a price, not a bet.** It is debited unconditionally at settlement, whichever way the case ends, and goes to maintenance. There is no branch, so there is nothing for a challenger to steer — and a challenger who supplies evidence that *confirms* the plurality has told the system something real and is paid for their vote on the same terms as everyone else.
- **No eligibility test to challenge.** An eligibility gate here would filter honest dissenters, not attackers, since deterrence is structural rather than priced.

**Votes accumulate; rounds do not replace each other.** The challenge opens a fresh commit-reveal period for a fresh cohort — a different eligible set, drawn from the same population by the same hash with the round number mixed in. When it closes, **every revealed vote from every round of the case is pooled into a single tally**, and the verdict is drawn from that pool.

This is the most important structural decision in the design, and it exists to defeat retry. If each challenge round *replaced* the last, every challenge would be a fresh roll of the dice at unchanged odds, and an attacker holding 30% of the network would need only to keep challenging: four attempts reach 76%, ten reach 97%. Probabilistic defence would become a formality. With a cumulative tally, an attacker's share of the pool stays at their share of the network no matter how many rounds happen. **The dice cannot be re-rolled.**

**v3 makes that structural rather than statistical.** The three tickets are drawn **once per claim**, after every window has closed, and the comparison is monotone in the tally. So a challenge that adds no votes returns the *identical* verdict — by arithmetic, not by probability — and a challenge that adds votes can only move the verdict toward the side it added. The only way to change the answer is to change the evidence, which is what the round is for. Measured against a lost round of 10 approve to 22 reject, the median number of Approve votes needed to flip it is 22; under a fresh per-round draw the attacker would need **zero** extra votes for a 24.6% chance.

It also produces the behaviour you would want anyway: a 30–2 first round cannot be overturned by one more cohort, while a 17–15 first round flips easily. Challenge power is proportional to how genuinely contestable the verdict was, and the process self-terminates — once the pooled tally is lopsided, another round cannot move it and nobody bothers to try.

For the same reason, cohorts stay the **same size** each round rather than escalating. Equal cohorts dilute each round's influence naturally, which is what makes the tally converge instead of swing.

If a window closes with no challenge, the case **finalizes**. Clear-cut content is decided in **about an hour to a published plurality, and about thirteen hours to a final verdict** — a challenged case takes one more round.

### 3.5 Settlement — the fee to the coherent, a debit for the rest

Settlement is **pulled per moderator**, not swept per case: `claim(caseId, m)` settles one moderator's claim, is permissionless, is paid for by the party it settles, and is order-independent. There is no batch, no cursor, and nothing that walks a committer list — because the committer count is unbounded and a sweep funded by a fixed fraction of a fixed fee stops being payable past a crossover, at which point **nobody settles anybody**.

Anyone may settle anyone. That is deliberate and load-bearing: a re-review requires every prior voter to be settled first, and if only the moderator could settle themselves, a single abandoned identity would block every re-review of that claim forever.

For each moderator's revealed vote:

- **Coherent with the verdict → paid a share of the pot.** `share = floor(P / W)` where `W` is the number of votes matching the verdict, from either round. The remainder goes to maintenance, never to a moderator.
- **Incoherent → debited `d` from the bond.** A fixed amount, a small multiple of expected pay, the same whichever direction the case went. It goes to the maintenance reserve — never to the other side, which is what makes punishment-farming impossible by construction.
- **Committed but never revealed → debited `REVEAL_BOND`.**

**The debits commute.** Three losses cost the same total whatever order they settle in, because a quantity subtracted from a balance is order-independent where an interval added to a deadline is not. That was v2's P0-6 defect and removing time as the penalty currency is what fixed it (principle 5).

Nothing is ever frozen, and no moderator is ever made ineligible by a penalty. A moderator whose bond can no longer cover a new vote simply cannot open one until they top it up — which is a solvency condition, not a punishment, and it removes future participation only for as long as the shortfall lasts.

### 3.6 Design rationale — how attacks are priced

The mechanism above survived several adversarial redesigns and two external audits; recording the reasoning so future contributors don't re-walk the same dead ends.

**Why nobody is assigned to a case.** The first architecture drew a panel and obligated the drawn moderators to serve, penalising them if they didn't. That is a natural design and it has a fatal property: the assignment is a *resource*, and an attacker can consume it by opening cases. With moderators at the minimum stake and a five-seat panel, a hundred moderators support twenty concurrent cases; the hundred-and-first submission queues behind them, and the attacker has bought a denial of service at the price of the fees. Every fix within that model — shorter locks, higher fees, more capacity — makes the attack more expensive without making it impossible, because the resource still exists. Removing the obligation removes the resource. This is the single largest change from the implemented contracts, and it came out of the capacity analysis in §8's audits.

**Why not deterministic majority?** An attacker who knows it holds a majority attacks with engineered certainty. Probabilistic outcomes mean *every* attack, however funded, can lose any round — there is no safe attack, only priced gambles. And attackers who would only attack with an assured majority are exactly the ones the probability draw deters.

**Why not slash and redistribute losing stakes?** Because redistribution mints the attack's profit: with 100 honest moderators, staking 200 attacking ones and winning would *harvest the honest stakes*. Punishment-as-bounty invites punishment-farming. Kleros-style systems paper over this with a meta-incentive — corrupt the court and its token crashes, destroying the attacker's capital — but that defense doesn't survive contact with a short position, and our stake token (xBZZ) doesn't depend on this contract anyway. So: no reliance on token-value arguments at all. The defense is structural — there is simply no internal transfer to farm.

**What a larger cohort does, and what it does not.** Under a proportional lottery, an attacker holding fraction *q* of the network wins any single round with probability *q* — and that is true whether the cohort is 5 or 32 or 200. Larger cohorts do **not** amplify the majority's judgment the way majority voting does; there is no Condorcet effect here, and it would be dishonest to imply one. What they do buy is the collapse of *complete* capture (the chance an attacker holds every revealed vote falls as *qⁿ*), much lower variance, and a far better chance that both readings of a borderline case are actually represented. Accuracy comes from the guidelines being a clear Schelling point, not from cohort size.

**Where does the attack cost actually live?** Three places. **Retry is closed**: pooled tallies mean a second challenge does not reset the odds, so an attacker cannot convert a 30% chance into a certainty by paying repeatedly — the property that a per-round-replacement design would have handed them. The **debit drag**: every lost round costs `d` from the attacker's bond, once per losing vote per case, and an attacker running many identities pays it on every one of them. The **absence of prize**: winning pays the attacker nothing from the mechanism — the only upside is the listing itself, and a listing bought through visible challenge wars is exactly the kind an honest challenger re-litigates.

**Why identity churn does not defeat the penalty.** Abandoning an identity is only unattractive if replacing it costs something. A fresh identity costs the 10 xBZZ minimum plus a bond, which alone would be a poor deterrent — so two things make replacement costly: new stake cannot vote until it matures, and track record does not transfer (principle 6), so an abandoned identity abandons its standing with it. Note what churn does *not* escape: `d` is debited from the bond at settlement, so walking away from an identity does not avoid a penalty already incurred — it only avoids future ones, which a fresh identity would have to earn its way back into anyway.

**What does an honest moderator's life look like?** Judge clearly-safe and clearly-unsafe content: earn fees, essentially risk-free (unanimous rounds have no lottery, unchallenged results just finalize). Judge borderline content honestly and lose the draw: a fixed debit `d` — annoying, never ruinous, and it never touches the stake (principle 1). Spot a wrong outcome: challenge it, and if the pooled tally moves your way you are paid rather than debited. Ignore a case entirely: nothing happens to you at all. The profitable long-run strategy is judging the way any other honest reader of the guidelines would — a Schelling point on honest judgment.

### 3.7 Randomness

MVP: `blockhash` of a snapshot block a few blocks past the relevant phase boundary, realized lazily by the first transaction that needs it and domain-separated per case, round and purpose. (The design draft said `block.prevrandao`; the EVM cannot read a past block's `prevrandao`, so `blockhash` is what the contract uses — `specs/state-machine.md` §7 and `contracts/DEVIATIONS.md` D-1.) Proposer manipulation is real: a proposer can influence the eligible cohort and the outcome draw. An earlier claim bounded its value by per-case pot size; that is wrong, because the attacker's prize is the **listing** itself, whose SEO value no pot cap bounds. It is an accepted MVP assumption — small per-case leverage on the Gnosis proposer set, and a biased listing stays challengeable — with a VDF or randomness-oracle upgrade path if listing value grows large.

### 3.8 Publication and search

Search has an easy way and a hard way; **we take the easy way first to reach an MVP**, and optimize later.

**Easy way (MVP):** the entry is written **at the transition that establishes a
terminal**, not at settlement — because settlement is pulled per moderator and may
never complete, so an index write bundled into it would sit behind an unbounded
number of calls nobody is obliged to make. A reader must never wait on moderator
payouts to see a result.

**Status is a value, not an absence**, and the zero slot is what makes the rest
mean anything:

```
NONE = 0 | PLURALITY_APPROVE | PLURALITY_REJECT | APPROVED | REJECTED
         | UNRESOLVED | REMOVED
```

Without `NONE`, an unwritten slot and a case whose plurality leans Approve would
read identically — in the one place where "not yet decided" and "never submitted"
must be distinguishable. Every identifier the index exposes is **derived from
content**, never from a counter or insertion order, so a replacement contract
re-derives the same address for the same entry instead of colliding with what its
predecessor wrote.

Entries carry the status, the plurality where one was established, and the counts.
A case that ends `UNRESOLVED` after a full cohort judged it keeps its published
plurality beside that status; one that ended before any tally carries `UNRESOLVED`
alone. **Nothing is listed in any of them**, which is the only property a
safe-search client needs — the distinction is for the reader who wants to know why.

**Two views of the index.** The system has probabilistic outcomes, and a
safe-search product must be honest about that:

- the **superset** — everything currently approved, including entries that won
  contested draws; and
- **`SUPER_SAFE`** — the cautious mode, and it is a **live query rather than a
  stored flag**, because a re-review or removal opened years later must revoke it:

```
SUPER_SAFE  =  verdict is Approve            -- all tally facts, fixed at the
           AND no challenge was opened          terminal that wrote the entry
           AND revealCount >= SUPER_QUORUM
           AND pooledReject == 0
           AND reveals == commits            -- nobody withheld
           AND no removal or re-review is currently open
```

**Read it literally, and note what it is not.** Every conjunct is a fact about the
*tally*; none is a fact about the *draw*. An earlier version also required the
three tickets to fall unanimously, which sounds stronger and was not: under a
unanimous tally the tickets are independent, so that clause excluded a random 7–16%
of otherwise-qualifying content while carrying no information about it. It was
dropped, because a label that publishes a random subsample is lying about its own
selectivity.

`SUPER_QUORUM` is an open parameter. Until it is set from measurement, **this is a
filter and not a certificate** — a client aiming at children's use should layer its
own absolute thresholds on the published counts rather than trusting the label.

**Hard way (later):** publishing the index into Swarm feeds for a more economical, chain-light structure once the MVP proves the mechanism — without changing the moderation game.

## 4. Economics

Making the money flows explicit, since this is the heart of the design:

- **Content creators pay** the submission fee. They are the ones who benefit: approval is exposure — inclusion in the safe-search index that applications will query. This is the *decentralized SEO* side of the coin.
- **Moderators earn** fees by judging coherently. Their own stake is never at risk from voting, only from being wrong; honest judgment is the only strategy that is profitable in the long run. Anyone can join by staking; nobody employs them, and nobody assigns them work — a genuinely decentralized job created by a smart contract alone.
- **The fee sets the cohort size.** Since every eligible moderator may vote and the fee is split among the coherent, each additional voter takes a smaller share — so turnout naturally settles where the share is still worth the gas. The fee is therefore not just a price for review; it is the dial that decides how many people review. Setting it is a simulation deliverable.
- **Attackers fund the system** — through their own fees, never through anyone else's stake.
- **AI moderation is expected and welcome**, but someone still has to run each AI moderator, and that operator is compensated like any moderator.
- **The contract holds no idle treasury.** Fees in, stake credits out. No corporate budget is needed anywhere in the loop.
- **The index is a public good with replaceable ranking.** Because approvals live in transparent contract state, anyone can build a competing search or ranking algorithm over the same data — the opposite of opaque corporate SEO.

## 5. Architecture: four components

| # | Component | Description | Tech |
|---|-----------|-------------|------|
| 1 | **Moderation contract** | Four contracts (§ status note): the case state machine, permanent stake custody and the claim ledger, the permanent topic index, and timelocked governance | Solidity on Gnosis Chain |
| 2 | **Moderator interface** | Web GUI making contract interaction easy for working moderators: cases you are eligible for, content/metadata fetch from Swarm, commit/reveal voting, challenging, claiming, stake and bond status | Rust → WebAssembly |
| 3 | **Submit interface** | Web GUI for content creators: compose submission (content hash, metadata JSON validated against the schema, topics), pay fee, track status, resubmit | Rust → WebAssembly |
| 4 | **Search dapp** | Safe-search front end: query the approved index by topic via contract view functions; unopposed startpage mode (§3.8) and full superset view; ranking and presentation live client-side and are replaceable | Rust → WebAssembly |

**Gnosis Chain** is chosen deliberately: Bee already depends on it for xBZZ, and its minimal transaction fees are essential for a system built on many small votes, challenges, and fee payments.

On the moderator interface: it began as a human-facing GUI, but since many moderators will be AI, the machine-facing "interface" is the contract itself — rich events (new cases, commit phases closing, reveal deadlines, challenge windows), a published ABI, and a light client library so bots can watch and act cheaply. Eligibility in particular needs no infrastructure at all: a bot computes one hash per open case to know whether it may vote.

On **Rust → WebAssembly**: the plan that extracts the most value from this choice is a shared Rust/WASM core (CAC/BMT hashing, metadata schema validation, contract call encoding) reused by all three apps, with thin JavaScript interop at the wallet boundary, since browser wallet APIs are JavaScript regardless.

## 6. Further design decisions

Reviewed by the design owner and delegated to implementation discretion; treated as working decisions unless flagged.

**P1 — Removal requests.** *Implemented (v3).* Approvals must not be
irrevocable: content can later prove illegal, metadata can turn out to be bait,
Swarm storage can lapse. A removal is an ordinary case with `actionType = REMOVE`
— **the same engine, the same cohort, the same three tickets, the same challenge
round** — carrying its own claim key so it never collides with the listing it
targets. On the removal question an Approve vote means *take it out*; a successful
removal sets the original entry to `REMOVED`, drops it from the topic's listing,
and frees the content's reservation so it can be submitted again.

**The fee is paid whichever way it goes, and that is load-bearing rather than
tidy.** Refunding a *successful* removal looks like paying whoever corrects a
protocol error — but a removal is judged by the same engine at the same accuracy,
so a removal against legitimately listed content carries at the false-approval
rate, which is 60% at `prior` 0.665. Refund-on-success would make censorship free
in the majority of attempts at the accuracy this design must assume. **The fee is
the only thing pricing a censorship attempt.**

Repetition needs no extra cooldown: a failed removal permanently reserves its
`REMOVE` key, so an identical retry is refused outright, and the only recourse is
re-review, which carries the tally forward and is self-defeating.

**What remains open is supply, not mechanism.** Removals are in nobody's private
interest, and approving bad content and failing to remove it leave the index in the
same state while only the first is an action the protocol can price. Funding
removals from the original submission fee was considered and rejected — a standing
pot attached to every entry is a target to farm. See §7.

**P2 — Topic hygiene and a gas-safety cap.** Topics are normalized (lowercase, trimmed, NFC) and stored as keccak keys; a `TopicCreated(string)` event lets UIs autocomplete existing topics so "Biology" and "biology " don't fragment the index. Junk topics die by ranking (the search UI orders topics by approved-entry count), and moderation criteria include "the topics are accurate and themselves acceptable." Topics per submission are capped (~5, with the fee scaling per topic) — also because settlement loops over topics, and an unbounded loop can exceed the block gas limit, making a case *unfinalizable with its pot stranded*. That failure mode must be tested explicitly.

**P3 — Deduplication.** A claim key derived from `(actionType, contentHash,
metadataHash, topics)` that is already reserved is refused. `policyVersion` is
deliberately **excluded**, so a reservation survives a ruleset change. Every
identifier is content-derived and none is a counter, so replacing the logic
contract re-derives the same keys rather than colliding with what its predecessor
wrote — a lesson v1 paid a CRITICAL to learn.

Reservation follows the terminal: `APPROVED` holds it while listed, `REJECTED`
holds it permanently, an empty round releases it, and a thin one reserves it for a
cooldown. **Once a claim has been tallied, no reachable terminal releases its key**
— including a re-review that attracts nobody, which is a hole the implementation
found and closed.

**P4 — Metadata schema v1.** A versioned JSON schema (`/specs/metadata-v1.json`) defining type, title, description, topics, language, content type — written before any frontend, validated in the submit interface, checked by moderators ("metadata matches content").

**P5 — Moderation guidelines as the Schelling focal point.** Version 1 is deliberately one line: **"Would Google SafeSearch return this?"** — plus "the metadata honestly describes the content, and the topics fit." It lives in a versioned `MODERATION_GUIDELINES.md` whose hash is referenced on-chain; each case is judged per the version active at submission time, and the document grows only as real disputed cases show where one line isn't enough. Under coherence rewards, this document is what moderators are paid to predict the reading of — as load-bearing as the contract, and more so now that cohort size buys no accuracy of its own (§3.6).

**P6 — Governance, minimal and honest.** Core logic immutable; only bounded numeric parameters (cohort target, windows, the debit `d`, track-record decay, fee floor) adjustable behind a multisig with a timelock — and every parameter block is **pinned per case at submission**, so a change can never alter how an already-submitted case is judged or settled; withdrawals can never be paused. A "decentralized moderation" contract with an admin backdoor would be a contradiction, so the trust assumptions are stated rather than hidden.

**P7 — Latency honesty and optimistic display.** A published plurality arrives in about an hour; an unchallenged case finalizes in about thirteen, and a challenged one takes one more round. Hours, not minutes — which suits durable content (posts, videos, articles, anything where SEO matters) and does not suit real-time chat. Optimistic display falls out of the index status directly (§3.8): a `PLURALITY_*` entry renders as *provisional*, `APPROVED` as settled, and only `SUPER_SAFE` as the cautious filter — **settled is not certified**, and until `SUPER_QUORUM` is set from measurement the label is a filter rather than an assurance.

**P8 — Fee floor and a natural priority market.** The contract enforces `minFee = base + perTopic × nTopics`, covering storage and minimum voter pay across a full cohort. Submitters may overpay; moderators see fees and rationally prioritize high-fee cases — a priority market with zero extra protocol, and the mechanism by which a flood of minimum-fee junk gets judged last rather than blocking anything.

## 7. Open questions

### `prior` decides whether any of this is deployable

**This is not one open question among several. It is the one that decides the
rest**, and it is unmeasured.

`prior` is how often a moderator's judgment matches the truth. Every safety figure
in the design turns out to be a function of `q + (1 − q)(1 − prior)` — the *effective*
wrong-side share — and **not** of the attacker share `q` alone, because an honest
moderator who misjudges the content votes with the attacker and the tally cannot
tell them apart. Two consequences neither the mechanism nor a parameter can repair:

| `prior` | consequence |
|---|---|
| **≈ 0.95** | With no attacker at all, ~1.3% of unsafe content is approved and ~1.7% of safe content rejected. The design works, permanence is defensible, and grinding a listing by resubmission costs ~229 fees. |
| **≈ 0.665** | With **zero attackers**, ~29% of safe content is rejected — 22.8% of it with no recourse that can reach it — and ~29% of unsafe content approved. That is not a search index, and no state machine repairs it. |

`measurement/prior/` specifies how to measure it, and the instrument is the
**testnet**: it supplies independent votes for free, bands cases by difficulty
using the tally itself, and samples the real submission mix — which is the part a
hand-built corpus cannot fix at any budget, because `prior` is a property of
readers *and* of what they are shown. What must be supplied from outside is ground
truth, on a stratified sample.

**Write the guidelines you intend to ship before the testnet starts.** A rewrite
partway through fragments the data along `guidelinesVersion` — which is pinned per
case — and yields two underpowered samples instead of one usable one.

### The parameters that are still open

`BOND_MIN`, `CHALLENGE_BOND`, `GAS_ALLOWANCE`, `MATURATION`, `SUPER_QUORUM`,
`RETRY_COOLDOWN`, and `DRAW_BOUNTY`'s sizing. `specs/state-machine-v3.md` §10
carries each with the argument that constrains it. Two are worth naming here:

- **`BOND_MIN`** is what Sybil resistance actually costs, and several safety
  arguments inherit their strength from it.
- **`RETRY_COOLDOWN`** stopped being deferrable when the quorum gate was removed:
  it is now the only thing pricing a censor who holds every commit on a case and
  withholds them all (§4.8c).

### Structural questions with no measurement pending

**Reliability weighting is the largest unexploited lever, and its sign is
unknown.** Weighting votes by measured reliability rather than counting them
equally is worth 15–32 points of false approval at `prior` 0.665 — the largest
improvement anything measured here produces, and it pays *most* exactly where the
design is weakest. But the signal is farmable: an attacker never has to dodge a
known-answer case, because he can answer everything honestly except the one he is
attacking. Above a measured crossover (0.797 at `prior` 0.665) the same mechanism
runs in reverse at comparable magnitude, and no weight cap removes it.
`simulation/v3/FINDINGS-weighted.md` has the full result. **Deliberately not in the
spec** until the crossover is measured.

**Cost of corruption is not stated.** An attacker's prize — the listing — is
external and unbounded, while a moderator's reward is a slice of a submission fee.
The design has no published cap on the value it will secure, and both the weighting
crossover and the pricing of any bond are really the same missing number.

**Removal supply.** Removals now exist as a real case type, and a removal is paid
for whichever way it goes so it cannot be used as free censorship. But nobody's
private interest is served by cleaning the index, so removals are undersupplied.
Whether removal needs a *role* rather than a price — someone paid from a pool to
look for removable content — is open, along with where that pool comes from without
reintroducing a farmable target.

**Repeated submission of rejected content.** A rejected case reserves its claim key
permanently, and re-review is the recourse — but the key binds *bytes*, not
*meaning*, so a trivially altered resubmission is a different claim. Pooled tallies
close retry *within* a claim; they do not close it across near-duplicates.

**Turnout under self-selection.** Nobody is obligated to vote, so the cohort that
votes is the subset that chose to. If honest moderators are apathetic while
attackers are always motivated, the population skews toward whoever cares most.
The counterweight is that voting pays; whether it pays enough, reliably enough, is
a fee-level question the testnet answers alongside `prior`.

Also open: long-term topic-namespace governance; who maintains the guidelines
document and how updates are ratified; repository license and organizational
ownership; moderator privacy; and the migration from the in-contract index to a
Swarm-feed-published one.

## 8. Roadmap

**M1 — Specification and simulation.** *Complete.* This writeup, a formal state-machine spec of the contract, the metadata schema, the guidelines document, and an agent-based simulation of the attack scenarios — *before any Solidity is written*, so parameters come from numbers rather than intuition.

**M2 — Contract (first architecture).** *Implemented and audited (`contracts/`, Foundry).* A complete Solidity implementation of the assigned-panel design: staking with a free/committed/frozen partition, a stake-weighted sortition tree (a clean 0.8.x port of Kleros's MIT sum-tree), the case lifecycle with two-seed randomness, an opt-in duty pool with penalties for drawn moderators who fail to serve, bonded appeals escalating through larger panels, the solvent settlement order, a permanent index and stake registry that survive replacing the game logic, and timelocked governance. 274 tests including a handler-driven invariant campaign (funds conservation, no internal transfer), a 52-vector differential regression test, and gas-bound tests. Spec departures are catalogued in `contracts/DEVIATIONS.md`.

Two external audits and a substantial internal remediation pass ran against it. They agreed on where the design was strong — permanent registries, case-scoped obligations, bounded loops, pinned rulesets — and on where it was not: **assigning moderators to cases creates a resource an attacker can exhaust**, and holding that assignment for the whole case lifetime rather than the moderator's actual work multiplies the problem. Section 3 is the answer to that finding.

**What carries forward:** the permanent stake and index registries and their migration model; the probabilistic verdict; commit-reveal with domain-separated commitments; the settlement solvency ordering; the index fields and the unopposed view; the deduplication model; governance. **What it replaces:** the seat draw, the duty pool and no-show penalties, obligation accounting, escalating panel sizes, and bonded appeals.

**M2.5 / M2.6 — Contract (second architecture).** Hash eligibility, fixed-window
voting with no assignment, pooled tallies, risk units, serial freezes. Specified in
`specs/design-v2.md` and `specs/state-machine-v2.md`. **Superseded before it was
completed**: freezes made penalties settlement-order-dependent, and risk units
priced concurrency with a reservation the design could not justify.

**M2.7–M2.13 — Contract (v3, current).** *Built.* Four contracts in
`contracts/src/v3/`, specified normatively by `specs/state-machine-v3.md`:

| | what it replaced |
|---|---|
| Three-ticket majority against `â = (A+1)/(N+2)` | the proportional lottery, and the quorum gate with it |
| One randomness per claim, drawn last | per-round draws, which made a challenge a free re-roll |
| Balance debits | identity freezes, which did not commute |
| Bonded challenge, no eligibility test, no disclosed direction | the challenge-as-public-vote |
| Pull settlement per moderator | the per-case sweep, whose cost was unbounded and whose funding was not |
| Removal cases (`actionType`) | nothing — a listed entry previously had **no recourse at all** |

Checked by 266 tests: per-contract suites, **stateful invariants over all four real
contracts under a fuzzer**, the draw swept rather than sampled, a **two-implementation
differential** on the verdict derivation, and mutation campaigns as the acceptance
bar rather than a metric. `contracts/DEVIATIONS.md` catalogues every place the
implementation departed from, refined, or pinned something the spec left open.

**Not yet independently reviewed.** That is the next step and the standing
constraint holds until it passes.

**M3 — Interfaces.** The three web apps on a shared Rust/WASM core, in dependency order: moderator interface first (without moderators nothing gets approved), then the submit interface (creators feed the pipeline), then the search dapp (proves the end-to-end value) — plus the client library for AI moderators.

**M4 — Launch.** Review/audit of the M2.5 contracts, deployment to Chiado (Gnosis testnet), then a guarded mainnet launch with conservative caps.

---
