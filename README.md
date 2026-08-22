# Decentralized Moderation

*A staking-based moderation market and safe-search index for [Swarm](https://www.ethswarm.org/), governed entirely by a smart contract.*

Content publishers pay a fee to be moderated. Staked moderators (human or AI) judge submissions in a Schelling game: for each case a random subset of moderators becomes eligible to vote, outcomes are drawn with probability proportional to the votes behind each side, and anyone who disagrees can challenge — putting their own stake behind the objection and adding a fresh cohort of voters to the tally. Approved content is recorded in an on-chain, topic-indexed registry that powers safe search — with no company in the middle.

This document sums up the aim of the project, the problems we are solving, and how we intend to solve them; section 3.6 documents the attack analysis that shaped it. All concrete numbers (stakes, cohort sizes, periods, fees) are current working values, not final protocol parameters — fixing them is what the simulation milestone is for.

> **Implementation status.** Section 3 describes the protocol as currently designed; `specs/design-v2.md` carries the full mechanism and its arithmetic, including the payout derivation. The Solidity in `contracts/` implements an *earlier* architecture — one where panels were actively drawn and drawn moderators were obligated to serve. It is complete, tested and audited, and it is the reason the current design exists: building it is what exposed the capacity problem section 3.6 now opens with. See §8 for what carries forward and what it replaces.

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

Five principles, made explicit because every rule below follows from them:

1. **Safe for moderators.** Voting never risks capital — the worst case for an honest moderator on the losing side of a genuinely borderline call is being frozen for a while. Hard cases exist; judging them must not be financially ruinous, or nobody sane moderates.
2. **Zero internal attack profit.** Stake is never slashed or redistributed between moderators. A redistribution rule would let a majority attacker farm honest minorities (stake 200 moderators against 100, win, harvest their stakes) — the mechanism itself would mint the attack's reward. Here, all rewards are *external* money: submission fees. An attacker's only possible prize is the listing itself.
3. **Nobody is conscripted.** No moderator is ever assigned to a case, bound to one, or penalised for ignoring one. Eligibility is an opportunity, never a duty. This is what makes the queue unfloodable, and it is why there is no no-show penalty anywhere in the design: there is no show to fail to make.
4. **The verdict never moves the *cash*.** A moderator is paid the same for judging a case whichever way the case goes. Money whose existence depends on the verdict must never reach the people choosing the verdict — otherwise the mechanism buys the answer it pays for. (Coherence still matters: voters coherent with the final outcome are paid and incoherent ones are frozen. What must not vary is *approve versus reject*.) **This holds for the payment and not yet for the penalty.** Suspension length scales with the winning side's track record (§3.5), so voting against a well-established bloc costs more in expectation than voting against newcomers — total utility is direction-dependent even where cash is not. That is a known gap between the principle and the mechanism, not a property the design has earned; `specs/v2-audit-triage.md` D4 carries the decision.
5. **Trust is earned, not bought.** A track record of coherent participation is what makes a moderator identity worth keeping — it drives freezing power, and it is what a moderator forfeits by abandoning an identity to escape a penalty. Fresh capital has none.

### 3.1 Moderators and staking

Anyone becomes a moderator by staking **10 xBZZ** — a flat amount, the same for everyone. Stake exists in three states: **free** (withdrawable after an exit cooldown of ~7 days, so pending judgments always settle first), **committed** (backing votes in open cases), and **frozen** (locked as a penalty, see 3.5). Stake is never destroyed or transferred away — principle 2.

**One stake, one vote, unlimited concurrent cases.** A moderator's stake is not divided between the cases they are judging. It backs all of them at once, and there is no cap on how many cases a moderator may be voting in simultaneously. The scarce resource is the moderator's attention, which the protocol has no business rationing.

Staking more than the minimum buys nothing. Voting power is flat per identity, so influence is bought by running more moderator identities, each costing its own 10 xBZZ — which means influence still costs capital linearly, but no single account accumulates a large voice. Identities are cheap to create and, by design, expensive to *replace*: a fresh identity carries no track record (principle 5) and cannot vote until its stake matures, so abandoning a frozen identity for a new one costs both the waiting period and the accumulated standing.

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

The threshold `T` is read from live state as `MAX / totalModerators × targetCohort`, so the number of eligible moderators stays near its target (working value: **32**) however large the moderator set grows. `caseSeed` is a blockhash from a few blocks after submission, realized lazily by the first vote and re-armed if it ages out — so the eligible set is unknowable when the case is submitted, and a submitter cannot grind the case id to select a friendly cohort.

**Everyone eligible may vote, within a fixed window.** Voting is not first-come: the window is a fixed **commit-reveal** period (working values: 24h commit, 24h reveal), every eligible moderator may participate for its whole duration, and votes are counted regardless of arrival order. This matters more than it looks — if only the first *n* votes counted, an attacker holding a minority of the cohort could decide cases by being fast, and speed is the one advantage a well-resourced attacker always has. A fixed window makes it worthless.

Eligible moderators who do not vote are not penalised in any way. They are simply not paid.

**A quiet case widens itself.** `T` grows slowly with the age of an unresolved case, so the eligible set expands until somebody judges it. There is no re-draw, no extra transaction, and no widening logic — just a threshold that is a function of time. High-fee cases attract voters immediately; a case nobody finds worth judging waits, gradually offering itself to more of the network, and the submitter can reclaim the fee if it never attracts anyone.

### 3.4 Probabilistic outcomes and challenges

The revealed votes are tallied, and the round's outcome is **drawn with probability proportional to the votes on each side**: if approve-votes are twice reject-votes, approve wins with 2/3 probability. A unanimous round needs no luck — one side holds every vote. Equivalently, and more intuitively: *the verdict is one revealed vote, picked at random.*

The result is preliminary. A **challenge window** follows (working value: 3 days; the first window 4 days, so long holiday weekends cannot decide outcomes). During it, any moderator eligible for the next round may open a **challenge**, which is simply a vote against the preliminary verdict, cast in public. No bond is posted and no fee is paid — the challenger's own stake is the stake, and it rides on the outcome: if the verdict is upheld, the challenger is frozen like any other incoherent voter. Opening a challenge while *agreeing* with the verdict is not possible, since a challenge is by definition a vote against it.

That is the whole disincentive against frivolous challenges, and it is enough. A challenge you expect to lose costs you a freeze; a challenge you expect to win is free and pays.

**Votes accumulate; rounds do not replace each other.** The challenge opens a fresh commit-reveal period for a fresh cohort — a different eligible set, drawn from the same population by the same hash with the round number mixed in. When it closes, **every revealed vote from every round of the case is pooled into a single tally**, and the verdict is drawn from that pool.

This is the most important structural decision in the design, and it exists to defeat retry. If each challenge round *replaced* the last, every challenge would be a fresh roll of the dice at unchanged odds, and an attacker holding 30% of the network would need only to keep challenging: four attempts reach 76%, ten reach 97%. Probabilistic defence would become a formality. With a cumulative tally, an attacker's share of the pool stays at their share of the network no matter how many rounds happen. **The dice cannot be re-rolled.**

It also produces the behaviour you would want anyway: a 30–2 first round cannot be overturned by one more cohort, while a 17–15 first round flips easily. Challenge power is proportional to how genuinely contestable the verdict was, and the process self-terminates — once the pooled tally is lopsided, another round cannot move it and nobody bothers to try.

For the same reason, cohorts stay the **same size** each round rather than escalating. Equal cohorts dilute each round's influence naturally, which is what makes the tally converge instead of swing.

If a window closes with no challenge, the case **finalizes**. Clear-cut content is decided in about two days plus one quiet window.

### 3.5 Settlement — the fee to the coherent, freezing for the rest

Finalization is triggered by a **claim** transaction anyone may send after the last window (earning a small bounty from the pot). Then, across all rounds of the case:

- **The pot — the submission fee — is split among voters coherent with the final outcome**, credited as bookkeeping to their in-contract stake balances. No per-moderator transfers: the money already sits in the contract, so the token balance always equals stakes plus open pots, and gas stays flat. The share is the same whichever way the verdict went (principle 4), and it is the same for a first-round voter and a challenge-round voter. **Precisely: for a given final tally, expected payment is `pot / turnout` whichever way you vote** — proved in `specs/design-v2.md` §4.2. That is a statement about the cash, holding the final pool fixed. It does not cover how a vote changes whether a challenge opens, how many rounds run, or how large the final pool becomes, and it does not cover the suspension cost, which is not direction-neutral (principle 4).
- **Voters incoherent with the final outcome are frozen.** Freeze duration scales with the **freezing power** of the winning side: a base week, multiplied up to a cap by the winners' track record — a decayed, capped count of past coherent participations. A newcomer that wins a round freezes honest veterans only briefly, while veterans who defeat an attack lock its capital up for a long time.

**Freezes stack.** A moderator penalised in three cases sits out the sum of the three terms, not the longest of them. This is what makes the penalty proportional under unlimited concurrency: since one stake backs any number of cases, a penalty that could only be served once would be diluted to nothing by an attacker voting in many cases at once. Time is the currency that does not dilute.

While frozen, a moderator is ineligible for new cases — but **votes already cast still count**, and cases already joined run to completion normally. The freeze removes future participation, never past judgment.

No stake moves from loser to winner — freezing is pure deterrence by locked funds, never a bounty. That is what makes "attack anyway and farm the punishment" impossible by construction.

### 3.6 Design rationale — how attacks are priced

The mechanism above survived several adversarial redesigns and two external audits; recording the reasoning so future contributors don't re-walk the same dead ends.

**Why nobody is assigned to a case.** The first architecture drew a panel and obligated the drawn moderators to serve, penalising them if they didn't. That is a natural design and it has a fatal property: the assignment is a *resource*, and an attacker can consume it by opening cases. With moderators at the minimum stake and a five-seat panel, a hundred moderators support twenty concurrent cases; the hundred-and-first submission queues behind them, and the attacker has bought a denial of service at the price of the fees. Every fix within that model — shorter locks, higher fees, more capacity — makes the attack more expensive without making it impossible, because the resource still exists. Removing the obligation removes the resource. This is the single largest change from the implemented contracts, and it came out of the capacity analysis in §8's audits.

**Why not deterministic majority?** An attacker who knows it holds a majority attacks with engineered certainty. Probabilistic outcomes mean *every* attack, however funded, can lose any round — there is no safe attack, only priced gambles. And attackers who would only attack with an assured majority are exactly the ones the probability draw deters.

**Why not slash and redistribute losing stakes?** Because redistribution mints the attack's profit: with 100 honest moderators, staking 200 attacking ones and winning would *harvest the honest stakes*. Punishment-as-bounty invites punishment-farming. Kleros-style systems paper over this with a meta-incentive — corrupt the court and its token crashes, destroying the attacker's capital — but that defense doesn't survive contact with a short position, and our stake token (xBZZ) doesn't depend on this contract anyway. So: no reliance on token-value arguments at all. The defense is structural — there is simply no internal transfer to farm.

**What a larger cohort does, and what it does not.** Under a proportional lottery, an attacker holding fraction *q* of the network wins any single round with probability *q* — and that is true whether the cohort is 5 or 32 or 200. Larger cohorts do **not** amplify the majority's judgment the way majority voting does; there is no Condorcet effect here, and it would be dishonest to imply one. What they do buy is the collapse of *complete* capture (the chance an attacker holds every revealed vote falls as *qⁿ*), much lower variance, and a far better chance that both readings of a borderline case are actually represented. Accuracy comes from the guidelines being a clear Schelling point, not from cohort size.

**Where does the attack cost actually live?** Three places. **Retry is closed**: pooled tallies mean a second challenge does not reset the odds, so an attacker cannot convert a 30% chance into a certainty by paying repeatedly — the property that a per-round-replacement design would have handed them. The **freeze drag**: every lost round locks the attacker's identity, losing to established honest moderators locks it for a long time, and penalties from concurrent cases stack rather than overlap. The **absence of prize**: winning pays the attacker nothing from the mechanism — the only upside is the listing itself, and a listing bought through visible challenge wars is exactly the kind an honest challenger re-litigates.

**Why identity churn does not defeat the freeze.** Freezing an identity is only a punishment if replacing it is expensive. A fresh identity costs the 10 xBZZ minimum, which alone would be a poor deterrent — so two things make replacement costly rather than cheap: new stake cannot vote until it matures (at least as long as the minimum freeze, so churning buys nothing a wait would not), and track record does not transfer (principle 5), so an abandoned identity abandons its earning power with it. This makes reputation load-bearing rather than decorative, and the exact weight is a simulation deliverable (§7).

**What does an honest moderator's life look like?** Judge clearly-safe and clearly-unsafe content: earn fees, essentially risk-free (unanimous rounds have no lottery, unchallenged results just finalize). Judge borderline content honestly and lose the draw: frozen for a while — annoying, never ruinous (principle 1). Spot a wrong outcome: challenge it, and if the pooled tally moves your way you are paid rather than frozen. Ignore a case entirely: nothing happens to you at all. The profitable long-run strategy is judging the way any other honest reader of the guidelines would — a Schelling point on honest judgment.

### 3.7 Randomness

MVP: `blockhash` of a snapshot block a few blocks past the relevant phase boundary, realized lazily by the first transaction that needs it and domain-separated per case, round and purpose. (The design draft said `block.prevrandao`; the EVM cannot read a past block's `prevrandao`, so `blockhash` is what the contract uses — `specs/state-machine.md` §7 and `contracts/DEVIATIONS.md` D-1.) Proposer manipulation is real: a proposer can influence the eligible cohort and the outcome draw. An earlier claim bounded its value by per-case pot size; that is wrong, because the attacker's prize is the **listing** itself, whose SEO value no pot cap bounds. It is an accepted MVP assumption — small per-case leverage on the Gnosis proposer set, and a biased listing stays challengeable — with a VDF or randomness-oracle upgrade path if listing value grows large.

### 3.8 Publication and search

Search has an easy way and a hard way; **we take the easy way first to reach an MVP**, and optimize later.

**Easy way (MVP):** when a case **settles** as an approval, its entry is written to an **in-contract map: topic → vector of approved entries** (writing at settlement rather than at the first round's tally is what lets an approval *won on challenge* be indexed at all, and keeps provisional entries out of the index entirely). Each entry carries the content hash, the metadata hash, the **time of approval**, and two booleans: **`uncontested`** and **`fullQuorum`**.

`uncontested` is `true` **iff no `Reject` vote was ever revealed, in any round of the case**. Since a challenge *is* a reject vote, a challenged entry is never uncontested — which is simpler than the previous rule, where an appeal could be filed without any vote behind it. The flag marks entries *no dissenting voter ever opposed*, and a unanimous tally involves no probabilistic draw to get lucky in.

`fullQuorum` is `true` iff the pooled tally reached at least `MIN_REVEALS` votes. Because voting power is flat and one identity casts one vote, distinct votes are distinct moderators by construction — the old caveat about a multi-seat voter satisfying quorum alone no longer applies. If a challenge ends in rejection, the entry is removed at settlement. A submission with multiple topics costs proportionally more, since more contract storage is written. The search dapp then serves queries entirely from **contract view functions against the latest state** — no scraping of historical logs, no off-chain indexer infrastructure.

**Two views of the index.** The system has probabilistic outcomes, and a safe-search product must be honest about that. The extra fields split the index into:

- the **superset** — everything currently approved by the system, including entries that won contested, probabilistic draws; and
- the **unopposed subset** — the cautious mode: `uncontested && fullQuorum && now − approvalTime ≥ 96h`. No `Reject` vote was ever revealed against it in any round, the pooled tally cleared `MIN_REVEALS`, and it has stood approved for 96 hours — the length of the first challenge window, so an approval that was going to be overturned has, in the ordinary case, already been overturned and removed.

  **Read that definition literally, because the earlier name for it did not.** `fullQuorum` means the pooled tally reached `MIN_REVEALS` — a working value of **five** — not that a full 32-moderator cohort turned out. Five unanimous votes from one operator satisfy both flags. This subset is *unopposed at minimum quorum*, which is a useful filter and is not a certificate; it was previously called "supersafe" and described as close to certainty, which the definition does not support. Clients that need a real assurance bar should require an absolute vote count and turnout rate of their own choosing, from the fields below.

The voting system stays meaningful for everything contested; the unopposed view gives cautious front ends (a default startpage, a kids-mode client) a subset in which no dissent was ever recorded. It is a floor to build on, not a safety guarantee — a client aiming at children's use should layer its own absolute thresholds on the counts.

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
| 1 | **Moderation contract** | Staking, hash-based eligibility, commit-reveal voting, probabilistic outcomes over pooled tallies, challenges, track-record bookkeeping, freeze accounting, fee pots, topic → approvals index | Solidity on Gnosis Chain |
| 2 | **Moderator interface** | Web GUI making contract interaction easy for working moderators: cases you are eligible for, content/metadata fetch from Swarm, commit/reveal voting, challenging, claiming, stake and freeze status | Rust → WebAssembly |
| 3 | **Submit interface** | Web GUI for content creators: compose submission (content hash, metadata JSON validated against the schema, topics), pay fee, track status, resubmit | Rust → WebAssembly |
| 4 | **Search dapp** | Safe-search front end: query the approved index by topic via contract view functions; unopposed startpage mode (§3.8) and full superset view; ranking and presentation live client-side and are replaceable | Rust → WebAssembly |

**Gnosis Chain** is chosen deliberately: Bee already depends on it for xBZZ, and its minimal transaction fees are essential for a system built on many small votes, challenges, and fee payments.

On the moderator interface: it began as a human-facing GUI, but since many moderators will be AI, the machine-facing "interface" is the contract itself — rich events (new cases, commit phases closing, reveal deadlines, challenge windows), a published ABI, and a light client library so bots can watch and act cheaply. Eligibility in particular needs no infrastructure at all: a bot computes one hash per open case to know whether it may vote.

On **Rust → WebAssembly**: the plan that extracts the most value from this choice is a shared Rust/WASM core (CAC/BMT hashing, metadata schema validation, contract call encoding) reused by all three apps, with thin JavaScript interop at the wallet boundary, since browser wallet APIs are JavaScript regardless.

## 6. Further design decisions

Reviewed by the design owner and delegated to implementation discretion; treated as working decisions unless flagged.

**P1 — Removal requests.** Approvals must not be irrevocable: content can later prove illegal, metadata can turn out to be bait, Swarm storage can lapse. Anyone may submit a *removal request* targeting an existing index entry — same fee, same eligibility, outcomes and challenges; if removal wins, the entry is deleted from the index.

**A removal costs its own fee, and we know this is the weak point.** A challenge says *this decision was wrong when it was made*, and the original fee can pay for it because it is a dispute about a judgment someone already bought. A removal says *this was fine and the situation has changed* — new law, a lapsed host, a rights claim — and no earlier fee anticipated it. Charging the requester keeps the mechanism neutral and stops removal spam, but it means removals are undersupplied: they are in nobody's private interest, and approving bad content and failing to remove bad content leave the index in the same state while only the first is an action the protocol can price. Funding removals from the original submission fee was considered and rejected — a standing pot attached to every entry is a target to farm. This is an accepted limitation with an open design question behind it (§7), not a solved problem.

There are two routes, differing only in how the target is named. `submitRemoval(targetCaseId)` names a case this game contract adjudicated, and removes that submission from every topic it was indexed under. `submitLegacyRemoval(globalEntryId)` names a single entry by its permanent registry id, and exists because the index outlives the game: after a logic upgrade the replacement contract holds no case record for anything its predecessor approved, so without an id-addressed route every inherited entry would be permanently unadjudicable. Either way the payload and topics come from stored state rather than the caller, so what a client displays is what settlement acts on, and a winning removal frees the content's deduplication reservation so it can be submitted again.

**P2 — Topic hygiene and a gas-safety cap.** Topics are normalized (lowercase, trimmed, NFC) and stored as keccak keys; a `TopicCreated(string)` event lets UIs autocomplete existing topics so "Biology" and "biology " don't fragment the index. Junk topics die by ranking (the search UI orders topics by approved-entry count), and moderation criteria include "the topics are accurate and themselves acceptable." Topics per submission are capped (~5, with the fee scaling per topic) — also because settlement loops over topics, and an unbounded loop can exceed the block gas limit, making a case *unfinalizable with its pot stranded*. That failure mode must be tested explicitly.

**P3 — Deduplication.** A submission key `H(contentHash, metadataHash, topicKey)` that already exists is rejected. Same content in genuinely different topics remains possible — each costs a separate fee, so spam self-limits. The reservation is held by the permanent index registry, not by the game contract, so it is exactly as permanent as the index entry it protects: replacing the logic contract does not reset it, and content already live in the index cannot be re-submitted by a new version. A reservation is released only by the case that took it — when that case is rejected, voided, or its entry is removed.

**P4 — Metadata schema v1.** A versioned JSON schema (`/specs/metadata-v1.json`) defining type, title, description, topics, language, content type — written before any frontend, validated in the submit interface, checked by moderators ("metadata matches content").

**P5 — Moderation guidelines as the Schelling focal point.** Version 1 is deliberately one line: **"Would Google SafeSearch return this?"** — plus "the metadata honestly describes the content, and the topics fit." It lives in a versioned `MODERATION_GUIDELINES.md` whose hash is referenced on-chain; each case is judged per the version active at submission time, and the document grows only as real disputed cases show where one line isn't enough. Under coherence rewards, this document is what moderators are paid to predict the reading of — as load-bearing as the contract, and more so now that cohort size buys no accuracy of its own (§3.6).

**P6 — Governance, minimal and honest.** Core logic immutable; only bounded numeric parameters (cohort target, vote counts, windows, freeze base and cap, track-record decay, fee floor) adjustable behind a multisig with a timelock; withdrawals can never be paused. A "decentralized moderation" contract with an admin backdoor would be a contradiction, so the trust assumptions are stated rather than hidden.

**P7 — Latency honesty and optimistic display.** Unchallenged content finalizes in about two days plus one challenge window — days, not minutes. That suits durable content (posts, videos, articles, anything where SEO matters) and does not suit real-time chat. Deep disputes take longer, but they are rare and self-funding. Optimistic display falls out of the index fields directly (3.8): entries younger than 96 hours or contested render as *provisional*; entries passing the unopposed filter render with the settled badge — settled, not certified.

**P8 — Fee floor and a natural priority market.** The contract enforces `minFee = base + perTopic × nTopics`, covering storage and minimum voter pay across a full cohort. Submitters may overpay; moderators see fees and rationally prioritize high-fee cases — a priority market with zero extra protocol, and the mechanism by which a flood of minimum-fee junk gets judged last rather than blocking anything.

## 7. Open questions

**Parameters are simulation output, not opinions.** The cohort target and its threshold curve, the age-widening rate, `MIN_REVEALS`, the freeze base and cap, the track-record formula (decay rate, saturation, anti-farming), commit and reveal windows, and the fee floor — all working values until simulation validates them against the attack scenarios.

**How much reputation should be worth.** This is the most load-bearing open number in the design. Track record carries three jobs at once: it sets freezing power (§3.5), it makes abandoning a frozen identity expensive (§3.6), and it makes running one well-regarded identity better than running several anonymous ones. Too weak and the freeze stops deterring anything; too strong and the system ossifies around incumbents. Needs adversarial simulation, not a guess.

**Track-record farming.** Freezing power derives from participation history, and history can be manufactured: self-submit innocuous content, judge it honestly, repeat. The cap and decay bound the damage, and farming costs real fees the honest side collects — but the exact formula needs adversarial simulation before it's trusted.

**Turnout under self-selection.** Nobody is obligated to vote, so the cohort that actually votes is the subset that chose to. If honest moderators are apathetic while attackers are always motivated, the voting population skews toward whoever cares most — and the verdict is drawn from votes cast, not votes possible. The counterweight is that voting pays; whether it pays enough, reliably enough, is exactly what the fee-level simulation has to establish.

**Removal supply.** Charging the requester keeps removals neutral and unspammable but leaves them undersupplied, since nobody's private interest is served by cleaning the index (P1). The open question is whether removal needs a *role* rather than a price — someone paid from a pool to look for removable content — and where that pool comes from without reintroducing a farmable target.

**Repeated submission of rejected content.** A rejected case releases its deduplication reservation, so identical content can be resubmitted for a fresh base fee. Pooled tallies close retry *within* a case; they do not close it *across* cases. Persisting per-content review history in the permanent index — attempt counts, last outcome, escalating fees or cooldowns for unchanged content — is the likely answer and is not yet designed.

Also open: long-term topic-namespace governance; who maintains the guidelines document and how updates are adopted; repository license and organizational ownership; moderator privacy (addresses are permanently linked to controversial decisions — the guidelines should recommend fresh addresses per moderator identity, which interacts with reputation weight above); and the migration path from the in-contract index to a Swarm-feed-published index.

## 8. Roadmap

**M1 — Specification and simulation.** *Complete.* This writeup, a formal state-machine spec of the contract, the metadata schema, the guidelines document, and an agent-based simulation of the attack scenarios — *before any Solidity is written*, so parameters come from numbers rather than intuition.

**M2 — Contract (first architecture).** *Implemented and audited (`contracts/`, Foundry).* A complete Solidity implementation of the assigned-panel design: staking with a free/committed/frozen partition, a stake-weighted sortition tree (a clean 0.8.x port of Kleros's MIT sum-tree), the case lifecycle with two-seed randomness, an opt-in duty pool with penalties for drawn moderators who fail to serve, bonded appeals escalating through larger panels, the solvent settlement order, a permanent index and stake registry that survive replacing the game logic, and timelocked governance. 274 tests including a handler-driven invariant campaign (funds conservation, no internal transfer), a 52-vector differential regression test, and gas-bound tests. Spec departures are catalogued in `contracts/DEVIATIONS.md`.

Two external audits and a substantial internal remediation pass ran against it. They agreed on where the design was strong — permanent registries, case-scoped obligations, bounded loops, pinned rulesets — and on where it was not: **assigning moderators to cases creates a resource an attacker can exhaust**, and holding that assignment for the whole case lifetime rather than the moderator's actual work multiplies the problem. Section 3 is the answer to that finding.

**What carries forward:** the permanent stake and index registries and their migration model; the probabilistic verdict; commit-reveal with domain-separated commitments; the settlement solvency ordering; the index fields and the unopposed view; the deduplication model; governance. **What it replaces:** the seat draw, the duty pool and no-show penalties, obligation accounting, escalating panel sizes, and bonded appeals.

**M2.5 — Contract (current architecture).** Implementing §3: hash eligibility, fixed-window voting with no assignment, pooled tallies across challenge rounds, stake-backed challenges, serial freezes, flat stake. The design and its arithmetic are in **`specs/design-v2.md`**, and the normative state machine in **`specs/state-machine-v2.md`** — including the proof that a moderator's expected payout is the same whichever way a verdict goes, the corollary that this forces the lottery to stay linear, and the order-independent reputation update. A normative state-machine specification follows that document; Solidity follows the specification.

**M3 — Interfaces.** The three web apps on a shared Rust/WASM core, in dependency order: moderator interface first (without moderators nothing gets approved), then the submit interface (creators feed the pipeline), then the search dapp (proves the end-to-end value) — plus the client library for AI moderators.

**M4 — Launch.** Review/audit of the M2.5 contracts, deployment to Chiado (Gnosis testnet), then a guarded mainnet launch with conservative caps.

---
