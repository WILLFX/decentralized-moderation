# Moderation Guidelines

**Version:** 1
**Status:** Active
**Applies to:** every case is judged against the guidelines version that was active at the time the submission was made (not the version active when the vote is cast). **This is a convention among moderators, not an enforced one** — see "Versioning and change control".

---

## How to read this document

This is the **Schelling focal point** of the whole protocol. Moderators are not
paid to enforce their personal taste; they are paid to predict *the reading any
other honest moderator would give this same document*. Coherence with the final
outcome earns a share of the fee; incoherence adds a fixed duration to your
frozen time, during which you are eligible for nothing. The profitable long-run
strategy is therefore to judge exactly the way a neutral reader of these
guidelines would — nothing more, nothing less.

Because coherence is what is rewarded, this document is **as load-bearing as the
contract** — it is what moderators are predicting each other against. It is not,
however, tied to the chain: **the contracts record no guidelines version and no
hash of this document**, so nothing on chain fixes which text a given case was
judged under. Until that changes, "the version active at submission" is a
convention this document asks moderators to keep, enforced by nothing.

This version is deliberately short. It grows **only** when a real, disputed case
demonstrates that one line was not enough — never speculatively. Every addition
should be traceable to a case that forced it.

---

## 1. The test

When you judge a submission you are answering **three** questions. A submission
is **APPROVED** only if the answer to all three is *yes*; otherwise it is
**REJECTED**.

### 1.1 Is it safe?

> **Would Google SafeSearch return this?**

That single line is the v1 safety standard. If a mainstream safe-search filter,
tuned for a general audience including minors, would return the content, it is
safe. If it would be filtered out, it is not. The standard deliberately defers
the boundary to a well-understood external reference rather than restating a
catalogue of prohibited material here.

The reference is to the **genre** of mainstream, general-audience safe-search
filtering as it is commonly understood at this guidelines version's date — not a
live query against any particular product (moderators cannot query one for
unpublished Swarm content, and such products are proprietary, regional, and
change continuously). Moderators judge the fetched content directly against that
shared understanding; the point being predicted is *whether general-audience
safe search would exclude this*, on safety grounds, not whether some specific
engine happens to index the URL.

One category is stated explicitly because it admits no ambiguity: content that
sexualizes minors is rejected without exception.

When in genuine doubt about safety, **reject**. The index exists to be trusted;
a false approval costs the index its credibility, while a false rejection costs
the submitter only a resubmission.

### 1.2 Does the metadata honestly describe the content?

The submission pairs a content hash with a metadata hash. Fetch both. The
metadata's `title`, `description`, `type`, and `contentType` must honestly
describe what the content actually is. Reject **bait-and-switch**: innocuous
metadata wrapped around unsafe or unrelated content, or vice versa. The metadata
is what search users and downstream applications will see *without* opening the
content, so a dishonest description is itself a safety failure.

### 1.3 Do the topics fit?

The submission declares a list of topics. Each declared topic must be **accurate**
— the content is genuinely about that topic — and **itself acceptable** as an
index category: it must not be used to place content under an unrelated topic,
and must not itself be a slur or an otherwise unacceptable label. A submission
that is safe and honestly described but filed under topics it does not concern
should be **rejected**, since misfiled topics degrade the quality of the index
for all users.

---

## 2. What you are *not* judging

- **Quality, popularity, or usefulness.** These guidelines are a safety and
  honesty filter, not an editorial one. Low-effort or niche content that is safe,
  honestly described, and correctly filed is **APPROVED**. Ranking and curation
  live client-side in the search dapps and are explicitly replaceable; they are
  outside the scope of moderation.
- **Legality in any specific jurisdiction.** You are applying a single global
  safe-search standard, not the law of any one country; moderators are not asked
  to make legal determinations. Content later shown to be illegal is handled by
  a removal case (§3).
- **The submitter's identity or motive.** Judge the content and its metadata,
  not who sent it.

## 3. Removal requests

A removal case targets an entry already in the index and is judged by
the **same** three-question test applied to the entry's *current* state, plus one
question specific to removals:

> **Should this entry no longer be in the index?**

**Read the ballot carefully, because a removal inverts what a vote means.** A
removal case asks *"should this be removed"*, so an **Approve** vote on a removal
case means **take it out of the index**, and a **Reject** vote means **leave it
listed**. It is the same ballot as any other case; only the question changes.

Vote to remove if the entry now fails any part of the test — the content has been
shown to be unsafe, the metadata has been shown to be bait, or the underlying
Swarm content is gone so the entry points at nothing. Vote to keep if the entry
still passes.

A removal is not a mechanism for re-litigating a sound approval, and it is priced
so that it cannot be used as one: **the fee is paid whether the removal succeeds
or fails**, so a speculative removal costs its submitter every time. Frivolous
removals fund the moderators who correctly vote to keep, exactly as frivolous
submissions do.

