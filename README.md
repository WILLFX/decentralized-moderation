# Decentralized Moderation

*A staking-based moderation market and safe-search index for [Swarm](https://www.ethswarm.org/), governed entirely by a smart contract.*

Content publishers pay a fee to be moderated. Staked moderators (human or AI) judge submissions in a Schelling game: random subsets vote, outcomes are drawn with probability proportional to the stake behind each side, and disputes escalate through bonded appeals to fresh, larger subsets. Approved content is recorded in an on-chain, topic-indexed registry that powers safe search — with no company in the middle.

This document sums up the aim of the project, the problems we are solving, and how we intend to solve them, section 3.6 documents the attack analysis that shaped it. All concrete numbers (stakes, subset sizes, periods, bond schedules) are current working values, not final protocol parameters — fixing them is what the simulation milestone is for.

## 1. Why this exists

Swarm **feeds** make permissionless publishing trivial. A feed is defined by an owner key and a 32-byte topic. In the *anythread* pattern, any URL (or any string) is hashed to derive both a feed owner key and a topic — and because anyone who knows the string can derive the same key, anyone can write to the feed and anyone can read it. The result is commenting, blogging, and annotation on top of any subject, with no user registry, no server, and no operator.

The flip side of "anyone can write" is that anyone can write anything;Centralized platforms (Facebook, YouTube, Meta at large) solve this by employing moderators in large numbers, increasingly assisted by AI — paid out of a corporate budget. A decentralized system has **no corporation and no budget**. Consuming unmoderated feeds means consuming out-of-control filth, which makes the whole publishing layer unusable for ordinary applications.

What is missing is a mechanism where **the people who want to publish pay a group of moderators — a group anyone can join as a form of work** — to certify that content is (1) safe (SFW, in the spirit of common community guidelines or what a safe-search filter would pass) and (2) relevant to the topics it claims. That mechanism turns moderation from a corporate cost center into an open, paid job that requires nothing but a smart contract. And its by-product is something the decentralized web currently lacks entirely: **safe search**.

## 2. The problems we are solving

**Moderation without a corporation.** Anyone can stake and become a moderator; moderators are paid per judged submission out of submission fees. There is no budget and no employer — the fee flow is the payroll. Moderators may be humans clicking through a web interface, but most will probably be AI classifiers. That changes nothing economically: somebody has to *run* each AI moderator, and that somebody is compensated like any moderator, because operating a moderation service is work — this is a job either way.

**Safe search over permissionless content.** Every finalized approval is recorded on-chain under its topics. A search front end can then answer "show me every entry approved in the category *xy*" — the primary example being exactly what Google SafeSearch does, but for content no company controls. Without this filter layer, permissionless publishing drowns and becomes unusable.

**Decentralized SEO.** Approval is exposure: paying the submission fee buys review, and passing review buys a place in the searchable index. This is search-engine optimization with the incentives on the table — the index is public and transparent, and the ranking algorithm is **replaceable**: anyone can build a different search or ranking application over the *same* on-chain data set. No black-box algorithm decides who gets seen.

**Attack-resistant judging.** No outcome can be engineered with certainty (every round resolves probabilistically), no proportion can be predicted (every round samples a fresh random subset), and no attack pays from the inside (the mechanism never transfers stake between moderators — there is nothing to farm). Persistence costs escalating bonds that flow to honest voters when the attack fails.

## 3. The core mechanism

### Design principles

Four principles, made explicit because every rule below follows from them:

1. **Safe for moderators.** Voting never risks capital — the worst case for an honest moderator on the losing side of a genuinely borderline call is being frozen for a while. Hard cases exist; judging them must not be financially ruinous, or nobody sane moderates.
2. **Zero internal attack profit.** Stake is never slashed or redistributed between moderators. A redistribution rule would let a majority attacker farm honest minorities (stake 200 moderators against 100, win, harvest their stakes) — the mechanism itself would mint the attack's reward. Here, all rewards are *external* money: submission fees and forfeited appeal bonds. An attacker's only possible prize is the listing itself.
3. **Risk at every step for attackers.** Outcomes are drawn with stake-proportional probability, so even an engineered majority can lose any round; subsets resample each round, so global stake proportions predict nothing locally.
4. **Trust is earned, not bought.** A track record of coherent participation grants *freezing power* — the ability to punish opponents with longer freezes. Fresh capital has none: a newcomer whale that wins hurts honest moderators only briefly, while established honest moderators who win against an attacker hurt it badly.

### 3.1 Moderators and staking

Anyone becomes a moderator by staking a minimum of **10 xBZZ** in the contract. Stake exists in three states: **free** (withdrawable after an exit cooldown of ~7 days, so pending judgments always settle first), **committed** (backing votes in open cases), and **frozen** (locked as a penalty, see 3.5). Stake is never destroyed or transferred away — principle 2.

### 3.2 Submissions

A moderation request contains three things:

1. the **CAC hash of the content** — a content-addressed chunk hash, deliberately *not* a single-owner chunk (SOC), because a SOC would allow bait-and-switch: getting something innocuous approved and then rewriting the content behind the same address. CAC hashes are immutable, so what was approved is exactly what stays approved;
2. the **CAC hash of a metadata JSON** — a conventional object describing what the entry is and what it is about (object type, topics, and other fields that aid searchability); and
3. the **submission fee**, transferred to the contract on submission, alongside an explicit **topic string list** (e.g. "biology", "geography") duplicating the topics in the metadata so the contract can index without reading Swarm.

An approval therefore asserts three things at once: the content is **safe**; the content and metadata hashes **match** and the metadata honestly describes the content; and the content is **relevant to the topics** used in the submission.

### 3.3 Round one — a random panel of seats votes

When a submission arrives, a **random panel of seats** is drawn — a working value of 5 counted seats, each drawn **stake-weighted with replacement** over the moderator set *as it existed before the submission block*, with a ~1-week activation delay on new stake. Because seats are drawn stake-weighted, splitting one stake into many identities buys no extra presence, and a large stake may hold several seats — its *only* advantage, since every seat is one flat vote (§3.4). The seat draw is seeded by on-chain randomness snapshotted a few blocks *after* the round opens; a **separate** seed, snapshotted only *after* the reveal window closes, drives the probabilistic outcome, so the tally is fixed before the outcome randomness exists and cannot be steered by withholding a reveal. Nobody — submitter or moderator — can position themselves for a specific case, and staking three moderators to approve your own content stops working the moment the moderator set has any size.

Drawing a fixed panel of seats (rather than opening voting to a whole eligible subset) keeps every case cheap and fast however large the moderator set grows. Some drawn seat-holders will be offline; that is handled by the widen path below, not by a race to commit.

Voting is **commit-reveal**: the drawn seat-holders submit `H(vote, salt)`, then reveal in a short window. Each seat is one **flat vote** — a moderator holding several seats votes once, counting as its seat count. Seat-holders who fail to reveal take a brief freeze and don't count; if fewer than 3 seats reveal, the panel **widens** (more seats are drawn) and voting reopens, and if none reveal after bounded widening the case voids and the fee is refunded. Commit-reveal keeps the judgments independent — public votes would invite copying the first one.

### 3.4 Probabilistic outcomes and bonded appeals

The revealed votes are tallied by **the seats behind each side**, and the round's outcome is **drawn with probability proportional to seat count**: if approve-seats are twice reject-seats, approve wins with 2/3 probability. A unanimous round needs no luck — one side holds all the seats. Because seats are won stake-weighted, this is stake-proportional in expectation, but stake enters *once* (through seat selection), not twice — the tally itself is unweighted. (Swarm's storage incentives use the same family of mechanism: stake-proportional probabilistic winner selection.)

