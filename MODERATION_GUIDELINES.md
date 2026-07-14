# Moderation Guidelines

**Version:** 1
**Status:** Active
**Applies to:** every case is judged against the guidelines version that was active at the time the submission was made (not the version active when the vote is cast).

---

## How to read this document

This is the **Schelling focal point** of the whole protocol. Moderators are not
paid to enforce their personal taste; they are paid to predict *the reading any
other honest moderator would give this same document*. Coherence with the final
outcome earns fees; incoherence earns a freeze. The profitable long-run strategy
is therefore to judge exactly the way a neutral reader of these guidelines would
— nothing more, nothing less.

Because coherence is what is rewarded, this document is **as load-bearing as the
contract**. Its keccak-256 hash is recorded on-chain, and the contract pins the
active version at submission time so that no later edit can retroactively change
how an already-submitted case should be judged.

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
safe. If it would be filtered out, it is not.

This covers, non-exhaustively, the categories a reasonable person expects a
safe-search filter to remove: sexually explicit content, graphic violence and
gore, content that sexualizes minors (an absolute line — always reject), and
content whose primary purpose is to harass, threaten, or incite violence against
a person or group.

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
index category (not spam, not an attempt to pollute an unrelated topic's results,
not a slur or an unsafe label). A submission that is safe and honestly described
but filed under topics it has nothing to do with should be **rejected**: topic
spam degrades the search product for everyone.

---

## 2. What you are *not* judging

- **Quality, popularity, or usefulness.** These guidelines are a safety and
  honesty filter, not an editorial one. Dull, low-effort, or niche content that
  is safe, honestly described, and correctly filed is **APPROVED**. Ranking and
  curation live client-side in the search dapps and are explicitly replaceable;
  they are not your job.
- **Legality in any specific jurisdiction.** You are applying a single global
  safe-search standard, not the law of any one country. (Content that later
  proves illegal is handled by the removal-request path, P1, not by asking
  moderators to be lawyers.)
- **The submitter's identity or motive.** Judge the content and its metadata,
  not who sent it.

## 3. Removal requests

A removal request (P1) targets an entry already in the index and is judged by
the **same** three-question test applied to the entry's *current* state, plus one
question specific to removals:

> **Should this entry no longer be in the index?**

Vote to **remove** (i.e. coherent with the removal request) if the entry now
fails any part of the test — for example the content has been shown to be
unsafe, the metadata has been shown to be bait, or the underlying Swarm content
is gone so the entry points at nothing. Vote to **keep** (coherent with
rejecting the removal request) if the entry still passes. A removal request is
not a second bite at a fair approval; frivolous removals fund the moderators who
correctly vote to keep, exactly as frivolous submissions do.

## 4. Practical notes for moderators

- **Fetch before you vote.** Both the content chunk and the metadata JSON are
  content-addressed (CAC), so what you fetch is exactly what was submitted and
  exactly what stays approved. Never vote on the metadata alone.
- **Borderline is allowed to be borderline.** Hard cases exist. If a call is
  genuinely borderline you may lose the probabilistic draw and be frozen for a
  while; that is annoying but never ruinous (design principle 1). Judge honestly
  anyway — over many cases, honest judgment is the only strategy that pays.
- **Appeal wrong outcomes.** If you believe a finalized-looking outcome is wrong,
  the appeal path exists for you: a correct appeal is reimbursed with a bonus. A
  wrong outcome left unappealed is nobody's fault but the network's.
- **Use a fresh address per moderator identity.** Addresses are permanently
  linked on-chain to the decisions they make. Treat moderator addresses as
  disposable identities, not as your primary wallet. (Open question in the
  README; recommended practice here.)

---

## Versioning and change control

- The active version integer and this document's keccak-256 hash are pinned
  on-chain.
- A case is always judged against the version active **at its submission block**.
- Changes are additive and case-driven: a new version is cut only when a real
  disputed case shows the current text is ambiguous, and the changelog entry must
  cite the case that forced it.
- Who maintains this document and how updates are ratified is an open governance
  question (see README §7); until resolved, changes follow the same bounded
  multisig-plus-timelock path as numeric parameters (P6).

## Changelog

- **v1** — Initial version. Three-question test (safe / honest metadata /
  fitting topics), the "Would Google SafeSearch return this?" safety line,
  removal-request handling, and moderator practical notes.