## 4. Practical notes for moderators

- **Fetch before you vote.** Both the content chunk and the metadata JSON are
  content-addressed (CAC), so what you fetch is exactly what was submitted and
  exactly what stays approved. Never vote on the metadata alone.
- **Reveal what you committed.** Withholding is never worth it on the merits:
  your vote can only help the side you actually hold, and removing it strictly
  lowers that side's chances. Be aware that the protocol does not currently
  *price* a non-reveal — a commitment never revealed is neither paid nor frozen —
  and that this is an open item (`specs/protocol.md` §11), not a licence.
- **Borderline cases will occur.** On a genuinely borderline judgment you may end
  up incoherent with the outcome, and `FREEZE_PER_LOSS` is added to your total
  frozen time. It is a bounded, fixed duration, additive to a running total rather
  than an extension from the present moment, so the same set of losses costs the
  same whatever order they settle in. **Your stake is never taken** — not slashed,
  not redistributed, not transferred. Time is the only currency of penalty. Judge
  honestly regardless: over many cases, honest judgment is the only strategy that
  is profitable in the long run.
- **Challenge incorrect outcomes, and understand what a challenge is.** Once both
  committees have revealed, three tickets are drawn against their combined tally
  and the result is published as a **preliminary outcome**. A one hour challenge
  window follows.

  Three things about it are easy to get wrong:

  - **A challenge *is* a vote, and it discloses its direction.** It is a public
    vote **opposite** the published outcome — you cannot challenge an Approve by
    approving. Your vote counts once in the pool and carries the ordinary vote
    liability, so challenging a correct outcome freezes you like any other
    incoherent vote.
  - **There is no bond.** Nothing is posted and nothing is refunded. The price of
    challenging is the liability you take on by voting.
  - **At most two challenges per case.** After the second resolves, the case
    finalizes.

  A challenge buys another two committees, and the tickets are then drawn
  **afresh** over the whole pool — every committee that has revealed, including
  the first two. So a challenge that brings no new votes still re-draws, but over
  a tally it barely moved; the way to change the answer is to change the evidence.
  An incorrect outcome that nobody challenges will simply stand.
- **Use a fresh address per moderator identity.** Addresses are permanently
  linked on-chain to the decisions they make, so treat a moderator address as a
  disposable identity rather than your primary wallet. Nothing in this design
  accrues to an address across cases — there is no reputation or track record to
  lose — so rotating costs you nothing but the stake for the new identity. Note
  the other side of that: it is also why a freeze deters only to the extent
  capital is scarce (`specs/protocol.md` §10.3).

---

## Versioning and change control

- **Nothing here is pinned on chain.** The contracts store no version integer and
  no hash of this document. A case therefore carries no record of which text it
  was judged under, and an edit to this file changes how every open case *should*
  be judged with no on-chain trace. Pinning the version and hash at submission is
  the mechanism that would fix it; it is not built, and it is not in
  `specs/protocol.md` either — it is an open item, listed there in §11.
- A case *should* be judged against the version active **at its submission
  block**. That is the intent the pin above would enforce.
- Changes are additive and case-driven: a new version is cut only when a real
  disputed case shows the current text is ambiguous, and the changelog entry must
  cite the case that forced it.
- Who maintains this document and how updates are ratified is an **open
  governance question** with no answer in this repository. There is no multisig,
  no timelock and no upgrade path in the contracts; the numeric parameters in
  `specs/protocol.md` §11 have no values yet, let alone a process for changing
  them.

## Changelog

- **v1** — Initial version. Three-question test (safe / honest metadata /
  fitting topics), the "Would Google SafeSearch return this?" safety line,
  removal-request handling, and moderator practical notes.

  **Corrected in place, before first use, and deliberately not cut as v2.** The
  three-question test in §1 has never changed. Everything this document said
  *around* it about consequence has been wrong at least once, because the protocol
  it describes was rewritten under it: bonds, balance debits, a `track` record, a
  published plurality and a direction-hiding challenge have all appeared here and
  are all gone. The text now matches `specs/protocol.md` as the single normative
  design: the only penalty is an additive freeze, the stake is never taken, a
  preliminary outcome is drawn and published, and a challenge is a public vote
  opposite it with no bond. The claim that this document's hash is pinned on chain
  was also removed — it never was.

  **Why this is not a version bump.** The change-control rule below cuts a new
  version when a *disputed case* shows the text is ambiguous. No case has ever
  been judged under v1 — it has never been pinned to a submission, so there is
  nothing whose judgment this could retroactively alter, which is the only harm
  the rule exists to prevent. Correcting it now is free; correcting it after a
  testnet begins would split `measurement/prior`'s dataset along
  `guidelinesVersion` and leave two underpowered samples instead of one usable
  one (`measurement/prior/README.md`). **A version bump becomes mandatory the
  moment the first case is submitted.**