The result is preliminary. An **appeal window** follows (working value: 3 days; the first window 4 days, so long holiday weekends cannot decide outcomes). During the window, *anyone* — a moderator, the submitter whose content was rejected, an uninvolved third party — may appeal by contributing to a **flip bond**, escalating with depth (working value: each bond ≥ 2× the current pot). An appeal draws a **fresh, larger panel** (working sizes: 5 → 11 → 23 → 47 counted seats), which votes the same way, and the outcome is again drawn probabilistically.

Appeals cap at a working depth of 3. The final round samples the largest subset — but still a *random subset*, never the full moderator set: an attacker holding a global stake majority would know the exact proportions of an all-moderator round in advance, while a sampled round can come out better or worse than its global share. Unpredictability is the point.

If a window closes with no appeal, the case **finalizes**. Clear-cut content is decided in 24 hours plus one quiet window; deep disputes take longer but are rare and fund themselves.

### 3.5 Settlement — fees and bonds to the coherent, freezing for the rest

Finalization is triggered by a **claim** transaction anyone may send after the last window (earning a small bounty from the pot). Then, across all rounds of the case:

- **The pot — submission fee plus all forfeited bonds of losing appellants — is split among voters coherent with the final outcome**, credited as bookkeeping to their in-contract stake balances. No per-moderator transfers: the money already sits in the contract, so the token balance always equals stakes plus open pots, and gas stays flat. A winning appellant's bond is returned, plus a bonus from the pot — appealing a wrong outcome is a paid service to the system.
- **Voters incoherent with the final outcome are frozen.** Freeze duration scales with the **freezing power** of the winning side: a base week, multiplied up to a cap by the winners' track record — a decayed, capped count of past coherent and undisputed participations. This is principle 4 at work: a newcomer whale that wins a round freezes honest veterans only briefly, while veterans who defeat an attack lock its capital up for a long time. (Track record is deliberately capped and time-decayed: raw participation counts could be farmed by self-submitting innocuous content and judging it honestly, so the multiplier saturates and fades. Exact formula is a simulation deliverable.)

No stake moves from loser to winner — freezing is pure deterrence by locked funds, never a bounty. That is what makes "attack anyway and farm the punishment" impossible by construction.

### 3.6 Design rationale — how attacks are priced

The mechanism above survived several adversarial redesigns; recording the reasoning so future contributors don't re-walk the same dead ends:

**Why not deterministic majority?** An attacker who knows it holds a majority attacks with engineered certainty. Probabilistic outcomes mean *every* attack, however funded, can lose any round — there is no safe attack, only priced gambles. And attackers who would only attack with an assured majority are exactly the ones the probability draw deters.

**Why not slash and redistribute losing stakes?** Because redistribution mints the attack's profit: with 100 honest moderators, staking 200 attacking ones and winning would *harvest the honest stakes*. Punishment-as-bounty invites punishment-farming. Kleros-style systems paper over this with a meta-incentive — corrupt the court and its token crashes, destroying the attacker's capital — but that defense doesn't survive contact with a short position, and our stake token (xBZZ) doesn't depend on this contract anyway. So: no reliance on token-value arguments at all. The defense is structural — there is simply no internal transfer to farm.

**Why subsets everywhere, even on appeal?** A global-majority attacker can predict the stake proportions of any all-moderator round exactly — they're the global proportions. A sampled round is unpredictable: sometimes better for the attacker, sometimes worse, never knowable in advance. Sampling also keeps every round cheap and fast regardless of how large the moderator set grows.

**Where does the attack cost actually live?** Three places. The **bond ladder**: pushing a bad outcome through appeals means posting escalating bonds that are forfeited to honest voters when a draw goes wrong — and honest challengers keep re-appealing an attacker's wins, reimbursed from the attacker's own forfeited bonds when they succeed. The **freeze drag**: every lost round locks the attacker's stake, and losing to established honest moderators locks it for a long time (track record). The **absence of prize**: winning pays the attacker nothing from the mechanism — the only upside is the listing itself, and a listing bought through visible bond wars is exactly the kind an honest appellant re-litigates.

**What does an honest moderator's life look like?** Judge clearly-safe and clearly-unsafe content: earn fees, essentially risk-free (unanimous rounds have no lottery, unchallenged results just finalize). Judge borderline content honestly and lose the draw: frozen for a while — annoying, never ruinous (principle 1). Spot a wrong outcome: appeal it, get reimbursed with a bonus when vindicated. The profitable long-run strategy is judging the way any other honest reader of the guidelines would — a Schelling point on honest judgment.

### 3.7 Randomness

MVP: `block.prevrandao` on Gnosis, snapshotted by the first transaction after the relevant phase boundary. Proposer manipulation is real but only pays above per-case pot sizes that fee and bond caps keep small; the assumption is documented, with a VDF or randomness-oracle upgrade path if pots grow.

### 3.8 Publication and search

Search has an easy way and a hard way; **we take the easy way first to reach an MVP**, and optimize later.

**Easy way (MVP):** when round one approves an entry, it is written to an **in-contract map: topic → vector of approved entries**. Each entry carries four fields: the content hash, the metadata hash, the **time of approval**, and an **`uncontested` boolean**. The boolean starts `true` only if no reject votes were revealed, and is **cleared by any contest** — a reject vote or an appeal — so a contested entry can never sneak back into the safe view by merely surviving a draw. If an appeal ends in rejection, the entry is removed at settlement. A submission with multiple topics costs proportionally more, since more contract storage is written (the timestamp and flag pack into a single extra storage word). The search dapp then serves queries entirely from **contract view functions against the latest state** — no scraping of historical logs, no off-chain indexer infrastructure.

**Two views of the index.** The system has probabilistic outcomes, and a safe-search product must be honest about that. The two extra fields split the index into:

- the **superset** — everything currently approved by the system, including entries that won contested, probabilistic draws; and
- the **supersafe subset** — the startpage mode: `uncontested == true && now − approvalTime ≥ 96h`. Judged safe with not a single dissenting vote, and sat through the first appeal window with nobody in public objecting — as close to certainty as a decentralized system gets, computed entirely client-side from the same two fields.

The voting system stays meaningful for everything contested; the supersafe view simply gives cautious front ends (a default startpage, a kids-mode client) a subset that never depended on luck.

**Hard way (later):** publishing the index into Swarm feeds for a more economical, chain-light structure once the MVP proves the mechanism — without changing the moderation game.

## 4. Economics

Making the money flows explicit, since this is the heart of the design:

- **Content creators pay** the submission fee. They are the ones who benefit: approval is exposure — inclusion in the safe-search index that applications will query. This is the *decentralized SEO* side of the coin.
- **Moderators earn** fees by judging coherently, and earn more from disputes — the forfeited bonds of failed appellants and attackers flow to them. Their own stake is never at risk from voting; honest judgment is the only strategy that is profitable in the long run. Anyone can join by staking; nobody employs them — a genuinely decentralized job created by a smart contract alone.
- **Attackers and frivolous appellants fund the system** — but only ever through their own bonds and fees, never through anyone else's stake.
- **AI moderation is expected and welcome**, but someone still has to run each AI moderator, and that operator is compensated like any moderator.
- **The contract holds no idle treasury.** Fees and bonds in, stake credits out. No corporate budget is needed anywhere in the loop.
- **The index is a public good with replaceable ranking.** Because approvals live in transparent contract state, anyone can build a competing search or ranking algorithm over the same data — the opposite of opaque corporate SEO.

## 5. Architecture: four components

| # | Component | Description | Tech |
|---|-----------|-------------|------|
| 1 | **Moderation contract** | Staking, submissions, stake-weighted subset draws, commit-reveal voting, probabilistic outcomes, bonded appeals, track-record bookkeeping, freeze accounting, fee/bond pots, topic → approvals index | Solidity on Gnosis Chain |
| 2 | **Moderator interface** | Web GUI making contract interaction easy for working moderators: eligible cases, content/metadata fetch from Swarm, commit/reveal voting, appealing, claiming, stake and freeze status | Rust → WebAssembly |
| 3 | **Submit interface** | Web GUI for content creators: compose submission (content hash, metadata JSON validated against the schema, topics), pay fee, track status, appeal rejections | Rust → WebAssembly |
| 4 | **Search dapp** | Safe-search front end: query the approved index by topic via contract view functions; supersafe startpage mode (uncontested + seasoned entries) and full superset view; ranking and presentation live client-side and are replaceable | Rust → WebAssembly |

**Gnosis Chain** is chosen deliberately: Bee already depends on it for xBZZ, and its minimal transaction fees are essential for a system built on many small votes, appeals, and fee payments.

On the moderator interface: it began as a human-facing GUI, but since many moderators will be AI, the machine-facing "interface" is the contract itself — rich events (subset eligibility, commit phases closing, reveal deadlines, appeal windows), a published ABI, and a light client library / indexer so bots can watch and act cheaply. A separate machine GUI is unnecessary.

On **Rust → WebAssembly**: the plan that extracts the most value from this choice is a shared Rust/WASM core (CAC/BMT hashing, metadata schema validation, contract call encoding) reused by all three apps, with thin JavaScript interop at the wallet boundary, since browser wallet APIs are JavaScript regardless.

Implementation note: Kleros's sortition-tree contracts (efficient stake-weighted drawing) are open source — evaluate reusing them for the subset draws, license permitting, rather than rewriting.

## 6. Further design decisions

Reviewed by the design owner and delegated to implementation discretion; treated as working decisions unless flagged.

**P1 — Removal requests.** Approvals must not be irrevocable: content can later prove illegal, metadata can turn out to be bait, Swarm storage can lapse. Anyone may submit a *removal request* targeting an existing index entry — same fee, same subsets, outcomes, and appeals; if removal wins, the entry is deleted from the index. Nearly free to build, and it gives the index a legitimate, decentralized correction path.

**P2 — Topic hygiene and a gas-safety cap.** Topics are normalized (lowercase, trimmed, NFC) and stored as keccak keys; a `TopicCreated(string)` event lets UIs autocomplete existing topics so "Biology" and "biology " don't fragment the index. Junk topics die by ranking (the search UI orders topics by approved-entry count), and moderation criteria include "the topics are accurate and themselves acceptable." Topics per submission are capped (~5, with the fee scaling per topic) — also because finalization loops over topics, and an unbounded loop can exceed the block gas limit, making a case *unfinalizable with its pot stranded*. That failure mode must be tested explicitly.

**P3 — Deduplication.** A submission key `H(contentHash, metadataHash, topicKey)` that already exists is rejected. Same content in genuinely different topics remains possible — each costs a separate fee, so spam self-limits.

**P4 — Metadata schema v1.** A versioned JSON schema (`/specs/metadata-v1.json`) defining type, title, description, topics, language, content type — written before any frontend, validated in the submit interface, checked by moderators ("metadata matches content").

**P5 — Moderation guidelines as the Schelling focal point.** Version 1 is deliberately one line: **"Would Google SafeSearch return this?"** — plus "the metadata honestly describes the content, and the topics fit." It lives in a versioned `MODERATION_GUIDELINES.md` whose hash is referenced on-chain; each case is judged per the version active at submission time, and the document grows only as real disputed cases show where one line isn't enough. Under coherence rewards, this document is what moderators are paid to predict the reading of — as load-bearing as the contract.

**P6 — Governance, minimal and honest.** Core logic immutable; only bounded numeric parameters (subset fraction, vote counts, windows, bond schedule, freeze base and cap, track-record decay, fee floor) adjustable behind a multisig with a timelock; withdrawals can never be paused. A "decentralized moderation" contract with an admin backdoor would be a contradiction, so the trust assumptions are stated rather than hidden.

**P7 — Latency honesty and optimistic display.** Unappealed content finalizes in ~24 hours plus one appeal window — days, not minutes. That suits durable content (posts, videos, articles, anything where SEO matters) and does not suit real-time chat. Deep disputes take weeks, but they are rare and self-funding. Optimistic display now falls out of the index fields directly (3.8): entries younger than 96 hours or contested render as *provisional*; entries passing the supersafe filter render with the final badge. No dapp-side case tracking needed.

**P8 — Fee floor and a natural priority market.** The contract enforces `minFee = base + perTopic × nTopics` (covering storage and minimum voter pay). Submitters may overpay; moderators see fees and rationally prioritize high-fee cases — a priority market with zero extra protocol.

## 7. Open questions

**Parameters are simulation output, not opinions.** Subset fraction and its scaling curve, counted-vote sizes per depth, the bond schedule, freeze base/cap and the track-record formula (decay rate, saturation, anti-farming), reveal windows and under-participation handling, the fee floor — all working values until the M1 simulation validates them against the attack scenarios.

**Track-record farming.** Freezing power derives from participation history, and history can be manufactured: self-submit innocuous content, judge it honestly, repeat. The cap and decay bound the damage, and farming costs real fees the honest side collects — but the exact formula needs adversarial simulation before it's trusted.

**Seat-holder liveness.** A drawn seat-holder may be offline. The panel is drawn by sortition (no first-come race), and offline seats are handled by the widen path — re-drawing more seats up to a bound, then voiding and refunding the fee if too few ever reveal. The working `MIN_REVEALS`, widen bound, and reveal window still need validation against realistic, bursty offline behaviour.

**Panel grinding.** Submitting repeatedly until friendly moderators land in the subset remains possible at a cost of one fee per attempt; the appeal ladder is the wall that makes it pointless. Documented as accepted.

Also open: long-term topic-namespace governance; who maintains the guidelines document and how updates are adopted; repository license and organizational ownership; moderator privacy (addresses are permanently linked to controversial decisions — the guidelines should recommend fresh addresses per moderator identity); and the migration path from the in-contract index to a Swarm-feed-published index.

## 8. Roadmap

**M1 — Specification and simulation.** This writeup, a formal state-machine spec of the contract, the metadata schema, the guidelines document, and an agent-based simulation of the attack scenarios (probability-buying whales, bond wars up the appeal ladder, track-record farming, first-come racing and copy-voting, subset under-participation, honest-moderator earnings across fee/bond/freeze values) — *before any Solidity is written*, so parameters come from numbers rather than intuition.

**M2 — Contract.** Solidity implementation with a full test suite, including the sortition machinery (evaluate reusing Kleros's tree, license permitting) and gas-bound tests on finalization and settlement paths. The contract defines the protocol; everything else is a client of it.

**M3 — Interfaces.** The three web apps on a shared Rust/WASM core, in dependency order: moderator interface first (without moderators nothing gets approved), then the submit interface (creators feed the pipeline), then the search dapp (proves the end-to-end value) — plus the event indexer / client library for AI moderators.

**M4 — Launch.** Review/audit, deployment to Chiado (Gnosis testnet), then a guarded mainnet launch with conservative caps.

---


